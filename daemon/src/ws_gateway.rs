//! WebSocket Gateway — real-time bidirectional control plane.
//!
//! Provides event streaming to dashboard/CLI/mobile clients, replacing
//! HTTP polling with push notifications. Coexists with REST API on the
//! same Axum server at `/ws`.
//!
//! ## Protocol
//!
//! 1. Client opens WebSocket to `ws://127.0.0.1:8081/ws`
//! 2. First message MUST be `{"type":"connect","token":"<bootstrap_token>"}` within 5s
//! 3. Server replies `{"type":"connected","seq":0}` on success
//! 4. Client may send `{"type":"subscribe","events":["task.*","health.*"]}` to filter
//! 5. Server pushes events as `{"seq":N,"type":"event","event":"VariantName","data":{...}}`
//! 6. Client may send `{"type":"resync","lastSeq":N}` to request missed events
//! 7. Ping/pong: client sends `{"type":"ping"}`, server replies `{"type":"pong"}`

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::response::IntoResponse;
use log::{debug, info, warn};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::RwLock;
use tokio::time::{timeout, Duration};

use crate::api::ApiState;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Global state shared across all WebSocket connections.
pub struct WsState {
    /// Monotonic sequence counter for outbound events.
    seq: AtomicU64,
    /// Ring buffer of recent events for resync support.
    recent_events: RwLock<VecDeque<SeqEvent>>,
}

/// An event paired with its sequence number, kept for resync.
#[derive(Clone)]
struct SeqEvent {
    seq: u64,
    json: String,
}

/// Maximum number of recent events kept for resync.
const RESYNC_BUFFER_SIZE: usize = 1024;

/// Messages FROM the client.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum WsClientMessage {
    Connect { token: String },
    Subscribe { events: Vec<String> },
    Resync { last_seq: u64 },
    Ping,
}

/// Messages TO the client.
#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum WsServerMessage {
    Connected { seq: u64 },
    Event { seq: u64, event: serde_json::Value },
    Error { message: String },
    Pong,
    Resync { events: Vec<serde_json::Value> },
}

impl WsState {
    pub fn new() -> Self {
        Self {
            seq: AtomicU64::new(0),
            recent_events: RwLock::new(VecDeque::with_capacity(RESYNC_BUFFER_SIZE)),
        }
    }

    fn next_seq(&self) -> u64 {
        self.seq.fetch_add(1, Ordering::Relaxed) + 1
    }

    async fn store_event(&self, seq: u64, json: String) {
        let mut buf = self.recent_events.write().await;
        if buf.len() >= RESYNC_BUFFER_SIZE {
            buf.pop_front();
        }
        buf.push_back(SeqEvent { seq, json });
    }

    async fn events_since(&self, last_seq: u64) -> Vec<serde_json::Value> {
        let buf = self.recent_events.read().await;
        buf.iter()
            .filter(|e| e.seq > last_seq)
            .filter_map(|e| serde_json::from_str(&e.json).ok())
            .collect()
    }
}

// Lazy global WsState shared by all connections.
static WS_STATE: std::sync::OnceLock<Arc<WsState>> = std::sync::OnceLock::new();

fn ws_state() -> &'static Arc<WsState> {
    WS_STATE.get_or_init(|| Arc::new(WsState::new()))
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

/// Axum handler — upgrades the HTTP connection to a WebSocket.
pub async fn ws_handler(ws: WebSocketUpgrade, State(state): State<ApiState>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_ws_client(socket, state))
}

