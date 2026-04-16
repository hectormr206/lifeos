//! Lightweight wake word detection via rustpotter.
//!
//! Provides streaming wake word detection as a replacement for the
//! capture-transcribe-match cycle. When the `wake-word` feature is enabled
//! and a trained `.rpw` model is available, the detector continuously listens
//! via `pw-record` and fires a `Notify` the instant the wake word is spoken.
//!
//! When the feature is not compiled or the model file is missing, the stub
//! implementation returns `available() == false` and the daemon falls back
//! to the legacy Whisper-based detection in `sensory_pipeline.rs`.

/// Default model path (writable, user-specific or refined by enrollment).
pub const RUSTPOTTER_MODEL_PATH: &str = "/var/lib/lifeos/models/rustpotter/axi.rpw";
/// Pre-built model shipped in the immutable image (read-only).
pub const RUSTPOTTER_IMAGE_MODEL_PATH: &str = "/usr/share/lifeos/models/rustpotter/axi.rpw";

/// Resolve the best available wake word model path.
/// Prefers the writable path (may be user-refined), falls back to the
/// pre-built image model, and auto-copies it to the writable location
/// on first use so future refinements can update it in place.
pub fn resolve_model_path() -> Option<std::path::PathBuf> {
    let writable = std::path::PathBuf::from(RUSTPOTTER_MODEL_PATH);
    if writable.exists() {
        return Some(writable);
    }
    let image = std::path::PathBuf::from(RUSTPOTTER_IMAGE_MODEL_PATH);
    if image.exists() {
        // Copy to writable location so it can be refined later
        if let Some(parent) = writable.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        if std::fs::copy(&image, &writable).is_ok() {
            log::info!(
                "Copied pre-built wake word model from {} to {}",
                image.display(),
                writable.display()
            );
            return Some(writable);
        }
        // If copy fails (e.g. read-only fs), use image path directly
        return Some(image);
    }
    None
}

// ── Feature-gated implementation ─────────────────────────────────────────

#[cfg(feature = "wake-word")]
mod inner {
    use crate::audio_frontend::{preprocess_frame_i16le, AudioFilterState};
    use anyhow::{Context, Result};
    use chrono::{DateTime, Utc};
    use log::{info, warn};
    use rustpotter::{Rustpotter, RustpotterConfig, SampleFormat};
    use std::io::Read;
    use std::path::PathBuf;
    use std::process::{Command, Stdio};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use tokio::sync::{Notify, RwLock};

    const SAMPLE_RATE: usize = 16000;
    const RESTART_DELAY: std::time::Duration = std::time::Duration::from_secs(2);
    const RESTART_DELAY_POLL: std::time::Duration = std::time::Duration::from_millis(100);

    /// Streaming wake word detector backed by rustpotter.
    #[derive(Clone)]
    pub struct WakeWordDetector {
        model_path: PathBuf,
        /// Fires each time the wake word is detected — wakes the sensory loop.
        pub detection_notify: Arc<Notify>,
        /// Timestamp of the most recent detection (consumed by `take_detection`).
        detected_at: Arc<RwLock<Option<DateTime<Utc>>>>,
        /// Controls pause / resume without killing the thread.
        active: Arc<AtomicBool>,
        /// Audio source for pw-record (updated by the sensory loop on BT changes).
        source_tx: tokio::sync::watch::Sender<Option<String>>,
        source_rx: tokio::sync::watch::Receiver<Option<String>>,
        /// Signals the listener thread to terminate.
        shutdown: Arc<AtomicBool>,
        /// Signals the listener thread to reload the model (hot-reload after training).
        reload: Arc<AtomicBool>,
        /// PID of the active pw-record child, if any.
        active_child_pid: Arc<std::sync::atomic::AtomicI32>,
    }

    impl WakeWordDetector {
        /// Create a new detector. Does **not** start listening yet — call [`run`].
        pub fn new(model_path: PathBuf, source: Option<String>) -> Result<Self> {
            anyhow::ensure!(
                model_path.exists(),
                "rustpotter model not found: {}",
                model_path.display()
            );
            let (source_tx, source_rx) = tokio::sync::watch::channel(source);
            Ok(Self {
                model_path,
                detection_notify: Arc::new(Notify::new()),
                detected_at: Arc::new(RwLock::new(None)),
                active: Arc::new(AtomicBool::new(true)),
                source_tx,
                source_rx,
                shutdown: Arc::new(AtomicBool::new(false)),
                reload: Arc::new(AtomicBool::new(false)),
                active_child_pid: Arc::new(std::sync::atomic::AtomicI32::new(0)),
            })
        }

