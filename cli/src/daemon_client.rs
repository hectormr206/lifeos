//! Shared daemon HTTP client with bootstrap token authentication
//!
//! All CLI commands that talk to the lifeosd API should use this module
//! to get an authenticated reqwest client.

use reqwest::Client;
use std::io::IsTerminal;
use std::path::PathBuf;
use std::process::Command;

const DEFAULT_DAEMON_URL: &str = "http://127.0.0.1:8081";
const TOKEN_FILENAME: &str = "bootstrap.token";

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
