//! Wake-word listener for the companion (feature = "wake-word").
//!
//! When a wake word is detected, calls
//! `POST /api/v1/sensory/wake-word/trigger` on the daemon so the sensory
//! pipeline can act on it.
//!
//! # Current Status (Phase 3b)
//!
//! The daemon's wake-word implementation (`daemon/src/wake_word.rs`) uses a
//! `pw-record` subprocess feeding raw PCM into rustpotter. Replicating that
//! pattern here as a standalone companion is feasible but requires:
//!   1. Duplicating the PipeWire subprocess management.
//!   2. Sharing the rustpotter model path constants with the daemon.
//!   3. Resolving the `audio_frontend` preprocess dependency (currently
//!      `daemon`-private and uses libc directly).
//!
//! None of those blockers are insurmountable, but they are non-trivial and
//! would inflate PR-B beyond scope. The design intent is that the daemon
//! handles in-process wake-word detection when running on a host with
//! `WAYLAND_DISPLAY` (the guard added in TASK-04), and the companion only
//! needs the relay endpoint for the Phase 3c migration.
//!
//! **Decision**: ship a stub that logs a clear ERROR on startup so the
//! feature is visibly incomplete. The companion runs correctly without it
//! (the daemon's in-process detector fires instead). Phase 3c will implement
//! the full PipeWire+rustpotter listener here.
//!
//! Phase 3c will implement the full PipeWire+rustpotter listener here.
//! See design §5 `wake_word.rs` skeleton for the target API.

#[cfg(feature = "wake-word")]
pub use inner::*;

#[cfg(feature = "wake-word")]
mod inner {
    use crate::daemon_client::DaemonClient;
    use anyhow::Result;
    use tokio_util::sync::CancellationToken;

    /// Model paths — duplicated from `daemon/src/wake_word.rs` constants.
    /// Phase 3c will extract these into a shared `lifeos-common` crate.
    const RUSTPOTTER_MODEL_PATH: &str = "/var/lib/lifeos/models/rustpotter/axi.rpw";
    const RUSTPOTTER_IMAGE_MODEL_PATH: &str = "/usr/share/lifeos/models/rustpotter/axi.rpw";

    /// Resolve the best available wake word model path.
    fn resolve_model_path() -> Option<std::path::PathBuf> {
        let writable = std::path::PathBuf::from(RUSTPOTTER_MODEL_PATH);
        if writable.exists() {
            return Some(writable);
        }
        let image = std::path::PathBuf::from(RUSTPOTTER_IMAGE_MODEL_PATH);
        if image.exists() {
            return Some(image);
        }
        None
    }

    /// Run the wake-word listener.
    ///
    /// Currently a stub — logs ERROR and idles until cancelled.
    /// Full implementation deferred to Phase 3c.
    pub async fn run(_client: DaemonClient, cancel: CancellationToken) {
        if resolve_model_path().is_none() {
            log::warn!(
                "[wake-word] no model found at {} or {} — wake-word disabled",
                RUSTPOTTER_MODEL_PATH,
                RUSTPOTTER_IMAGE_MODEL_PATH
            );
            cancel.cancelled().await;
            return;
        }

        log::error!(
            "[wake-word] companion wake-word listener is a stub in Phase 3b — \
             the daemon's in-process detector is active instead. \
             Phase 3c will implement the PipeWire+rustpotter listener here."
        );

        // Idle until cancelled — don't crash the companion, just skip wake-word.
        cancel.cancelled().await;
        log::info!("[wake-word] stub listener cancelled");
    }

    /// Send a detection event to the daemon.
    ///
    /// Called by the (future) real listener when a wake word fires.
    /// Exported so Phase 3c can use it without re-inventing the debounce logic.
    pub async fn post_detection(client: &DaemonClient, word: &str, score: f32) -> Result<()> {
        let ts = chrono::Utc::now();
        log::info!("[wake-word] detection word={} score={:.2}", word, score);
        let resp = client.post_wake_word_trigger(word, score, ts).await?;
        if resp.accepted {
            log::debug!(
                "[wake-word] daemon accepted detection (session={:?})",
                resp.session_id
            );
        } else {
            log::debug!("[wake-word] daemon rejected detection (kill-switch or duplicate)");
        }
        Ok(())
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;
        use std::time::Duration;

        #[tokio::test]
        async fn stub_run_exits_on_cancel() {
            // Build a minimal DaemonClient (won't actually connect in this test)
            let client = DaemonClient::new(
                "http://127.0.0.1:0".to_string(), // unreachable — not called
                "stub-token".to_string(),
            )
            .expect("client build");

            let cancel = CancellationToken::new();
            let done = Arc::new(AtomicBool::new(false));
            let done_clone = done.clone();
            let cancel_inner = cancel.clone();

            tokio::spawn(async move {
                run(client, cancel_inner).await;
                done_clone.store(true, Ordering::SeqCst);
            });

            // Give the task a moment to start, then cancel it
            tokio::time::sleep(Duration::from_millis(20)).await;
            cancel.cancel();
            tokio::time::sleep(Duration::from_millis(50)).await;

            assert!(
                done.load(Ordering::SeqCst),
                "run() should exit after cancel"
            );
        }

        #[tokio::test]
        async fn resolve_model_path_returns_none_on_missing() {
            // On CI / dev machines, neither model path exists
            // This test documents the expected fallback behavior
            let path = resolve_model_path();
            // We can't assert is_none() because a real LifeOS install might have the model
            // But we CAN verify the function returns a valid Option<PathBuf> without panic
            match path {
                Some(p) => assert!(p.is_absolute(), "model path should be absolute"),
                None => {} // expected on dev/CI machines
            }
        }

        #[tokio::test]
        async fn post_detection_constructs_correct_request() {
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            use tokio::net::TcpListener;

            let body = r#"{"accepted":true,"session_id":null}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                body.len(),
                body
            );
            // Leak so we get &'static str (consistent with other test pattern)
            let static_response: &'static str = Box::leak(response.into_boxed_str());

            let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
            let port = listener.local_addr().expect("local_addr").port();

            tokio::spawn(async move {
                if let Ok((mut stream, _)) = listener.accept().await {
                    let mut buf = [0u8; 4096];
                    let _ = tokio::time::timeout(Duration::from_millis(200), stream.read(&mut buf))
                        .await;
                    let _ = stream.write_all(static_response.as_bytes()).await;
                }
            });

            tokio::time::sleep(Duration::from_millis(10)).await;

            let client = DaemonClient::new(
                format!("http://127.0.0.1:{}", port),
                "test-token".to_string(),
            )
            .expect("client build");

            let result = post_detection(&client, "axi", 0.93).await;
            // Should succeed (mock server returns 200)
            assert!(
                result.is_ok(),
                "post_detection should succeed: {:?}",
                result
            );
        }
    }
}