        /// Spawn the listener on a blocking thread. Returns immediately.
        pub fn run(&self) -> tokio::task::JoinHandle<()> {
            let det = self.clone();
            tokio::task::spawn_blocking(move || det.listener_loop())
        }

        /// Consume the most recent detection timestamp, if any.
        pub async fn take_detection(&self) -> Option<DateTime<Utc>> {
            self.detected_at.write().await.take()
        }

        /// Update the audio source (e.g. after BT connect/disconnect).
        /// No-op when the new value matches the current one — without this
        /// guard the sensory loop calls us every tick and pw-record is
        /// SIGTERM'd every few seconds even when the source never changed.
        pub fn set_source(&self, source: Option<String>) {
            if *self.source_tx.borrow() == source {
                return;
            }
            let _ = self.source_tx.send(source);
            self.signal_active_child(libc::SIGTERM, "source change");
        }

        /// Pause detection AND close the mic. SIGTERMs any running
        /// pw-record so the mic is actually released — the listener
        /// loop will notice `active=false` and idle without respawning.
        /// Hearing audit C-2/C-3.
        pub fn pause(&self) {
            self.active.store(false, Ordering::Relaxed);
            self.signal_active_child(libc::SIGTERM, "pause");
        }

        /// Resume detection.
        pub fn resume(&self) {
            self.active.store(true, Ordering::Relaxed);
        }

        /// Permanently stop the listener thread.
        pub fn stop(&self) {
            self.shutdown.store(true, Ordering::Relaxed);
            self.signal_active_child(libc::SIGTERM, "shutdown");
        }

        pub fn is_active(&self) -> bool {
            self.active.load(Ordering::Relaxed)
        }

        /// Signal the detector to reload its model file (hot-reload after training).
        /// The listener loop will restart with the updated model on the next cycle.
        pub fn reload_model(&self) {
            info!("Wake word model reload requested");
            self.reload.store(true, Ordering::Relaxed);
            self.signal_active_child(libc::SIGTERM, "model reload");
        }

        /// Returns `true` when the feature is compiled.
        pub fn available() -> bool {
            true
        }

        // ── internal ─────────────────────────────────────────────────────

        fn listener_loop(&self) {
            loop {
                if self.shutdown.load(Ordering::Relaxed) {
                    info!("Wake word detector shutting down");
                    return;
                }

                // Hearing audit C-2/C-3: do NOT hold `pw-record` open
                // while the detector is paused (kill switch engaged or
                // audio disabled). Previously `pause()` only flipped a
                // flag so detections got discarded, but the mic
                // subprocess stayed running — observed live as a 5h49m
                // hot pw-record that the kill switch could not stop.
                //
                // Now: when `active=false` and no reload/shutdown is
                // pending, idle in a cheap 500ms poll loop without
                // spawning pw-record. The mic is actually closed.
                // Resume flips `active=true` and we spawn a fresh
                // session on the next iteration.
                if !self.active.load(Ordering::Relaxed) {
                    std::thread::sleep(std::time::Duration::from_millis(500));
                    continue;
                }

                // Clear reload flag before starting a new session
                if self.reload.swap(false, Ordering::Relaxed) {
                    info!("Reloading wake word model...");
                }
                if let Err(e) = self.listen_session() {
                    warn!("Wake word listener session ended: {e}");
                }
                if self.shutdown.load(Ordering::Relaxed) {
                    return;
                }
                if !self.active.load(Ordering::Relaxed) {
                    // Don't churn respawn when we've just been paused
                    // mid-session. Skip the 2s delay and idle directly.
                    continue;
                }
                info!("Respawning pw-record in 2 s …");
                if self.wait_for_restart_delay() {
                    return;
                }
            }
        }

