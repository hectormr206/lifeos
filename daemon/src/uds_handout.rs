//! Bootstrap-token handout over a Unix-domain socket authenticated by
//! `SO_PEERCRED`.
//!
//! Phase 8c — Phase 8b R9 rolled `lifeos-lifeosd` back to `Network=host`
//! after empirical validation showed netavark SNATs PublishPort traffic
//! to the bridge gateway IP (10.89.0.1). This module is the smallest
//! viable Unix-socket-based identity check that the broader Phase 8b
//! follow-up needs. It does NOT reshape the daemon's HTTP listener
//! (still TCP on 127.0.0.1:8081 so the browser dashboard keeps working)
//! but it DOES expose the bootstrap token via a UDS authenticated by
//! kernel-asserted peer credentials.
//!
//! Why for Phase 3b: the per-user `lifeos-desktop` companion needs the
//! bootstrap token, but the file at `/run/lifeos/bootstrap.token` lives
//! in a directory whose perms make non-root traversal painful (see
//! `tmpfiles.d/lifeos-runtime.conf`). With this handout, the companion
//! just connects to the socket and the kernel certifies its UID; if the
//! UID is in the allowlist the daemon writes the token bytes back. No
//! file-perm gymnastics, no rotation race, no setuid helper.
//!
//! Sentinel + lifeos-check + life CLI gain the same simplification.
//! The dashboard SPA keeps the existing TCP `/dashboard/bootstrap` path
//! because browsers cannot speak Unix sockets.
//!
//! Socket path: `/run/lifeos/lifeos-bootstrap.sock`. Round-2 JD caught
//! that the original choice (`/run/lifeos-bootstrap.sock` at the top of
//! `/run`) was invisible to host clients because `lifeos-lifeosd` runs
//! as a Quadlet container with its own mount namespace — the container's
//! `/run/` is private tmpfs, only `/run/lifeos/` is bind-mounted from
//! the host. Putting the socket inside the bind-mounted directory lets
//! both sides see it; the directory perms are tightened to `0751 root:root`
//! by `lifeos-runtime.conf` — `--x` for other lets the user session
//! `connect()` to the known socket path while blocking `readdir(2)` so
//! non-root cannot enumerate filenames in `/run/lifeos/`.
//!
//! File mode: `0666`. The kernel `SO_PEERCRED` check is the security
//! boundary; the permissive file mode just lets local clients reach
//! the listener. `getsockopt(SO_PEERCRED)` returns the credentials at
//! `connect(2)` time, NOT current credentials, and is filled by the
//! kernel from the connecting process's task struct — userland cannot
//! forge it. (A process can `connect()` and then `setuid()` to drop
//! privileges; the daemon still sees the original UID. That's
//! acceptable for this threat model — root-equivalent local exploit.)

use anyhow::Context;
use log::{debug, error, info, warn};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::Semaphore;
use tokio::time::Duration;

/// Default location of the bootstrap-token handout socket. Lives inside
/// the host-bind-mounted `/run/lifeos/` so both the containerized
/// daemon and the host clients see the same inode.
pub const DEFAULT_SOCKET_PATH: &str = "/run/lifeos/lifeos-bootstrap.sock";

/// Maximum simultaneous in-flight handout handlers. R1 JD B caught that
/// an unbounded accept loop is a DoS surface (a hostile local UID can
/// open thousands of connections to spawn thousands of tokio tasks). 32
/// is generous for legitimate use (one client at a time, request-reply
/// finishes in milliseconds) and trivial to enforce via Semaphore.
const HANDLER_PERMITS: usize = 32;

/// Per-handler write/read deadline. `peer_cred()` is sync-fast, but
/// `write_all` could block indefinitely if a hostile client refuses to
/// drain its recv buffer. 2 s is plenty for a hex token + newline.
const HANDLER_TIMEOUT: Duration = Duration::from_secs(2);

/// UID of the `lifeos` user on the bootc image (default 1000). Override
/// via `LIFEOS_HANDOUT_UID` for development hosts where the user UID
/// differs from the production image. Root (uid 0) is always accepted
/// because system services like `lifeos-sentinel.sh` run as root.
///
/// Allowlist is captured ONCE at `spawn()` time — runtime changes to
/// `LIFEOS_HANDOUT_UID` do not widen the allowlist on the fly. This is
/// intentional: an attacker who can rewrite the daemon's environment
/// after start could otherwise grant themselves access without
/// restarting the service.
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

/// Spawn the bootstrap-token handout listener as a background task.
/// On bind failure, logs a WARN and returns `None`; clients fall back
/// to the legacy `/run/lifeos/bootstrap.token` file.
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
    let token = Arc::<str>::from(token);
    let allowed = Arc::<[u32]>::from(allowed.into_boxed_slice());
    Some(tokio::spawn(serve(listener, token, allowed)))
}

