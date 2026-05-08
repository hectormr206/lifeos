//! Shared daemon client over Unix-domain socket (UDS).
//!
//! All CLI commands that talk to the lifeosd API should use this module.
//!
//! ## Transport model
//!
//! Every CLI command connects to the daemon via the UDS socket at
//! `/run/lifeos/lifeosd.sock` (overridable via `LIFEOS_API_SOCKET`).
//! The daemon's `serve_uds_loop` enforces kernel-level `SO_PEERCRED` UID
//! checks before the request reaches the router — defense-in-depth with
//! no network stack involved.
//!
//! ## Usage
//!
//! - `get_json::<R>(path)` — GET request, deserialize JSON response
//! - `post_json::<T, R>(path, &body)` — POST with JSON body, deserialize response
//! - `post_empty::<R>(path)` — POST with no body, deserialize response
//! - `delete_json::<R>(path)` — DELETE request, deserialize JSON response
//! - `daemon_socket_path()` — resolved UDS socket path (reads `LIFEOS_API_SOCKET`)

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::Uri;
use hyper_util::client::legacy::connect::Connection;
use hyper_util::client::legacy::Client;
use hyper_util::rt::{TokioExecutor, TokioIo};
use std::future::Future;
use std::io::{BufRead, BufReader, IsTerminal};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::process::Command;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::net::UnixStream as TokioUnixStream;
use tower_service::Service;

const TOKEN_FILENAME: &str = "bootstrap.token";
const DEFAULT_HANDOUT_SOCKET: &str = "/run/lifeos/lifeos-bootstrap.sock";

/// Returns the path to the daemon API Unix-domain socket.
/// Reads `LIFEOS_API_SOCKET` from the environment; falls back to the
/// compile-time default `/run/lifeos/lifeosd.sock`.
pub fn daemon_socket_path() -> PathBuf {
    std::env::var("LIFEOS_API_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/run/lifeos/lifeosd.sock"))
}

// ─── UDS connector ───────────────────────────────────────────────────────────

/// A `tower::Service` connector that resolves any `Uri` to the daemon's
/// Unix-domain socket path. The URI scheme and host are ignored; every
/// connection goes to `daemon_socket_path()`.
#[derive(Clone, Debug)]
pub struct UnixConnector {
    socket_path: PathBuf,
}

impl UnixConnector {
    pub fn new(socket_path: PathBuf) -> Self {
        Self { socket_path }
    }
}

/// A connection wrapper that marks the stream as not reusable across
/// different hosts (UDS has no "host" concept; each call connects to
/// the same socket path).
pub struct UnixConnection(TokioIo<TokioUnixStream>);

impl hyper::rt::Read for UnixConnection {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: hyper::rt::ReadBufCursor<'_>,
    ) -> Poll<Result<(), std::io::Error>> {
        Pin::new(&mut self.0).poll_read(cx, buf)
    }
}

impl hyper::rt::Write for UnixConnection {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<Result<usize, std::io::Error>> {
        Pin::new(&mut self.0).poll_write(cx, buf)
    }

