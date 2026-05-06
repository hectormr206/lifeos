//! Shared daemon HTTP client with bootstrap token authentication
//!
//! All CLI commands that talk to the lifeosd API should use this module
//! to get an authenticated reqwest client.

use reqwest::Client;
use std::io::{IsTerminal, Read};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

const DEFAULT_DAEMON_URL: &str = "http://127.0.0.1:8081";
const TOKEN_FILENAME: &str = "bootstrap.token";
const DEFAULT_HANDOUT_SOCKET: &str = "/run/lifeos/lifeos-bootstrap.sock";

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
    // attempted was a no-op. Just read.
    let mut buf = String::new();
    let mut reader = stream;
    reader.read_to_string(&mut buf).ok()?;
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

/// Get the daemon API base URL
pub fn daemon_url() -> String {
    std::env::var("LIFEOS_API_URL").unwrap_or_else(|_| DEFAULT_DAEMON_URL.to_string())
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
        // 2) Direct read (works when running as root or token is world/group readable)
        if let Some(token) = std::fs::read_to_string(&token_path)
            .ok()
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
        {
            return Some(token);
        }

        // 3) Best-effort privileged read without prompting (fails fast if sudo is unavailable)
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

        // 4) Interactive sudo fallback for terminal users.
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

/// Build a reqwest client that includes the bootstrap token header.
/// If the token file is not readable (e.g. dev machine), requests
/// proceed without auth — the daemon will reject them with 401.
pub fn authenticated_client() -> Client {
    let mut headers = reqwest::header::HeaderMap::new();
    if let Some(token) = read_bootstrap_token() {
        if let Ok(value) = reqwest::header::HeaderValue::from_str(&token) {
            headers.insert("x-bootstrap-token", value);
        }
    }
    Client::builder()
        .default_headers(headers)
        .build()
        .unwrap_or_else(|_| Client::new())
}