fn bind(path: &Path) -> anyhow::Result<UnixListener> {
    // The previous `path.exists()` + `remove_file()` + `bind()` chain
    // had a small attack surface: a privileged-equivalent attacker
    // could swap the path for a symlink before the unlink. Round-2
    // narrowed it with a `symlink_metadata()` precheck — refuse to
    // remove unless the path is `S_IFSOCK` and `uid == 0`. Round-3
    // honest acknowledgement: this defends only against NON-root
    // pre-planting. A root-equivalent attacker can race any number
    // of `unlink`/`bind` syscalls and we cannot close that window
    // without `openat2(RESOLVE_NO_SYMLINKS)` + `unlinkat(parent_fd)`,
    // which is overkill for the threat model — a root attacker
    // already controls the daemon. Leaving the precheck because it
    // catches misconfigured environments and bad rollback states
    // cheaply.
    if let Ok(meta) = std::fs::symlink_metadata(path) {
        let mode = meta.mode();
        let is_socket = (mode & libc::S_IFMT) == libc::S_IFSOCK;
        if !is_socket {
            anyhow::bail!(
                "{} exists but is not a socket (mode 0o{:o}); refusing to remove",
                path.display(),
                mode & libc::S_IFMT
            );
        }
        if meta.uid() != 0 {
            anyhow::bail!(
                "{} is owned by uid={} (expected root); refusing to remove",
                path.display(),
                meta.uid()
            );
        }
        std::fs::remove_file(path)
            .with_context(|| format!("remove stale socket {}", path.display()))?;
    }

    // Round-3 JD A+B: the previous `umask(0o111)` dance was a real
    // bug. `umask()` is process-global, not thread-local. Daemon
    // startup spawns many concurrent tokio tasks (telemetry,
    // sensory_pipeline, browser_automation, experience_modes …) that
    // create files; any file create that happened between the two
    // umask calls would inherit the relaxed mask and be born 0666.
    // The single chmod immediately after bind is sufficient on its
    // own — the only window where the socket exists with the
    // process's default umask perms (typically 0755) is the few
    // microseconds between bind() returning and set_permissions()
    // returning. During that window the kernel still gates connects
    // by directory perms; a peer that wins the race connects to a
    // socket where SO_PEERCRED still fires correctly inside
    // handle_connection. Information leak: zero — the rejection
    // payload is the same `FORBIDDEN`. Drop the umask trick.
    let listener = UnixListener::bind(path)
        .with_context(|| format!("UnixListener::bind({})", path.display()))?;

    let mut perms = std::fs::metadata(path)
        .with_context(|| format!("stat {}", path.display()))?
        .permissions();
    perms.set_mode(0o666);
    std::fs::set_permissions(path, perms)
        .with_context(|| format!("chmod 0666 {}", path.display()))?;
    Ok(listener)
}

async fn serve(listener: UnixListener, token: Arc<str>, allowed_uids: Arc<[u32]>) {
    let permits = Arc::new(Semaphore::new(HANDLER_PERMITS));
    loop {
        // Round-3 JD A+B: acquire the permit BEFORE accept so the loop
        // itself back-pressures. Holding the permit while we wait for a
        // connection is the desired behaviour — it caps the number of
        // accepted-but-unhandled streams (each consuming an fd) at
        // HANDLER_PERMITS. Round-2 acquired the permit AFTER spawn,
        // letting a flooder grow the tokio task queue without bound and
        // exhausting RLIMIT_NOFILE before HANDLER_PERMITS ever caught up.
        let permit = match permits.clone().acquire_owned().await {
            Ok(p) => p,
            Err(_) => return, // semaphore closed → daemon shutting down
        };
        let (stream, _addr) = match listener.accept().await {
            Ok(s) => s,
            Err(e) => {
                error!("bootstrap-token handout accept failed: {}", e);
                drop(permit);
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        let token = token.clone();
        let allowed = allowed_uids.clone();
        tokio::spawn(async move {
            let _permit = permit; // released when this task returns
            match tokio::time::timeout(HANDLER_TIMEOUT, handle_connection(stream, &token, &allowed))
                .await
            {
                Ok(Ok(())) => {}
                Ok(Err(e)) => debug!("bootstrap-token handout: dropped connection ({})", e),
                Err(_) => debug!(
                    "bootstrap-token handout: handler exceeded {:?}, aborting",
                    HANDLER_TIMEOUT
                ),
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
        // Deterministic rejection payload so clients can distinguish
        // "daemon refused" from "daemon hung". The literal `FORBIDDEN`
        // is what `cli/src/daemon_client.rs::read_token_from_handout`
        // matches via `starts_with` — keep the prefix stable; a
        // future diagnostic suffix (e.g. `FORBIDDEN: uid=N`) is
        // permitted but only after the prefix.
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
    /// otherwise), assert the returned token bytes match. Holds the
    /// ENV_LOCK because sibling tests in this module mutate
    /// `LIFEOS_HANDOUT_UID` / `LIFEOS_HANDOUT_SOCKET`, and parallel
    /// test runs would race on those env vars (the process-wide umask
    /// rationale that justified this lock in round-2 was removed when
    /// round-3 dropped the `umask()` manipulation).
    ///
    /// `clippy::await_holding_lock` is allowed: the lock is a serializer
    /// over process-global env-var state for tests, NOT a synchronisation
    /// primitive across tasks — only one tokio task in the test ever
    /// holds it at a time, and the test runs single-threaded by virtue
    /// of `cargo test`'s default scheduling semantics for blocking
    /// `Mutex`. The async work inside the critical section is local to
    /// the test (`tokio::spawn` for the server half, then awaits) and
    /// never re-enters this module. Replacing with `tokio::sync::Mutex`
    /// would require an async test setup helper that buys nothing.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn handout_returns_token_to_authorized_peer() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
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

    /// R1 JD A SUGGESTION: prove `peer_cred()` actually returns the
    /// real Linux ucred, not a constant. If a future tokio change
    /// stubbed peer_cred to always return uid 0, the previous test
    /// would still pass tautologically. This one binds the listener,
    /// connects from the test process, and asserts the daemon-side
    /// peer_cred uid matches our own getuid() — anchoring the
    /// authentication to a real syscall result.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn peer_cred_returns_real_uid_of_connecting_process() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.sock");
        let listener = bind(&path).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            stream.peer_cred().unwrap().uid()
        });
        let _client = UnixStream::connect(&path).await.unwrap();
        let observed_uid = server.await.unwrap();
        let real_uid = unsafe { libc::getuid() };
        assert_eq!(observed_uid, real_uid);
    }

    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn handout_refuses_unauthorized_peer() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
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