        /// One session: spawn pw-record → feed rustpotter → detect.
        /// Returns when pw-record exits or source changes.
        fn listen_session(&self) -> Result<()> {
            // Build rustpotter
            let mut config = RustpotterConfig::default();
            config.fmt.sample_rate = SAMPLE_RATE;
            config.fmt.channels = 1;
            config.fmt.sample_format = SampleFormat::I16;
            let mut rp = Rustpotter::new(&config)
                .map_err(|e| anyhow::anyhow!("failed to create rustpotter instance: {e}"))?;
            rp.add_wakeword_from_file("axi", self.model_path.to_string_lossy().as_ref())
                .map_err(|e| {
                    anyhow::anyhow!(
                        "failed to load wake word model {}: {e}",
                        self.model_path.display()
                    )
                })?;

            let bytes_per_frame = rp.get_bytes_per_frame();
            info!(
                "Rustpotter ready — bytes_per_frame={bytes_per_frame}, model={}",
                self.model_path.display()
            );

            // Spawn pw-record
            let source = self.source_rx.borrow().clone();
            let mut child = self.spawn_pw_record(source.as_deref())?;
            let active_child = ActiveChildGuard::new(self.active_child_pid.clone(), child.id());
            let mut stdout = child
                .stdout
                .take()
                .context("failed to capture pw-record stdout")?;

            // Read a snapshot of source_rx to detect changes.
            let mut last_source = source;
            let mut filter_state = AudioFilterState::default();
            let mut rolling_noise_floor = None;
            let wake_gain_db: f64 = std::env::var("LIFEOS_WAKE_WORD_GAIN_DB")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(4.0);

            let mut buf = vec![0u8; bytes_per_frame];
            let mut wav_header_skipped = false;

            loop {
                // Check shutdown
                if self.shutdown.load(Ordering::Relaxed) {
                    let _ = child.kill();
                    let _ = child.wait();
                    drop(active_child);
                    return Ok(());
                }

                // Check model reload
                if self.reload.load(Ordering::Relaxed) {
                    info!("Model reload requested, restarting listener");
                    let _ = child.kill();
                    let _ = child.wait();
                    drop(active_child);
                    return Ok(());
                }

                // Check source change
                let current_source = self.source_rx.borrow().clone();
                if current_source != last_source {
                    info!("Audio source changed, restarting pw-record");
                    let _ = child.kill();
                    let _ = child.wait();
                    drop(active_child);
                    return Ok(());
                }
                last_source = current_source;

                // Read one frame
                match stdout.read_exact(&mut buf) {
                    Ok(()) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                        let _ = child.wait();
                        drop(active_child);
                        return Ok(());
                    }
                    Err(e) => return Err(e.into()),
                }

                // pw-record may write a WAV header (44 bytes) before PCM data.
                // Skip it once if we see the RIFF magic.
                if !wav_header_skipped {
                    wav_header_skipped = true;
                    if buf.len() >= 4 && &buf[..4] == b"RIFF" {
                        // Drain remaining header bytes and re-read.
                        // WAV header is 44 bytes; we already read bytes_per_frame.
                        // The first frame is corrupted — just skip it.
                        continue;
                    }
                }

                // If paused, discard frames silently.
                if !self.active.load(Ordering::Relaxed) {
                    continue;
                }

                let processed = preprocess_frame_i16le(
                    &buf,
                    SAMPLE_RATE as u32,
                    wake_gain_db,
                    rolling_noise_floor,
                    &mut filter_state,
                );
                if processed.pcm_le.is_empty() {
                    continue;
                }
                if processed.stats.rms > 0.0 {
                    rolling_noise_floor = Some(match rolling_noise_floor {
                        Some(prev) if processed.stats.rms <= prev * 2.5 => {
                            (prev * 0.96) + (processed.stats.rms * 0.04)
                        }
                        Some(prev) => prev,
                        None => processed.stats.rms,
                    });
                }

                // Feed rustpotter
                if let Some(detection) = rp.process_bytes(&processed.pcm_le) {
                    info!(
                        "Wake word detected: name={}, score={:.3}, avg_score={:.3}",
                        detection.name, detection.score, detection.avg_score
                    );
                    // Publish detection
                    let rt = tokio::runtime::Handle::try_current();
                    if let Ok(handle) = rt {
                        let detected_at = self.detected_at.clone();
                        handle.block_on(async {
                            *detected_at.write().await = Some(Utc::now());
                        });
                    }
                    self.detection_notify.notify_one();
                }
            }
        }

        fn spawn_pw_record(&self, source: Option<&str>) -> Result<std::process::Child> {
            let mut cmd = Command::new("pw-record");
            cmd.args(["--rate", "16000", "--channels", "1", "--format", "s16"]);
            if let Some(src) = source {
                cmd.args(["--target", src]);
            }
            cmd.arg("-"); // stdout
            cmd.stdout(Stdio::piped());
            cmd.stderr(Stdio::null());
            let child = cmd.spawn().context("failed to spawn pw-record")?;
            info!(
                "pw-record started (pid={}, source={:?})",
                child.id(),
                source
            );
            Ok(child)
        }

