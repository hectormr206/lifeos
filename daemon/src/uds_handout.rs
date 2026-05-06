//! Bootstrap-token handout over a Unix-domain socket authenticated by
//! `SO_PEERCRED`.
//!
//! Phase 8c — Phase 8b R9 rolled `lifeos-lifeosd` back to `Network=host`
//! after empirical validation showed netavark SNATs PublishPort traffic
//! to the bridge gateway IP (10.89.0.1), making the daemon's
//! peer-loopback gate 403 every legitimate request. The bridge migration
//! needs `SO_PEERCRED` to identify peers; this module is the smallest
//! viable seed of that work — it does NOT reshape the daemon's HTTP
//! listener (still TCP on 127.0.0.1:8081 to keep browser dashboard
//! traffic working) but it DOES expose the bootstrap token via a UDS
//! authenticated by kernel-asserted peer credentials.
//!
//! Why this matters for Phase 3b: the per-user `lifeos-desktop`
//! companion (deferred from session 2026-05-06) needs to reach the
//! daemon. The previous design read the token from a file at
//! `/run/lifeos/bootstrap.token`, but that directory is `0750 root:root`
//! by default — the `lifeos` user cannot traverse it without a tmpfiles.d
//! group rewrite, and even with that the file-on-disk model is fragile
//! to rotation races. With this handout, the companion just connects to
//! the UDS, the kernel reports its UID via `SO_PEERCRED`, and if the UID
//! matches an allowlist the daemon writes the token bytes back. No
//! filesystem perms gymnastics, no rotation races.
//!
//! Sentinel + lifeos-check + life CLI gain the same simplification.
//! The dashboard SPA (loaded by a browser) keeps the existing TCP
//! `/dashboard/bootstrap` path because browsers cannot speak Unix
//! sockets.
//!
//! Socket path: `/run/lifeos-bootstrap.sock` (top-level `/run`, NOT
//! inside `/run/lifeos/` whose `0750 root:root` would block traversal).
//! Mode: `0666`. The kernel `SO_PEERCRED` check is the security
//! boundary; the permissive file mode just lets local clients connect
//! so the daemon can identify them and reject the unauthorised ones.
//! `getsockopt(SO_PEERCRED)` cannot be forged from userland — that's
//! the entire point of the design.

use anyhow::Context;
use log::{debug, error, info, warn};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use tokio::io::AsyncWriteExt;
use tokio::net::{UnixListener, UnixStream};

/// Default location of the bootstrap-token handout socket.
pub const DEFAULT_SOCKET_PATH: &str = "/run/lifeos-bootstrap.sock";

/// UID of the `lifeos` user on the bootc image (default 1000). Override
/// via `LIFEOS_HANDOUT_UID` for development hosts where the user UID
/// differs from the production image. Root (uid 0) is always accepted
/// because system services like `lifeos-sentinel.sh` run as root.
fn allowed_uids() -> Vec<u32> {
    let mut uids = vec![0u32];
    let configured = std::env::var("LIFEOS_HANDOUT_UID")
        .ok()
        .and_then(|s| s.trim().parse::<u32>().ok())
        .unwrap_or(1000);
    if configured != 0 {
        uids.push(configured);
    }
    uids
}

/// Resolve the handout socket path, honoring `LIFEOS_HANDOUT_SOCKET`.
pub fn socket_path() -> PathBuf {
    std::env::var("LIFEOS_HANDOUT_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(DEFAULT_SOCKET_PATH))
}

/// Spawn the bootstrap-token handout listener as a background task. The
/// returned `JoinHandle` is held by `main` so the listener is torn down
/// cleanly on shutdown. Errors during bind are logged and the listener
/// is silently disabled — the daemon stays usable via the file-on-disk
/// fallback path that the existing `generate_bootstrap_token()` already
/// writes.
pub fn spawn(token: String) -> Option<tokio::task::JoinHandle<()>> {
    let path = socket_path();
    let allowed = allowed_uids();
    let listener = match bind(&path) {
        Ok(l) => l,
        Err(e) => {
            warn!(
                "bootstrap-token handout disabled: failed to bind {} ({}); \
                 clients will fall back to /run/lifeos/bootstrap.token",
                path.display(),
                e
            );
            return None;
        }
    };
    info!(
        "bootstrap-token handout listening on {} (allowed UIDs {:?})",
        path.display(),
        allowed
    );
    Some(tokio::spawn(serve(listener, token, allowed)))
}

fn bind(path: &Path) -> anyhow::Result<UnixListener> {
    // Remove any stale socket from a previous (crashed) daemon. UnixListener::bind
    // refuses to overwrite, so we have to do it ourselves; this is the standard
    // pattern for server-side UDS code in tokio.
    if path.exists() {
        let _ = std::fs::remove_file(path);
    }
    let listener = UnixListener::bind(path)
        .with_context(|| format!("UnixListener::bind({})", path.display()))?;
    // Permissive file mode (0666). The actual auth is the kernel's
    // SO_PEERCRED check inside `serve()`. World-readable would be a
    // problem ONLY if SO_PEERCRED could be forged, which it cannot — the
    // kernel writes it from the connecting process's credentials.
    let mut perms = std::fs::metadata(path)
        .with_context(|| format!("stat {}", path.display()))?
        .permissions();
    perms.set_mode(0o666);
    std::fs::set_permissions(path, perms)
        .with_context(|| format!("chmod 0666 {}", path.display()))?;
    Ok(listener)
}

async fn serve(listener: UnixListener, token: String, allowed_uids: Vec<u32>) {
    loop {
        let (stream, _addr) = match listener.accept().await {
            Ok(s) => s,
            Err(e) => {
                error!("bootstrap-token handout accept failed: {}", e);
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                continue;
            }
        };
        let token = token.clone();
        let allowed = allowed_uids.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_connection(stream, &token, &allowed).await {
                debug!("bootstrap-token handout: dropped connection ({})", e);
            }
        });
    }
}

