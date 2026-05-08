//! Daemon HTTP client — thin async reqwest wrapper over the lifeosd API.
//!
//! All schemas use `#[serde(deny_unknown_fields)]` so daemon schema drift
//! surfaces immediately as a deserialization error rather than silent data loss.
//!
//! On 401 responses, methods return `DaemonClientError::Unauthorized` so the
//! caller can trigger token re-acquisition.

use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use reqwest::{header, Client, StatusCode};
use serde::{Deserialize, Serialize};

/// Errors specific to the daemon client (subset of anyhow::Error).
#[derive(Debug)]
pub enum DaemonClientError {
    /// The daemon rejected our token (HTTP 401). Caller should re-acquire.
    Unauthorized,
    /// Other HTTP or network error.
    Other(anyhow::Error),
}

impl std::fmt::Display for DaemonClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DaemonClientError::Unauthorized => write!(f, "daemon returned 401 Unauthorized"),
            DaemonClientError::Other(e) => write!(f, "{}", e),
        }
    }
}

impl std::error::Error for DaemonClientError {}

// ── Response schemas ──────────────────────────────────────────────────────────
// These mirror `daemon/src/api/mod.rs` structs exactly.
// `deny_unknown_fields` catches daemon schema drift at deserialization time.

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SystemStatus {
    pub online: bool,
    pub uptime_seconds: u64,
    pub version: String,
    pub hostname: String,
    pub boot_time: String,
    pub server_time: String,
    pub timezone: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HealthCheck {
    pub name: String,
    pub status: String,
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HealthReport {
    pub healthy: bool,
    pub score: u8,
    pub checks: Vec<HealthCheck>,
    pub timestamp: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiGameGuardStatus {
    pub supported: bool,
    pub guard_enabled: bool,
    pub assistant_enabled: bool,
    pub game_detected: bool,
    pub game_name: Option<String>,
    pub game_pid: Option<u32>,
    pub llm_mode: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiRuntimeStatus {
    pub service_state: String,
    pub service_scope: Option<String>,
    pub service_pid: Option<u32>,
    pub active_profile: Option<String>,
    pub profile_source: Option<String>,
    pub benchmark_completed: Option<bool>,
    pub benchmark_pending_reason: Option<String>,
    pub effective_gpu_layers: Option<i32>,
    pub gpu_layers_source: Option<String>,
    pub backend: Option<String>,
    pub backend_name: Option<String>,
    pub mode: String,
    pub mode_confidence: String,
    pub mode_reason: String,
    pub gpu_memory_mb: Option<u64>,
    pub rss_memory_mb: Option<u64>,
    pub preflight_reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub game_guard: Option<AiGameGuardStatus>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiStatus {
    pub running: bool,
    pub version: String,
    pub active_model: Option<String>,
    pub models_loaded: Vec<String>,
    pub gpu_available: bool,
    pub gpu_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub runtime: Option<AiRuntimeStatus>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WakeWordTriggerResponse {
    pub accepted: bool,
    pub session_id: Option<String>,
}

// ── DaemonClient ──────────────────────────────────────────────────────────────

/// Async HTTP client for the lifeosd API.
///
/// Clone is cheap — reqwest::Client uses an Arc internally.
#[derive(Clone)]
pub struct DaemonClient {
    base: String,
    token: String,
    http: Client,
}

impl DaemonClient {
    /// Construct a new client. Builds a reqwest::Client with the bootstrap
    /// token set as a default header on every request.
    pub fn new(base: String, token: String) -> Result<Self> {
        let mut headers = header::HeaderMap::new();
        let mut header_value = header::HeaderValue::from_str(&token)
            .context("bootstrap token contains invalid header characters")?;
        header_value.set_sensitive(true);
        headers.insert("x-bootstrap-token", header_value);

        let http = Client::builder()
            .default_headers(headers)
            .build()
            .context("failed to build reqwest client")?;

        Ok(Self { base, token, http })
    }

    /// Update the token (used after re-acquisition on 401).
    pub fn with_token(mut self, token: String) -> Result<Self> {
        let mut headers = header::HeaderMap::new();
        let mut header_value = header::HeaderValue::from_str(&token)
            .context("new token contains invalid header characters")?;
        header_value.set_sensitive(true);
        headers.insert("x-bootstrap-token", header_value);

        self.http = Client::builder()
            .default_headers(headers)
            .build()
            .context("failed to rebuild reqwest client")?;
        self.token = token;
        Ok(self)
    }

    pub fn base_url(&self) -> &str {
        &self.base
    }

    pub fn token(&self) -> &str {
        &self.token
    }

    // ── API methods ───────────────────────────────────────────────────────────

    pub async fn system_status(&self) -> Result<SystemStatus> {
        self.get_json("/api/v1/system/status").await
    }

    pub async fn ai_status(&self) -> Result<AiStatus> {
        self.get_json("/api/v1/ai/status").await
    }

    pub async fn health(&self) -> Result<HealthReport> {
        self.get_json("/api/v1/health").await
    }

    pub async fn post_wake_word_trigger(
        &self,
        word: &str,
        score: f32,
        ts: DateTime<Utc>,
    ) -> Result<WakeWordTriggerResponse> {
        let body = serde_json::json!({
            "word": word,
            "score": score,
            "detected_at": ts.to_rfc3339(),
        });
        self.post_json("/api/v1/sensory/wake-word/trigger", &body)
            .await
    }

    // ── private helpers ───────────────────────────────────────────────────────

    async fn get_json<T: serde::de::DeserializeOwned>(&self, path: &str) -> Result<T> {
        let url = format!("{}{}", self.base, path);
        let resp = self
            .http
            .get(&url)
            .send()
            .await
            .with_context(|| format!("GET {} failed", url))?;

        if resp.status() == StatusCode::UNAUTHORIZED {
            bail!(DaemonClientError::Unauthorized);
        }

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            bail!("GET {} returned {}: {}", url, status, body);
        }

        resp.json::<T>()
            .await
            .with_context(|| format!("failed to parse JSON from GET {}", url))
    }

    async fn post_json<B, T>(&self, path: &str, body: &B) -> Result<T>
    where
        B: Serialize,
        T: serde::de::DeserializeOwned,
    {
        let url = format!("{}{}", self.base, path);
        let resp = self
            .http
            .post(&url)
            .json(body)
            .send()
            .await
            .with_context(|| format!("POST {} failed", url))?;

        if resp.status() == StatusCode::UNAUTHORIZED {
            bail!(DaemonClientError::Unauthorized);
        }

        let status = resp.status();
        if !status.is_success() {
            let body_text = resp.text().await.unwrap_or_default();
            bail!("POST {} returned {}: {}", url, status, body_text);
        }

        resp.json::<T>()
            .await
            .with_context(|| format!("failed to parse JSON from POST {}", url))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    /// Hand-rolled mock HTTP/1.1 server (single-request, pre-canned response).
    ///
    /// Binds a random port, spawns a task that accepts one connection,
    /// reads the request (discards it), writes the provided HTTP/1.1 response,
    /// and closes. Returns the bound port.
    async fn mock_server_once(response: &'static str) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind mock server");
        let port = listener.local_addr().expect("local_addr").port();
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 4096];
                // Read the request (we don't care about it)
                let _ =
                    tokio::time::timeout(Duration::from_millis(200), stream.read(&mut buf)).await;
                let _ = stream.write_all(response.as_bytes()).await;
            }
        });
        port
    }

    #[tokio::test]
    async fn health_round_trip_happy() {
        let body = r#"{"healthy":true,"score":95,"checks":[{"name":"llm","status":"ok","message":null}],"timestamp":"2026-01-01T00:00:00Z"}"#;
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );
        let port = mock_server_once(Box::leak(response.into_boxed_str())).await;
        tokio::time::sleep(Duration::from_millis(10)).await;

        let client = DaemonClient::new(
            format!("http://127.0.0.1:{}", port),
            "test-token".to_string(),
        )
        .expect("client build");

        let report = client.health().await.expect("health should succeed");
        assert!(report.healthy);
        assert_eq!(report.score, 95);
    }

    #[tokio::test]
    async fn wake_word_trigger_round_trip() {
        let body = r#"{"accepted":true,"session_id":"sess-abc"}"#;
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );
        let port = mock_server_once(Box::leak(response.into_boxed_str())).await;
        tokio::time::sleep(Duration::from_millis(10)).await;

        let client = DaemonClient::new(
            format!("http://127.0.0.1:{}", port),
            "test-token".to_string(),
        )
        .expect("client build");

        let resp = client
            .post_wake_word_trigger("axi", 0.95, Utc::now())
            .await
            .expect("trigger should succeed");
        assert!(resp.accepted);
        assert_eq!(resp.session_id.as_deref(), Some("sess-abc"));
    }

    #[tokio::test]
    async fn unauthorized_returns_error() {
        let response = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n";
        let port = mock_server_once(response).await;
        tokio::time::sleep(Duration::from_millis(10)).await;

        let client = DaemonClient::new(
            format!("http://127.0.0.1:{}", port),
            "bad-token".to_string(),
        )
        .expect("client build");

        let result = client.health().await;
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("Unauthorized") || msg.contains("401"),
            "expected 401 error, got: {}",
            msg
        );
    }

    #[tokio::test]
    async fn system_status_deny_unknown_fields() {
        // The SystemStatus struct uses deny_unknown_fields.
        // Adding an unknown field should fail deserialization.
        let json = r#"{"online":true,"uptime_seconds":100,"version":"1.0","hostname":"host",
            "boot_time":"2026-01-01T00:00:00Z","server_time":"2026-01-01T01:00:00Z",
            "timezone":"UTC","UNKNOWN_FIELD":"should_fail"}"#;
        let result: std::result::Result<SystemStatus, _> = serde_json::from_str(json);
        assert!(
            result.is_err(),
            "deny_unknown_fields should reject unknown fields"
        );
    }

    // Re-export Utc for test use
    use chrono::Utc;
    // Re-export Arc for future tests
    #[allow(unused_imports)]
    use Arc as _Arc;
}
