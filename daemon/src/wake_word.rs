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

/// Default model search path inside the OS image.
pub const RUSTPOTTER_MODEL_PATH: &str = "/var/lib/lifeos/models/rustpotter/axi.rpw";

// ── Feature-gated implementation ─────────────────────────────────────────

#[cfg(feature = "wake-word")]
mod inner {
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
        pub fn set_source(&self, source: Option<String>) {
            let _ = self.source_tx.send(source);
        }

        /// Pause detection (mic stays open but detections are suppressed).
        pub fn pause(&self) {
            self.active.store(false, Ordering::Relaxed);
        }

        /// Resume detection.
        pub fn resume(&self) {
            self.active.store(true, Ordering::Relaxed);
        }

        /// Permanently stop the listener thread.
        pub fn stop(&self) {
            self.shutdown.store(true, Ordering::Relaxed);
        }

        pub fn is_active(&self) -> bool {
            self.active.load(Ordering::Relaxed)
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
                if let Err(e) = self.listen_session() {
                    warn!("Wake word listener session ended: {e}");
                }
                if self.shutdown.load(Ordering::Relaxed) {
                    return;
                }
                info!("Respawning pw-record in 2 s …");
                std::thread::sleep(std::time::Duration::from_secs(2));
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
            let mut stdout = child
                .stdout
                .take()
                .context("failed to capture pw-record stdout")?;

            // Read a snapshot of source_rx to detect changes.
            let mut last_source = source;

            let mut buf = vec![0u8; bytes_per_frame];
            let mut wav_header_skipped = false;

            loop {
                // Check shutdown
                if self.shutdown.load(Ordering::Relaxed) {
                    let _ = child.kill();
                    return Ok(());
                }

                // Check source change
                let current_source = self.source_rx.borrow().clone();
                if current_source != last_source {
                    info!("Audio source changed, restarting pw-record");
                    let _ = child.kill();
                    return Ok(());
                }
                last_source = current_source;

                // Read one frame
                match stdout.read_exact(&mut buf) {
                    Ok(()) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
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

                // Feed rustpotter
                if let Some(detection) = rp.process_bytes(&buf) {
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
        pub fn is_active(&self) -> bool {
            false
        }
    }
}

pub use inner::WakeWordDetector;