async fn handle_connection(
    mut stream: UnixStream,
    token: &str,
    allowed_uids: &[u32],
) -> anyhow::Result<()> {
    let cred = stream
        .peer_cred()
        .context("peer_cred() failed (SO_PEERCRED unavailable on this kernel?)")?;
    let uid = cred.uid();
    if !allowed_uids.contains(&uid) {
        warn!(
            "bootstrap-token handout rejected uid={} pid={:?}",
            uid,
            cred.pid()
        );
        // Write a short rejection so the client gets a deterministic
        // error string instead of an empty read. Closing without a
        // payload would also work but produces a less useful client log.
        let _ = stream.write_all(b"FORBIDDEN\n").await;
        let _ = stream.shutdown().await;
        return Ok(());
    }
    debug!(
        "bootstrap-token handout: serving uid={} pid={:?}",
        uid,
        cred.pid()
    );
    stream.write_all(token.as_bytes()).await?;
    stream.write_all(b"\n").await?;
    stream.shutdown().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tokio::io::AsyncReadExt;

    // env-var tests share process state; serialise. Recover from
    // poisoned lock so a panicking test doesn't cascade.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn allowed_uids_includes_root_and_default_lifeos() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::remove_var("LIFEOS_HANDOUT_UID");
        let uids = allowed_uids();
        assert!(uids.contains(&0));
        assert!(uids.contains(&1000));
    }

    #[test]
    fn allowed_uids_honors_override() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::set_var("LIFEOS_HANDOUT_UID", "1234");
        let uids = allowed_uids();
        std::env::remove_var("LIFEOS_HANDOUT_UID");
        assert!(uids.contains(&0));
        assert!(uids.contains(&1234));
        assert!(!uids.contains(&1000));
    }

    #[test]
    fn allowed_uids_skips_zero_override() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::set_var("LIFEOS_HANDOUT_UID", "0");
        let uids = allowed_uids();
        std::env::remove_var("LIFEOS_HANDOUT_UID");
        assert_eq!(uids, vec![0]);
    }

    #[test]
    fn socket_path_default() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::remove_var("LIFEOS_HANDOUT_SOCKET");
        assert_eq!(socket_path(), PathBuf::from(DEFAULT_SOCKET_PATH));
    }

    #[test]
    fn socket_path_honors_override() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::set_var("LIFEOS_HANDOUT_SOCKET", "/tmp/lifeos-test.sock");
        let p = socket_path();
        std::env::remove_var("LIFEOS_HANDOUT_SOCKET");
        assert_eq!(p, PathBuf::from("/tmp/lifeos-test.sock"));
    }

    /// End-to-end test: bind on a tmp path, connect from the same
    /// process (uid will match either 0 in CI as root, or current uid
    /// otherwise), assert the returned token bytes match.
    #[tokio::test]
    async fn handout_returns_token_to_authorized_peer() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.sock");
        let token = "deadbeef".to_string();

        // The current process's UID must be in the allowlist or the
        // test would 403 itself. Add the current UID explicitly.
        let our_uid = unsafe { libc::getuid() };
        let allowed = vec![0u32, our_uid];

        // Hand-rolled bind so we control the path.
        let listener = bind(&path).unwrap();
        let listener_token = token.clone();
        let listener_allowed = allowed.clone();
        let server = tokio::spawn(async move {
            // Single-shot accept for the test.
            let (stream, _) = listener.accept().await.unwrap();
            handle_connection(stream, &listener_token, &listener_allowed)
                .await
                .unwrap();
        });

        let mut client = UnixStream::connect(&path).await.unwrap();
        let mut buf = String::new();
        client.read_to_string(&mut buf).await.unwrap();
        assert_eq!(buf.trim(), token);

        server.await.unwrap();
    }

    #[tokio::test]
    async fn handout_refuses_unauthorized_peer() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.sock");
        let token = "deadbeef".to_string();
        // Empty allowlist forces rejection — easier than spoofing a
        // different UID, which would require fork/seteuid privileges
        // tests don't have.
        let allowed: Vec<u32> = Vec::new();

        let listener = bind(&path).unwrap();
        let listener_token = token.clone();
        let listener_allowed = allowed.clone();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            handle_connection(stream, &listener_token, &listener_allowed)
                .await
                .unwrap();
        });

        let mut client = UnixStream::connect(&path).await.unwrap();
        let mut buf = String::new();
        client.read_to_string(&mut buf).await.unwrap();
        assert!(
            buf.contains("FORBIDDEN"),
            "expected FORBIDDEN, got {:?}",
            buf
        );
        assert!(!buf.contains(&token), "token leaked to unauthorized peer");
        server.await.unwrap();
    }
}