/// Per-client WebSocket loop.
async fn handle_ws_client(mut socket: WebSocket, state: ApiState) {
    // --- Step 1: Authenticate (first message within 5 seconds) ---
    let authenticated = match timeout(Duration::from_secs(5), socket.recv()).await {
        Ok(Some(Ok(Message::Text(text)))) => match serde_json::from_str::<WsClientMessage>(&text) {
            Ok(WsClientMessage::Connect { token }) => validate_token(&state, &token),
            _ => {
                let _ = send_msg(
                    &mut socket,
                    &WsServerMessage::Error {
                        message: "First message must be {\"type\":\"connect\",\"token\":\"...\"}"
                            .into(),
                    },
                )
                .await;
                false
            }
        },
        _ => {
            let _ = send_msg(
                &mut socket,
                &WsServerMessage::Error {
                    message: "Auth timeout — send connect message within 5 seconds".into(),
                },
            )
            .await;
            false
        }
    };

    if !authenticated {
        let _ = socket.close().await;
        return;
    }

    let ws_st = ws_state().clone();
    let current_seq = ws_st.seq.load(Ordering::Relaxed);
    if send_msg(
        &mut socket,
        &WsServerMessage::Connected { seq: current_seq },
    )
    .await
    .is_err()
    {
        return;
    }
    info!("WebSocket client connected (seq={})", current_seq);

    // --- Step 2: Event loop ---
    let mut event_rx = state.event_bus.subscribe();
    let mut filter: Option<Vec<String>> = None;

    loop {
        tokio::select! {
            // Incoming event from the daemon event bus
            event_result = event_rx.recv() => {
                match event_result {
                    Ok(event) => {
                        let json_value = match serde_json::to_value(&event) {
                            Ok(v) => v,
                            Err(_) => continue,
                        };

                        // Apply subscription filter if set
                        if let Some(ref patterns) = filter {
                            let event_type = event_type_name(&json_value);
                            if !matches_any_pattern(&event_type, patterns) {
                                continue;
                            }
                        }

                        let seq = ws_st.next_seq();
                        let msg = WsServerMessage::Event { seq, event: json_value };
                        let json_str = serde_json::to_string(&msg).unwrap_or_default();

                        // Store for resync
                        ws_st.store_event(seq, json_str.clone()).await;

                        if socket.send(Message::Text(json_str)).await.is_err() {
                            debug!("WebSocket client disconnected (send failed)");
                            break;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        warn!("WebSocket client lagged by {} events", n);
                        let _ = send_msg(&mut socket, &WsServerMessage::Error {
                            message: format!("Lagged by {n} events — consider resync"),
                        }).await;
                    }
                    Err(_) => {
                        // Channel closed
                        break;
                    }
                }
            }
            // Incoming message from the client
            client_msg = socket.recv() => {
                match client_msg {
                    Some(Ok(Message::Text(text))) => {
                        match serde_json::from_str::<WsClientMessage>(&text) {
                            Ok(WsClientMessage::Ping) => {
                                if send_msg(&mut socket, &WsServerMessage::Pong).await.is_err() {
                                    break;
                                }
                            }
                            Ok(WsClientMessage::Subscribe { events }) => {
                                debug!("WebSocket client subscribed to: {:?}", events);
                                filter = if events.is_empty() { None } else { Some(events) };
                            }
                            Ok(WsClientMessage::Resync { last_seq }) => {
                                let missed = ws_st.events_since(last_seq).await;
                                debug!("WebSocket resync from seq {}: {} events", last_seq, missed.len());
                                if send_msg(&mut socket, &WsServerMessage::Resync { events: missed }).await.is_err() {
                                    break;
                                }
                            }
                            Ok(WsClientMessage::Connect { .. }) => {
                                // Already authenticated, ignore duplicate connect
                            }
                            Err(e) => {
                                debug!("Invalid WS message from client: {}", e);
                                let _ = send_msg(&mut socket, &WsServerMessage::Error {
                                    message: format!("Invalid message: {e}"),
                                }).await;
                            }
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => {
                        debug!("WebSocket client disconnected");
                        break;
                    }
                    Some(Ok(Message::Ping(data))) => {
                        let _ = socket.send(Message::Pong(data)).await;
                    }
                    Some(Ok(_)) => {
                        // Binary or other message types — ignore
                    }
                    Some(Err(e)) => {
                        debug!("WebSocket error: {}", e);
                        break;
                    }
                }
            }
        }
    }

    info!("WebSocket client disconnected");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn validate_token(state: &ApiState, token: &str) -> bool {
    match state.config.api_key.as_deref() {
        // No token configured — allow all connections on localhost
        None => true,
        Some(expected) => expected == token,
    }
}

async fn send_msg(socket: &mut WebSocket, msg: &WsServerMessage) -> Result<(), ()> {
    let json = serde_json::to_string(msg).map_err(|_| ())?;
    socket.send(Message::Text(json)).await.map_err(|_| ())
}

/// Extract the event type name from the serialized DaemonEvent JSON value.
/// DaemonEvent is tagged with `#[serde(tag = "type")]`, so the "type" field holds the variant name.
fn event_type_name(value: &serde_json::Value) -> String {
    value
        .get("type")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown")
        .to_string()
}

/// Check if an event type matches any of the subscription patterns.
/// Supports glob-style patterns: `*` matches everything, `task.*` matches `task.completed`, etc.
fn matches_any_pattern(event_type: &str, patterns: &[String]) -> bool {
    for pattern in patterns {
        if pattern == "*" {
            return true;
        }
        if pattern.ends_with(".*") {
            let prefix = &pattern[..pattern.len() - 2];
            if event_type.starts_with(prefix) {
                return true;
            }
        }
        // Also support exact match and underscore-delimited prefix match
        // e.g., "axi_state" matches "axi_state_changed"
        if event_type == pattern || event_type.starts_with(&format!("{}_", pattern)) {
            return true;
        }
    }
    false
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_matches_any_pattern_wildcard() {
        assert!(matches_any_pattern("anything", &["*".to_string()]));
    }

    #[test]
    fn test_matches_any_pattern_glob() {
        let patterns = vec!["task.*".to_string()];
        assert!(matches_any_pattern("task.completed", &patterns));
        assert!(matches_any_pattern("task.started", &patterns));
        assert!(!matches_any_pattern("health.check", &patterns));
    }

    #[test]
    fn test_matches_any_pattern_exact() {
        let patterns = vec!["axi_state_changed".to_string()];
        assert!(matches_any_pattern("axi_state_changed", &patterns));
        assert!(!matches_any_pattern("sensor_changed", &patterns));
    }

    #[test]
    fn test_matches_any_pattern_prefix() {
        let patterns = vec!["axi_state".to_string()];
        assert!(matches_any_pattern("axi_state_changed", &patterns));
    }

    #[test]
    fn test_matches_any_pattern_empty() {
        let patterns: Vec<String> = vec![];
        assert!(!matches_any_pattern("anything", &patterns));
    }

    #[test]
    fn test_event_type_name() {
        let val = serde_json::json!({"type": "axi_state_changed", "data": {}});
        assert_eq!(event_type_name(&val), "axi_state_changed");
    }

    #[test]
    fn test_event_type_name_missing() {
        let val = serde_json::json!({"foo": "bar"});
        assert_eq!(event_type_name(&val), "unknown");
    }

    #[tokio::test]
    async fn test_ws_state_seq_and_resync() {
        let state = WsState::new();

        let s1 = state.next_seq();
        let s2 = state.next_seq();
        assert_eq!(s1, 1);
        assert_eq!(s2, 2);

        state
            .store_event(
                1,
                r#"{"seq":1,"type":"event","event":{"type":"test1"}}"#.to_string(),
            )
            .await;
        state
            .store_event(
                2,
                r#"{"seq":2,"type":"event","event":{"type":"test2"}}"#.to_string(),
            )
            .await;

        let missed = state.events_since(0).await;
        assert_eq!(missed.len(), 2);

        let missed = state.events_since(1).await;
        assert_eq!(missed.len(), 1);

        let missed = state.events_since(2).await;
        assert_eq!(missed.len(), 0);
    }

    #[tokio::test]
    async fn test_ws_state_buffer_overflow() {
        let state = WsState::new();
        for i in 1..=(RESYNC_BUFFER_SIZE + 10) {
            let seq = i as u64;
            state.store_event(seq, format!(r#"{{"seq":{seq}}}"#)).await;
        }
        let buf = state.recent_events.read().await;
        assert_eq!(buf.len(), RESYNC_BUFFER_SIZE);
        // Oldest should be 11 (first 10 evicted)
        assert_eq!(buf.front().unwrap().seq, 11);
    }
}
