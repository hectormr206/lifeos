//! Bootstrap: daemon socket waiting + token acquisition + health probing.
//!
//! The companion is socket-only by design — UID 1000 is always allowed.
//! No file-on-disk fallback (that's the CLI's responsibility).

use crate::daemon_client::DaemonClient;
use anyhow::{bail, Context, Result};
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::UnixStream;

/// Poll for socket existence with 500ms backoff, up to `max_wait`.
///
/// Returns `Ok(())` when the socket file appears on the filesystem.
/// Returns `Err` if the timeout expires before the socket appears.
pub async fn wait_for_socket(socket_path: &Path, max_wait: Duration) -> Result<()> {
    let deadline = tokio::time::Instant::now() + max_wait;
    loop {
        if tokio::fs::try_exists(socket_path).await.unwrap_or(false) {
            return Ok(());
        }
        if tokio::time::Instant::now() >= deadline {
            bail!(
                "bootstrap socket never appeared at {} within {:?}",
                socket_path.display(),
                max_wait
            );
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

/// Connect to the daemon's UDS handout socket and read the bootstrap token.
///
/// The daemon writes one line: the token, or "FORBIDDEN..." on UID mismatch.
/// An empty line or any line starting with "FORBIDDEN" is rejected.
pub async fn read_bootstrap_token(socket_path: &Path) -> Result<String> {
    let stream = tokio::time::timeout(Duration::from_secs(5), UnixStream::connect(socket_path))
        .await
        .context("timeout connecting to bootstrap socket")?
        .with_context(|| {
            format!(
                "failed to connect to bootstrap socket: {}",
                socket_path.display()
            )
        })?;

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    tokio::time::timeout(Duration::from_secs(5), reader.read_line(&mut line))
        .await
        .context("timeout reading bootstrap token")??;

    let token = line.trim().to_string();

    if token.is_empty() {
        bail!("bootstrap socket returned an empty token");
    }
    if token.starts_with("FORBIDDEN") {
        bail!(
            "bootstrap socket rejected our UID — check daemon allowlist (got: {})",
            token
        );
    }

    Ok(token)
}

/// Probe `/api/v1/health` until the daemon responds with a healthy status,
/// retrying every 1s up to `max_wait`.
pub async fn probe_health_until_ready(client: &DaemonClient, max_wait: Duration) -> Result<()> {
    let deadline = tokio::time::Instant::now() + max_wait;
    let mut last_err: Option<anyhow::Error> = None;

    loop {
        match client.health().await {
            Ok(report) if report.healthy => {
                log::info!("[desktop] daemon healthy (score={})", report.score);
                return Ok(());
            }
            Ok(report) => {
                log::debug!(
                    "[desktop] health probe: not healthy yet (score={})",
                    report.score
                );
            }
            Err(e) => {
                log::debug!("[desktop] health probe error: {}", e);
                last_err = Some(e);
            }
        }

        if tokio::time::Instant::now() >= deadline {
            let msg = last_err
                .map(|e| e.to_string())
                .unwrap_or_else(|| "daemon not healthy within timeout".to_string());
            bail!("health probe timed out after {:?}: {}", max_wait, msg);
        }

        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;
    use tokio::net::UnixListener;

    /// Helper: bind a temporary UDS, accept one connection, write `payload`, close.
    async fn serve_once(path: &Path, payload: &'static str) {
        let listener = UnixListener::bind(path).expect("bind failed");
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let _ = stream.write_all(payload.as_bytes()).await;
                // Drop closes the stream, signaling EOF to the reader
            }
        });
    }

    #[tokio::test]
    async fn token_read_happy_path() {
        let dir = tempdir();
        let socket_path = dir.join("bootstrap-happy.sock");

        serve_once(&socket_path, "test-token-abc123\n").await;

        // Small delay so the spawn has time to start accepting
        tokio::time::sleep(Duration::from_millis(10)).await;

        let token = read_bootstrap_token(&socket_path)
            .await
            .expect("should succeed");
        assert_eq!(token, "test-token-abc123");

        drop(dir);
    }

    #[tokio::test]
    async fn token_read_rejects_forbidden() {
        let dir = tempdir();
        let socket_path = dir.join("bootstrap-forbidden.sock");

        serve_once(&socket_path, "FORBIDDEN: uid=999\n").await;
        tokio::time::sleep(Duration::from_millis(10)).await;

        let result = read_bootstrap_token(&socket_path).await;
        assert!(result.is_err(), "FORBIDDEN should be rejected");
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("FORBIDDEN"),
            "error should mention FORBIDDEN, got: {}",
            msg
        );

        drop(dir);
    }

    #[tokio::test]
    async fn wait_for_socket_times_out_when_absent() {
        let dir = tempdir();
        let socket_path = dir.join("nonexistent.sock");

        // Use a very short timeout so the test completes quickly
        let result = wait_for_socket(&socket_path, Duration::from_millis(600)).await;
        assert!(result.is_err(), "should time out when socket is absent");

        drop(dir);
    }

    #[tokio::test]
    async fn wait_for_socket_succeeds_when_socket_exists() {
        let dir = tempdir();
        let socket_path = dir.join("exists.sock");

        // Create the file first (bind a listener so the path exists as a socket)
        let _listener = UnixListener::bind(&socket_path).expect("bind failed");

        let result = wait_for_socket(&socket_path, Duration::from_millis(500)).await;
        assert!(
            result.is_ok(),
            "should succeed when socket exists: {:?}",
            result
        );

        drop(dir);
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    fn tempdir() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "lifeos-desktop-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .subsec_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("create tempdir");
        dir
    }
}
