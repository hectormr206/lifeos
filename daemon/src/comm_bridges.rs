//! Communication bridges — Multi-channel messaging (WhatsApp, Matrix, Signal).
//!
//! Provides a unified interface for sending/receiving messages across platforms.
//! Each bridge is feature-gated and requires external setup.

use serde::{Deserialize, Serialize};

/// Unified message from any channel.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IncomingMessage {
    pub channel: Channel,
    pub sender: String,
    pub text: String,
    pub has_media: bool,
    pub timestamp: String,
}

/// Unified outgoing message.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OutgoingMessage {
    pub channel: Channel,
    pub recipient: String,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Channel {
    Telegram,
    WhatsApp,
    Matrix,
    Signal,
    Email,
}

/// Check which bridges are configured.
pub fn available_bridges() -> Vec<Channel> {
    let mut bridges = Vec::new();

    // Telegram: always check
    if !std::env::var("LIFEOS_TELEGRAM_BOT_TOKEN")
        .unwrap_or_default()
        .is_empty()
    {
        bridges.push(Channel::Telegram);
    }

    // WhatsApp: requires Business API token
    if !std::env::var("LIFEOS_WHATSAPP_TOKEN")
        .unwrap_or_default()
        .is_empty()
    {
        bridges.push(Channel::WhatsApp);
    }

    // Matrix: requires homeserver + token
    if !std::env::var("LIFEOS_MATRIX_HOMESERVER")
        .unwrap_or_default()
        .is_empty()
    {
        bridges.push(Channel::Matrix);
    }

    // Signal: requires signal-cli
    if std::path::Path::new("/usr/bin/signal-cli").exists()
        || std::path::Path::new("/usr/local/bin/signal-cli").exists()
    {
        bridges.push(Channel::Signal);
    }

    // Email: requires IMAP config
    if !std::env::var("LIFEOS_EMAIL_IMAP_HOST")
        .unwrap_or_default()
        .is_empty()
    {
        bridges.push(Channel::Email);
    }

    bridges
}

/// WhatsApp bridge stub — sends via WhatsApp Business API.
#[allow(dead_code)]
pub async fn send_whatsapp(phone: &str, message: &str) -> anyhow::Result<()> {
    let token = std::env::var("LIFEOS_WHATSAPP_TOKEN")
        .map_err(|_| anyhow::anyhow!("LIFEOS_WHATSAPP_TOKEN not configured"))?;
    let phone_id = std::env::var("LIFEOS_WHATSAPP_PHONE_ID")
        .map_err(|_| anyhow::anyhow!("LIFEOS_WHATSAPP_PHONE_ID not configured"))?;

    let client = reqwest::Client::new();
    let _res = client
        .post(format!(
            "https://graph.facebook.com/v18.0/{}/messages",
            phone_id
        ))
        .bearer_auth(&token)
        .json(&serde_json::json!({
            "messaging_product": "whatsapp",
            "to": phone,
            "type": "text",
            "text": {"body": message}
        }))
        .send()
        .await?;

    Ok(())
}

/// Matrix bridge stub — sends via Matrix client-server API.
#[allow(dead_code)]
pub async fn send_matrix(room_id: &str, message: &str) -> anyhow::Result<()> {
    let homeserver = std::env::var("LIFEOS_MATRIX_HOMESERVER")
        .map_err(|_| anyhow::anyhow!("LIFEOS_MATRIX_HOMESERVER not configured"))?;
    let token = std::env::var("LIFEOS_MATRIX_TOKEN")
        .map_err(|_| anyhow::anyhow!("LIFEOS_MATRIX_TOKEN not configured"))?;

    let txn_id = uuid::Uuid::new_v4().to_string();
    let client = reqwest::Client::new();
    let _res = client
        .put(format!(
            "{}/_matrix/client/v3/rooms/{}/send/m.room.message/{}",
            homeserver, room_id, txn_id
        ))
        .bearer_auth(&token)
        .json(&serde_json::json!({
            "msgtype": "m.text",
            "body": message
        }))
        .send()
        .await?;

    Ok(())
}

/// Signal bridge stub — sends via signal-cli.
#[allow(dead_code)]
pub async fn send_signal(phone: &str, message: &str) -> anyhow::Result<()> {
    let output = tokio::process::Command::new("signal-cli")
        .args(["send", "-m", message, phone])
        .output()
        .await?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("signal-cli failed: {}", stderr);
    }
    Ok(())
}

/// Home Assistant bridge — control smart devices.
#[allow(dead_code)]
pub async fn homeassistant_call_service(
    domain: &str,
    service: &str,
    entity_id: &str,
) -> anyhow::Result<String> {
    let ha_url = std::env::var("LIFEOS_HA_URL")
        .map_err(|_| anyhow::anyhow!("LIFEOS_HA_URL not configured"))?;
    let ha_token = std::env::var("LIFEOS_HA_TOKEN")
        .map_err(|_| anyhow::anyhow!("LIFEOS_HA_TOKEN not configured"))?;

    let client = reqwest::Client::new();
    let res = client
        .post(format!("{}/api/services/{}/{}", ha_url, domain, service))
        .bearer_auth(&ha_token)
        .json(&serde_json::json!({"entity_id": entity_id}))
        .send()
        .await?;

    let status = res.status();
    let body = res.text().await?;

    if status.is_success() {
        Ok(format!("OK: {}.{} -> {}", domain, service, entity_id))
    } else {
        anyhow::bail!("HA error {}: {}", status, body)
    }
}