    fn poll_flush(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Result<(), std::io::Error>> {
        Pin::new(&mut self.0).poll_flush(cx)
    }

    fn poll_shutdown(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Result<(), std::io::Error>> {
        Pin::new(&mut self.0).poll_shutdown(cx)
    }
}

impl Connection for UnixConnection {
    fn connected(&self) -> hyper_util::client::legacy::connect::Connected {
        hyper_util::client::legacy::connect::Connected::new()
    }
}

impl Service<Uri> for UnixConnector {
    type Response = UnixConnection;
    type Error = std::io::Error;
    type Future = Pin<Box<dyn Future<Output = Result<Self::Response, Self::Error>> + Send>>;

    fn poll_ready(&mut self, _cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, _uri: Uri) -> Self::Future {
        let path = self.socket_path.clone();
        Box::pin(async move {
            let stream = TokioUnixStream::connect(path).await?;
            Ok(UnixConnection(TokioIo::new(stream)))
        })
    }
}

// ─── Bootstrap token retrieval ───────────────────────────────────────────────

/// Read the bootstrap token via the daemon's SO_PEERCRED-authenticated
/// handout socket (Phase 8c). The kernel reports the calling process's
/// UID at `connect(2)` time; the daemon writes the token bytes back if
/// the UID is in its allowlist (root + LIFEOS_HANDOUT_UID, default
/// 1000), else a payload starting with the literal "FORBIDDEN".
///
/// Returns `None` when the socket is missing, unreachable, or the
/// daemon refused — the caller falls through to the file-on-disk path
/// for legacy hosts.
fn read_token_from_handout() -> Option<String> {
    let path = std::env::var("LIFEOS_HANDOUT_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(DEFAULT_HANDOUT_SOCKET));
    if !Path::new(&path).exists() {
        return None;
    }
    let stream = UnixStream::connect(&path).ok()?;
    // 500 ms is plenty — the daemon writes the token + newline + closes
    // without waiting for any client input. Anything slower indicates
    // the daemon is stuck and we fall back rather than hang the CLI.
    // Set both read AND write timeouts (the latter would matter only
    // if a future change introduces a client→daemon payload, but
    // defence-in-depth is cheap).
    if stream
        .set_read_timeout(Some(Duration::from_millis(500)))
        .is_err()
    {
        return None;
    }
    let _ = stream.set_write_timeout(Some(Duration::from_millis(500)));
    // No payload — SO_PEERCRED is filled by the kernel at accept(2)
    // time on the daemon side; the empty write the previous version
    // attempted was a no-op. Read exactly one line (Round-3 JD B):
    // `BufReader::read_line` stops at the first `\n` so a future
    // multi-line payload (e.g. diagnostic suffix on the FORBIDDEN
    // path, or accidental log spew) does not leak into the token
    // value. `read_to_string` would have concatenated it all.
    let mut reader = BufReader::new(stream);
    let mut buf = String::new();
    reader.read_line(&mut buf).ok()?;
    let token = buf.trim();
    // R1 JD: match the FORBIDDEN prefix (not exact string) so the
    // daemon can later add a diagnostic suffix like "FORBIDDEN: uid=N"
    // without poisoning the token field with a bogus value.
    if token.is_empty() || token.starts_with("FORBIDDEN") {
        None
    } else {
        Some(token.to_string())
    }
}

/// Read the bootstrap token from the runtime directory.
///
/// Search order: `$LIFEOS_RUNTIME_DIR`, `$XDG_RUNTIME_DIR/lifeos`,
/// `$HOME/.local/state/lifeos/runtime`, `/run/lifeos`.
fn read_bootstrap_token() -> Option<String> {
    // 1) Explicit token override for automation/testing
    if let Ok(token) = std::env::var("LIFEOS_BOOTSTRAP_TOKEN") {
        let token = token.trim().to_string();
        if !token.is_empty() {
            return Some(token);
        }
    }

    // 2) Phase 8c: SO_PEERCRED-authenticated handout socket. No sudo
    // prompt, no file-perm gymnastics — the kernel certifies the
    // CLI's UID and the daemon hands back the token if it's in the
    // allowlist. Falls through silently when the socket is absent
    // (legacy hosts) or refused (UID not whitelisted).
    if let Some(token) = read_token_from_handout() {
        return Some(token);
    }

    for token_path in bootstrap_token_candidates() {
        // 3) Direct read (works when running as root or token is world/group readable)
        if let Some(token) = std::fs::read_to_string(&token_path)
            .ok()
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
        {
            return Some(token);
        }

        // 4) Best-effort privileged read without prompting (fails fast if sudo is unavailable)
        if let Some(token) = Command::new("sudo")
            .arg("-n")
            .arg("cat")
            .arg(&token_path)
            .output()
            .ok()
            .filter(|output| output.status.success())
            .and_then(|output| String::from_utf8(output.stdout).ok())
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
        {
            return Some(token);
        }

        // 5) Interactive sudo fallback for terminal users.
        // This resolves 401 errors on systems where the token is root-only.
        if std::io::stdin().is_terminal() {
            if let Some(token) = Command::new("sudo")
                .arg("cat")
                .arg(&token_path)
                .output()
                .ok()
                .filter(|output| output.status.success())
                .and_then(|output| String::from_utf8(output.stdout).ok())
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty())
            {
                return Some(token);
            }
        }
    }

    None
}

fn bootstrap_token_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();

    if let Ok(runtime_dir) = std::env::var("LIFEOS_RUNTIME_DIR") {
        let runtime_dir = runtime_dir.trim();
        if !runtime_dir.is_empty() {
            candidates.push(PathBuf::from(runtime_dir).join(TOKEN_FILENAME));
        }
    }

    if let Ok(xdg_runtime_dir) = std::env::var("XDG_RUNTIME_DIR") {
        let xdg_runtime_dir = xdg_runtime_dir.trim();
        if !xdg_runtime_dir.is_empty() {
            candidates.push(
                PathBuf::from(xdg_runtime_dir)
                    .join("lifeos")
                    .join(TOKEN_FILENAME),
            );
        }
    }

    if let Ok(home) = std::env::var("HOME") {
        let home = home.trim();
        if !home.is_empty() {
            candidates.push(
                PathBuf::from(home)
                    .join(".local/state/lifeos/runtime")
                    .join(TOKEN_FILENAME),
            );
        }
    }

    candidates.push(PathBuf::from("/run/lifeos").join(TOKEN_FILENAME));
    candidates
}

// ─── High-level UDS request helpers ──────────────────────────────────────────
//
// These wrappers reduce each CLI call site to one line.  They build a hyper
// HTTP/1.1 request over the UDS connector, attach the bootstrap token header,
// read+collect the response body, enforce 2xx, and deserialize JSON.
//
// The `_at(socket_path, path, …)` variants accept an explicit socket path for
// unit testing.  The public `get_json / post_json / delete_json / post_empty`
// functions use `daemon_socket_path()` as the default.

/// Internal: send a hyper request over UDS at `socket_path`, collect body,
/// and return `(status_code, body_bytes)`.
async fn uds_send_at(
    socket_path: &std::path::Path,
    req: hyper::Request<Full<Bytes>>,
) -> anyhow::Result<(u16, Bytes)> {
    let connector = UnixConnector::new(socket_path.to_path_buf());
    let client = Client::builder(TokioExecutor::new()).build(connector);
    let resp = client
        .request(req)
        .await
        .map_err(|e| anyhow::anyhow!("UDS request failed: {e}"))?;
    let status = resp.status().as_u16();
    let body_bytes = resp
        .into_body()
        .collect()
        .await
        .map_err(|e| anyhow::anyhow!("Failed to read response body: {e}"))?
        .to_bytes();
    Ok((status, body_bytes))
}

/// Build the standard daemon auth header value, or empty string when the token
/// is unavailable (daemon will reply 401 in that case).
fn token_header_value() -> String {
    bootstrap_token().unwrap_or_default()
}

/// GET `path` over UDS at `socket_path`, deserialize the JSON response body as `R`.
/// Surfaces non-2xx responses as an `Err` with the status code and body text.
async fn get_json_at<R: serde::de::DeserializeOwned>(
    socket_path: &std::path::Path,
    path: &str,
) -> anyhow::Result<R> {
    let req = hyper::Request::builder()
        .method("GET")
        .uri(format!("http://localhost{}", path))
        .header("x-bootstrap-token", token_header_value())
        .header("content-length", "0")
        .body(Full::new(Bytes::new()))?;
    let (status, body) = uds_send_at(socket_path, req).await?;
    if !(200..300).contains(&status) {
        let text = String::from_utf8_lossy(&body).into_owned();
        anyhow::bail!("daemon returned HTTP {}: {}", status, text);
    }
    serde_json::from_slice(&body).map_err(|e| anyhow::anyhow!("JSON decode failed: {e}"))
}

/// POST `path` with JSON body `payload` over UDS at `socket_path`, deserialize response as `R`.
async fn post_json_at<T: serde::Serialize, R: serde::de::DeserializeOwned>(
    socket_path: &std::path::Path,
    path: &str,
    payload: &T,
) -> anyhow::Result<R> {
    let body_bytes = serde_json::to_vec(payload)?;
    let content_length = body_bytes.len().to_string();
    let req = hyper::Request::builder()
        .method("POST")
        .uri(format!("http://localhost{}", path))
        .header("x-bootstrap-token", token_header_value())
        .header("content-type", "application/json")
        .header("content-length", content_length)
        .body(Full::new(Bytes::from(body_bytes)))?;
    let (status, body) = uds_send_at(socket_path, req).await?;
    if !(200..300).contains(&status) {
        let text = String::from_utf8_lossy(&body).into_owned();
        anyhow::bail!("daemon returned HTTP {}: {}", status, text);
    }
    serde_json::from_slice(&body).map_err(|e| anyhow::anyhow!("JSON decode failed: {e}"))
}

/// DELETE `path` over UDS at `socket_path`, deserialize response as `R`.
async fn delete_json_at<R: serde::de::DeserializeOwned>(
    socket_path: &std::path::Path,
    path: &str,
) -> anyhow::Result<R> {
    let req = hyper::Request::builder()
        .method("DELETE")
        .uri(format!("http://localhost{}", path))
        .header("x-bootstrap-token", token_header_value())
        .header("content-length", "0")
        .body(Full::new(Bytes::new()))?;
    let (status, body) = uds_send_at(socket_path, req).await?;
    if !(200..300).contains(&status) {
        let text = String::from_utf8_lossy(&body).into_owned();
        anyhow::bail!("daemon returned HTTP {}: {}", status, text);
    }
    serde_json::from_slice(&body).map_err(|e| anyhow::anyhow!("JSON decode failed: {e}"))
}

/// POST `path` with an EMPTY body over UDS at `socket_path`, deserialize response as `R`.
/// Used for toggle/action endpoints that take no request payload.
async fn post_empty_at<R: serde::de::DeserializeOwned>(
    socket_path: &std::path::Path,
    path: &str,
) -> anyhow::Result<R> {
    let req = hyper::Request::builder()
        .method("POST")
        .uri(format!("http://localhost{}", path))
        .header("x-bootstrap-token", token_header_value())
        .header("content-length", "0")
        .body(Full::new(Bytes::new()))?;
    let (status, body) = uds_send_at(socket_path, req).await?;
    if !(200..300).contains(&status) {
        let text = String::from_utf8_lossy(&body).into_owned();
        anyhow::bail!("daemon returned HTTP {}: {}", status, text);
    }
    serde_json::from_slice(&body).map_err(|e| anyhow::anyhow!("JSON decode failed: {e}"))
}

// ── Public API ────────────────────────────────────────────────────────────────

/// GET `path` from the daemon API over UDS, deserialize JSON as `R`.
pub async fn get_json<R: serde::de::DeserializeOwned>(path: &str) -> anyhow::Result<R> {
    let sock = daemon_socket_path();
    if !sock.exists() {
        anyhow::bail!(
            "daemon socket not found at {} — is lifeosd running?",
            sock.display()
        );
    }
    get_json_at(&sock, path).await
}

/// POST `path` with JSON `payload` to the daemon API over UDS, deserialize response as `R`.
pub async fn post_json<T: serde::Serialize, R: serde::de::DeserializeOwned>(
    path: &str,
    payload: &T,
) -> anyhow::Result<R> {
    let sock = daemon_socket_path();
    if !sock.exists() {
        anyhow::bail!(
            "daemon socket not found at {} — is lifeosd running?",
            sock.display()
        );
    }
    post_json_at(&sock, path, payload).await
}

/// DELETE `path` from the daemon API over UDS, deserialize response as `R`.
pub async fn delete_json<R: serde::de::DeserializeOwned>(path: &str) -> anyhow::Result<R> {
    let sock = daemon_socket_path();
    if !sock.exists() {
        anyhow::bail!(
            "daemon socket not found at {} — is lifeosd running?",
            sock.display()
        );
    }
    delete_json_at(&sock, path).await
}

/// POST `path` with no body to the daemon API over UDS, deserialize response as `R`.
pub async fn post_empty<R: serde::de::DeserializeOwned>(path: &str) -> anyhow::Result<R> {
    let sock = daemon_socket_path();
    if !sock.exists() {
        anyhow::bail!(
            "daemon socket not found at {} — is lifeosd running?",
            sock.display()
        );
    }
    post_empty_at(&sock, path).await
}

/// Returns the bootstrap token string, if available. Used by callers
/// that need to inject the token header manually (e.g. into hyper
/// requests over the UDS client).
pub fn bootstrap_token() -> Option<String> {
    read_bootstrap_token()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UnixListener;

    // Helper: spin a one-shot HTTP/1.1 server over a UnixListener.
    // Serves `status_line` + JSON body `json_body` (or raw bytes for body).
    async fn serve_once(
        listener: UnixListener,
        status_code: u16,
        json_body: &'static str,
    ) -> tokio::task::JoinHandle<()> {
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buf = [0u8; 8192];
            let _ =
                tokio::time::timeout(std::time::Duration::from_millis(300), stream.read(&mut buf))
                    .await;
            let reason = if status_code == 200 { "OK" } else { "Error" };
            let response = format!(
                "HTTP/1.1 {} {}\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{}",
                status_code, reason,
                json_body.len(),
                json_body
            );
            stream.write_all(response.as_bytes()).await.unwrap();
        })
    }

    // ── RED tests for get_json / post_json / delete_json / post_empty ────────

    // get_json_returns_deserialized_value: [RED] get_json does not exist yet.
    // Expects get_json("/health") to call the UDS socket and deserialize JSON.
    #[tokio::test]
    async fn get_json_returns_deserialized_value() {
        let dir = TempDir::new().unwrap();
        let sock = dir.path().join("test.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        serve_once(listener, 200, r#"{"status":"ok"}"#).await;
        let result: serde_json::Value = get_json_at(&sock, "/health").await.unwrap();
        assert_eq!(result["status"], "ok");
    }

    // get_json_surfaces_non_2xx_as_error: [RED] get_json does not exist yet.
    // A 404 response must propagate as an Err containing the status code.
    #[tokio::test]
    async fn get_json_surfaces_non_2xx_as_error() {
        let dir = TempDir::new().unwrap();
        let sock = dir.path().join("test.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        serve_once(listener, 404, r#"{"error":"not found"}"#).await;
        let result: anyhow::Result<serde_json::Value> = get_json_at(&sock, "/missing").await;
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("404"), "expected 404 in error, got: {msg}");
    }

    // post_json_sends_body_and_returns_deserialized: [RED] post_json does not exist yet.
    #[tokio::test]
    async fn post_json_sends_body_and_returns_deserialized() {
        let dir = TempDir::new().unwrap();
        let sock = dir.path().join("test.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        serve_once(listener, 200, r#"{"ack":true}"#).await;
        let body = serde_json::json!({"mode": "pro"});
        let result: serde_json::Value = post_json_at(&sock, "/api/v1/mode/set", &body)
            .await
            .unwrap();
        assert_eq!(result["ack"], true);
    }

    // delete_json_returns_deserialized: [RED] delete_json does not exist yet.
    #[tokio::test]
    async fn delete_json_returns_deserialized() {
        let dir = TempDir::new().unwrap();
        let sock = dir.path().join("test.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        serve_once(listener, 200, r#"{"deleted":true}"#).await;
        let result: serde_json::Value = delete_json_at(&sock, "/api/v1/mode/custom/foo")
            .await
            .unwrap();
        assert_eq!(result["deleted"], true);
    }

    // post_empty_returns_deserialized: [RED] post_empty does not exist yet.
    // POST with no body (used for toggle/action endpoints).
    #[tokio::test]
    async fn post_empty_returns_deserialized() {
        let dir = TempDir::new().unwrap();
        let sock = dir.path().join("test.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        serve_once(listener, 200, r#"{"triggered":true}"#).await;
        let result: serde_json::Value =
            post_empty_at(&sock, "/api/v1/overlay/clear").await.unwrap();
        assert_eq!(result["triggered"], true);
    }

    // 4.2 RED→GREEN: daemon_socket_path reads LIFEOS_API_SOCKET env var
    // and returns default when env var is absent. Run under a mutex to
    // prevent parallel tests from clobbering the process-global env.
    #[test]
    fn daemon_socket_path_env_var_and_default() {
        // Serialize env-var tests in this module — env is process-global.
        use std::sync::Mutex;
        static ENV_LOCK: Mutex<()> = Mutex::new(());
        let _guard = ENV_LOCK.lock().unwrap();

        // Case 1: env var set → use it
        unsafe { std::env::set_var("LIFEOS_API_SOCKET", "/tmp/test.sock") };
        let path = daemon_socket_path();
        assert_eq!(path, std::path::PathBuf::from("/tmp/test.sock"));

        // Case 2: env var absent → default
        unsafe { std::env::remove_var("LIFEOS_API_SOCKET") };
        let path = daemon_socket_path();
        assert_eq!(path, std::path::PathBuf::from("/run/lifeos/lifeosd.sock"));
    }

    // 4.3 RED→GREEN: cli reports actionable error when socket missing
    #[tokio::test]
    async fn cli_reports_actionable_error_when_socket_missing() {
        use std::sync::Mutex;
        static ENV_LOCK: Mutex<()> = Mutex::new(());
        let _guard = ENV_LOCK.lock().unwrap();

        // Point LIFEOS_API_SOCKET at a path that cannot exist
        let dir = TempDir::new().unwrap();
        let nonexistent = dir.path().join("no-such.sock");
        unsafe { std::env::set_var("LIFEOS_API_SOCKET", nonexistent.to_str().unwrap()) };
        let result = get_json::<serde_json::Value>("/api/v1/health").await;
        unsafe { std::env::remove_var("LIFEOS_API_SOCKET") };

        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("is lifeosd running"),
            "expected actionable hint, got: {msg}"
        );
    }

    // 4.2 RED→GREEN: life CLI connects via UDS and returns health
    // Spins a minimal HTTP/1.1 server over a UnixListener and verifies
    // that a hyper client built with UnixConnector can send a request
    // and receive a 200 response over a Unix-domain socket.
    // Does NOT mutate env vars (avoids parallel test interference).
    #[tokio::test]
    async fn life_cli_connects_via_uds_and_returns_health() {
        use hyper::Request;

        let dir = TempDir::new().unwrap();
        let sock_path = dir.path().join("test-api.sock");

        // Spin up a minimal Unix-socket HTTP/1.1 server
        let listener = UnixListener::bind(&sock_path).unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            // Drain the request bytes
            let mut buf = [0u8; 4096];
            let _ =
                tokio::time::timeout(std::time::Duration::from_millis(200), stream.read(&mut buf))
                    .await;
            let response = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nOK";
            stream.write_all(response).await.unwrap();
        });

        // Build client directly from the socket path (no env var needed)
        let connector = UnixConnector::new(sock_path.clone());
        let client = Client::builder(TokioExecutor::new()).build::<_, Full<Bytes>>(connector);

        let req = Request::builder()
            .uri("http://localhost/api/v1/health")
            .body(Full::new(Bytes::new()))
            .unwrap();

        let resp = client.request(req).await.unwrap();
        assert_eq!(resp.status(), 200);

        let _ = server.await;
    }
}
