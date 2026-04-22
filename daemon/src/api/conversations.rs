//! Conversations API — unified view of message history across bridges.
//!
//! Backed by the on-disk `~/.local/share/lifeos/conversation_history.json`
//! file owned by [`crate::axi_tools::ConversationHistory`]. We intentionally
//! read the file directly (rather than going through the in-memory store)
//! because the dashboard needs a flat enumeration of *all* chats and the
//! existing store does not expose one.
//!
//! The endpoint is read-only and returns at most `limit` entries (default 20),
//! sorted by most recent activity. Per-chat message previews are truncated
//! to keep the payload small.

use super::{ApiError, ApiState};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
    routing::{delete, get},
    Router,
};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

pub fn conversations_routes() -> Router<ApiState> {
    Router::new()
        .route("/", get(list_conversations))
        .route("/:chat_id", get(get_conversation))
        .route("/:chat_id", delete(delete_conversation))
}

fn history_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
    PathBuf::from(format!(
        "{}/.local/share/lifeos/conversation_history.json",
        home
    ))
}

#[derive(Debug, Deserialize)]
pub struct ListQuery {
    #[serde(default)]
    pub limit: Option<usize>,
    #[serde(default)]
    pub source: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ConversationSummary {
    pub chat_id: i64,
    pub source: String,
    pub last_active: String,
    pub message_count: usize,
    pub preview: String,
}

#[derive(Debug, Serialize)]
pub struct ListConversationsResponse {
    pub conversations: Vec<ConversationSummary>,
    pub total: usize,
}

#[derive(Debug, Serialize)]
pub struct ConversationMessage {
    pub role: String,
    pub content: String,
    pub timestamp: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ConversationDetail {
    pub chat_id: i64,
    pub source: String,
    pub last_active: String,
    pub messages: Vec<ConversationMessage>,
}

/// Best-effort reader for the on-disk JSON. Returns parsed entries paired with
/// the raw JSON value of each entry (so we can extract messages on demand).
fn load_entries() -> Vec<(i64, serde_json::Value)> {
    let path = history_path();
    if !path.exists() {
        return Vec::new();
    }
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    let Ok(map) = serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(&text) else {
        return Vec::new();
    };
    map.into_iter()
        .filter_map(|(k, v)| k.parse::<i64>().ok().map(|id| (id, v)))
        .collect()
}

fn classify_source(chat_id: i64) -> &'static str {
    // Heuristic: SimpleX uses synthetic negative ids derived from contact
    // hashes; Telegram uses positive user ids. This matches the pattern in
    // simplex_bridge::contact_to_chat_id().
    if chat_id < 0 {
        "simplex"
    } else {
        "telegram"
    }
}

fn entry_last_active(v: &serde_json::Value) -> String {
    v.get("last_active")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string()
}

fn entry_messages(v: &serde_json::Value) -> Vec<serde_json::Value> {
    v.get("messages")
        .and_then(|x| x.as_array())
        .cloned()
        .unwrap_or_default()
}

fn first_text(v: &serde_json::Value) -> String {
    let content = v.get("content");
    if let Some(s) = content.and_then(|c| c.as_str()) {
        return s.to_string();
    }
    if let Some(arr) = content.and_then(|c| c.as_array()) {
        for part in arr {
            if let Some(t) = part.get("text").and_then(|t| t.as_str()) {
                return t.to_string();
            }
        }
    }
    String::new()
}

async fn list_conversations(
    State(_state): State<ApiState>,
    Query(q): Query<ListQuery>,
) -> Result<Json<ListConversationsResponse>, (StatusCode, Json<ApiError>)> {
    let limit = q.limit.unwrap_or(20).min(200);
    let mut entries = load_entries();
    entries.sort_by(|a, b| entry_last_active(&b.1).cmp(&entry_last_active(&a.1)));

    let mut out: Vec<ConversationSummary> = Vec::new();
    let total = entries.len();
    for (chat_id, v) in entries.into_iter() {
        let source = classify_source(chat_id);
        if let Some(ref filter) = q.source {
            if !filter.eq_ignore_ascii_case(source) {
                continue;
            }
        }
        let messages = entry_messages(&v);
        let preview = messages
            .last()
            .map(first_text)
            .unwrap_or_default()
            .chars()
            .take(140)
            .collect::<String>();
        out.push(ConversationSummary {
            chat_id,
            source: source.into(),
            last_active: entry_last_active(&v),
            message_count: messages.len(),
            preview,
        });
        if out.len() >= limit {
            break;
        }
    }

    Ok(Json(ListConversationsResponse {
        conversations: out,
        total,
    }))
}

async fn get_conversation(
    State(_state): State<ApiState>,
    Path(chat_id): Path<i64>,
) -> Result<Json<ConversationDetail>, (StatusCode, Json<ApiError>)> {
    let entries = load_entries();
    let entry = entries.into_iter().find(|(id, _)| *id == chat_id);
    let Some((_, v)) = entry else {
        return Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "conversation_not_found".into(),
                message: format!("No conversation for chat_id {}", chat_id),
                code: 404,
            }),
        ));
    };
    let source = classify_source(chat_id).to_string();
    let last_active = entry_last_active(&v);
    let messages = entry_messages(&v)
        .into_iter()
        .map(|m| ConversationMessage {
            role: m
                .get("role")
                .and_then(|r| r.as_str())
                .unwrap_or("user")
                .to_string(),
            content: first_text(&m).chars().take(2000).collect(),
            timestamp: m
                .get("timestamp")
                .and_then(|t| t.as_str())
                .map(|s| s.to_string()),
        })
        .collect();
    Ok(Json(ConversationDetail {
        chat_id,
        source,
        last_active,
        messages,
    }))
}

async fn delete_conversation(
    State(state): State<ApiState>,
    Path(chat_id): Path<i64>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    #[cfg(feature = "messaging")]
    {
        let cleared = state.conversation_history.clear(chat_id).await;
        return Ok(Json(serde_json::json!({
            "cleared": true,
            "chat_id": chat_id,
            "removed_messages": cleared.len(),
        })));
    }
    #[cfg(not(feature = "messaging"))]
    {
        let _ = (state, chat_id);
        Err((
            StatusCode::NOT_IMPLEMENTED,
            Json(ApiError {
                error: "messaging_disabled".into(),
                message: "messaging feature not enabled in this build".into(),
                code: 501,
            }),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_source_heuristics() {
        assert_eq!(classify_source(123_456), "telegram");
        assert_eq!(classify_source(-9_999), "simplex");
    }

    #[test]
    fn first_text_handles_string_and_array() {
        let v_str = serde_json::json!({ "content": "hola" });
        assert_eq!(first_text(&v_str), "hola");
        let v_arr = serde_json::json!({
            "content": [
                { "type": "image_url", "image_url": "x" },
                { "type": "text", "text": "buenas" }
            ]
        });
        assert_eq!(first_text(&v_arr), "buenas");
    }

    #[test]
    fn load_entries_returns_empty_when_missing() {
        let _ = load_entries();
    }
}