        fn signal_active_child(&self, signal: i32, reason: &str) {
            let pid = self.active_child_pid.load(Ordering::SeqCst);
            if pid <= 0 {
                return;
            }
            let rc = unsafe { libc::kill(pid, signal) };
            if rc == 0 {
                info!(
                    "Signaled active wake word audio process pid={} with signal {} ({reason})",
                    pid, signal
                );
                return;
            }
            let err = std::io::Error::last_os_error();
            if err.raw_os_error() != Some(libc::ESRCH) {
                warn!(
                    "Failed to signal active wake word audio process pid={} with signal {} ({}): {}",
                    pid, signal, reason, err
                );
            }
        }

        fn wait_for_restart_delay(&self) -> bool {
            let checks = RESTART_DELAY.as_millis() / RESTART_DELAY_POLL.as_millis();
            for _ in 0..checks {
                if self.shutdown.load(Ordering::Relaxed) {
                    info!("Wake word detector restart canceled during shutdown");
                    return true;
                }
                std::thread::sleep(RESTART_DELAY_POLL);
            }
            false
        }
    }

    struct ActiveChildGuard {
        pid_slot: Arc<std::sync::atomic::AtomicI32>,
        pid: i32,
    }

    impl ActiveChildGuard {
        fn new(pid_slot: Arc<std::sync::atomic::AtomicI32>, pid: u32) -> Self {
            let pid = pid as i32;
            pid_slot.store(pid, Ordering::SeqCst);
            Self { pid_slot, pid }
        }
    }

    impl Drop for ActiveChildGuard {
        fn drop(&mut self) {
            let _ = self
                .pid_slot
                .compare_exchange(self.pid, 0, Ordering::SeqCst, Ordering::SeqCst);
        }
    }

    #[cfg(test)]
    mod tests {
        use super::WakeWordDetector;
        use std::path::PathBuf;
        use std::process::Command;
        use std::time::{Duration, SystemTime, UNIX_EPOCH};

        #[test]
        fn stop_terminates_active_audio_process() {
            let model_path = temp_model_path("stop");
            let detector = WakeWordDetector::new(model_path.clone(), None).unwrap();
            let mut child = Command::new("sh")
                .args(["-c", "sleep 30"])
                .spawn()
                .expect("spawn sleep child");
            let _active_child =
                super::ActiveChildGuard::new(detector.active_child_pid.clone(), child.id());

            detector.stop();

            let mut exited = false;
            for _ in 0..20 {
                if child.try_wait().expect("try_wait").is_some() {
                    exited = true;
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            if !exited {
                let _ = child.kill();
                let _ = child.wait();
            }

            assert!(exited, "stop() should terminate the active audio process");

            let _ = std::fs::remove_file(model_path);
        }

        #[test]
        fn restart_delay_exits_early_when_shutdown_requested() {
            let model_path = temp_model_path("delay");
            let detector = WakeWordDetector::new(model_path.clone(), None).unwrap();
            detector.stop();

            let started = std::time::Instant::now();
            let stopped_early = detector.wait_for_restart_delay();

            assert!(stopped_early, "restart delay should stop during shutdown");
            assert!(
                started.elapsed() < Duration::from_millis(300),
                "restart delay should not sleep the full 2s after shutdown"
            );

            let _ = std::fs::remove_file(model_path);
        }

        fn temp_model_path(label: &str) -> PathBuf {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock before epoch")
                .as_nanos();
            let path = std::env::temp_dir().join(format!("lifeos-wakeword-{label}-{nanos}.rpw"));
            std::fs::write(&path, b"test-model").expect("write temp model");
            path
        }
    }
}

// ── Stub when feature is not compiled ────────────────────────────────────

#[cfg(not(feature = "wake-word"))]
mod inner {
    use std::path::PathBuf;

    /// Stub detector when the `wake-word` feature is not compiled.
    #[derive(Clone)]
    pub struct WakeWordDetector;

    impl WakeWordDetector {
        pub fn available() -> bool {
            false
        }

        pub fn new(_model_path: PathBuf, _source: Option<String>) -> anyhow::Result<Self> {
            anyhow::bail!("wake-word feature not compiled")
        }

        pub fn run(&self) -> tokio::task::JoinHandle<()> {
            tokio::task::spawn(async {})
        }

        pub async fn take_detection(&self) -> Option<chrono::DateTime<chrono::Utc>> {
            None
        }

        pub fn set_source(&self, _source: Option<String>) {}
        pub fn pause(&self) {}
        pub fn resume(&self) {}
        pub fn stop(&self) {}
        pub fn reload_model(&self) {}
        pub fn is_active(&self) -> bool {
            false
        }
    }
}

pub use inner::WakeWordDetector;
