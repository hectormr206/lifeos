//! Email bridge — Read and send emails via IMAP/SMTP.
//!
//! Provides email capabilities to the supervisor:
//! - List recent emails
//! - Read email content
//! - Send email replies
//! - **Conversational loop** (requires `telegram` feature): poll for new emails,
//!   process through the agentic loop, and auto-reply (like Telegram).
//!
//! Configuration via environment variables:
//! - LIFEOS_EMAIL_IMAP_HOST, LIFEOS_EMAIL_IMAP_USER, LIFEOS_EMAIL_IMAP_PASS
//! - LIFEOS_EMAIL_SMTP_HOST, LIFEOS_EMAIL_SMTP_USER, LIFEOS_EMAIL_SMTP_PASS
//! - LIFEOS_EMAIL_CONVERSATIONAL=true  — enable the auto-reply loop
//! - LIFEOS_EMAIL_ALLOWED_SENDERS=a@x.com,b@y.com — whitelist
//! - LIFEOS_EMAIL_POLL_SECS=300 — polling interval (default 5 min)

use log::info;
#[cfg(feature = "telegram")]
use log::warn;
use serde::{Deserialize, Serialize};
#[cfg(feature = "telegram")]
use std::collections::HashSet;
#[cfg(feature = "telegram")]
use std::time::Duration;

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmailConfig {
    pub imap_host: String,
    pub imap_port: u16,
    pub smtp_host: String,
    pub smtp_port: u16,
    pub username: String,
    pub password: String,
}

impl EmailConfig {
    pub fn from_env() -> Option<Self> {
        let imap_host = std::env::var("LIFEOS_EMAIL_IMAP_HOST").ok()?;
        if imap_host.is_empty() {
            return None;
        }
        Some(Self {
            imap_host,
            imap_port: std::env::var("LIFEOS_EMAIL_IMAP_PORT")
                .ok()
                .and_then(|p| p.parse().ok())
                .unwrap_or(993),
            smtp_host: std::env::var("LIFEOS_EMAIL_SMTP_HOST").unwrap_or_default(),
            smtp_port: std::env::var("LIFEOS_EMAIL_SMTP_PORT")
                .ok()
                .and_then(|p| p.parse().ok())
                .unwrap_or(587),
            username: std::env::var("LIFEOS_EMAIL_IMAP_USER").unwrap_or_default(),
            password: std::env::var("LIFEOS_EMAIL_IMAP_PASS").unwrap_or_default(),
        })
    }

    pub fn is_configured() -> bool {
        Self::from_env().is_some()
    }
}

/// Configuration for the conversational auto-reply loop.
#[cfg(feature = "telegram")]
#[derive(Debug, Clone)]
pub struct ConversationalEmailConfig {
    pub email: EmailConfig,
    pub allowed_senders: HashSet<String>,
    pub poll_interval: Duration,
    pub max_replies_per_hour: u32,
}

#[cfg(feature = "telegram")]
impl ConversationalEmailConfig {
    /// Build from env. Returns `None` when the feature is not enabled or email
    /// is not configured.
    pub fn from_env() -> Option<Self> {
        let enabled = std::env::var("LIFEOS_EMAIL_CONVERSATIONAL")
            .map(|v| v == "true" || v == "1")
            .unwrap_or(false);
        if !enabled {
            return None;
        }

        let email = EmailConfig::from_env()?;

        let allowed: HashSet<String> = std::env::var("LIFEOS_EMAIL_ALLOWED_SENDERS")
            .unwrap_or_default()
            .split(',')
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty())
            .collect();

        if allowed.is_empty() {
            warn!("LIFEOS_EMAIL_CONVERSATIONAL enabled but LIFEOS_EMAIL_ALLOWED_SENDERS is empty -- disabling");
            return None;
        }

        let poll_secs: u64 = std::env::var("LIFEOS_EMAIL_POLL_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(300);

        let max_replies: u32 = std::env::var("LIFEOS_EMAIL_MAX_REPLIES_PER_HOUR")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(10);

        Some(Self {
            email,
            allowed_senders: allowed,
            poll_interval: Duration::from_secs(poll_secs),
            max_replies_per_hour: max_replies,
        })
    }
}

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmailSummary {
    pub from: String,
    pub subject: String,
    pub date: String,
    pub preview: String,
}

/// Extended email data returned by the conversational fetch script.
#[cfg(feature = "telegram")]
#[derive(Debug, Clone, Serialize, Deserialize)]
struct IncomingEmail {
    message_id: String,
    from: String,
    subject: String,
    date: String,
    body: String,
    /// RFC-2822 Date parsed to epoch seconds (for age filtering).
    epoch: Option<i64>,
}

// ---------------------------------------------------------------------------
// IMAP helpers
// ---------------------------------------------------------------------------

/// List recent emails (stub -- uses python's imaplib).
pub async fn list_recent_emails(limit: usize) -> anyhow::Result<Vec<EmailSummary>> {
    let config = EmailConfig::from_env()
        .ok_or_else(|| anyhow::anyhow!("Email not configured (set LIFEOS_EMAIL_* env vars)"))?;

    info!(
        "Checking emails via IMAP: {}@{}",
        config.username, config.imap_host
    );

    let script = format!(
        r#"
import imaplib, email, json, sys
try:
    m = imaplib.IMAP4_SSL('{}', {})
    m.login('{}', '{}')
    m.select('INBOX')
    _, data = m.search(None, 'ALL')
    ids = data[0].split()[-{}:]
    results = []
    for eid in reversed(ids):
        _, msg_data = m.fetch(eid, '(RFC822)')
        msg = email.message_from_bytes(msg_data[0][1])
        body = ''
        if msg.is_multipart():
            for part in msg.walk():
                if part.get_content_type() == 'text/plain':
                    body = part.get_payload(decode=True).decode('utf-8','ignore')[:200]
                    break
        else:
            body = msg.get_payload(decode=True).decode('utf-8','ignore')[:200]
        results.append({{'from': str(msg['From']), 'subject': str(msg['Subject']), 'date': str(msg['Date']), 'preview': body.strip()[:150]}})
    m.close()
    m.logout()
    print(json.dumps(results))
except Exception as e:
    print(json.dumps({{'error': str(e)}}))
"#,
        config.imap_host, config.imap_port, config.username, config.password, limit
    );

    let output = tokio::process::Command::new("python3")
        .args(["-c", &script])
        .output()
        .await?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let parsed: serde_json::Value = serde_json::from_str(stdout.trim())?;

    if let Some(err) = parsed.get("error") {
        anyhow::bail!("IMAP error: {}", err);
    }

    let emails: Vec<EmailSummary> = serde_json::from_value(parsed)?;
    Ok(emails)
}

/// Fetch UNSEEN emails with full metadata (Message-ID, body, epoch).
/// Returns them oldest-first so we reply in order.
#[cfg(feature = "telegram")]
async fn fetch_unseen_emails(config: &EmailConfig) -> anyhow::Result<Vec<IncomingEmail>> {
    let script = format!(
        r#"
import imaplib, email, email.utils, json, time, sys
try:
    m = imaplib.IMAP4_SSL('{host}', {port})
    m.login('{user}', '{passwd}')
    m.select('INBOX')
    _, data = m.search(None, 'UNSEEN')
    ids = data[0].split()
    results = []
    for eid in ids:
        _, msg_data = m.fetch(eid, '(RFC822)')
        msg = email.message_from_bytes(msg_data[0][1])
        body = ''
        if msg.is_multipart():
            for part in msg.walk():
                if part.get_content_type() == 'text/plain':
                    payload = part.get_payload(decode=True)
                    if payload:
                        body = payload.decode('utf-8','ignore')[:4000]
                    break
        else:
            payload = msg.get_payload(decode=True)
            if payload:
                body = payload.decode('utf-8','ignore')[:4000]
        mid = msg.get('Message-ID', '')
        date_str = msg.get('Date', '')
        epoch = None
        parsed = email.utils.parsedate_tz(date_str)
        if parsed:
            epoch = int(email.utils.mktime_tz(parsed))
        from_addr = ''
        from_hdr = msg.get('From', '')
        parsed_from = email.utils.parseaddr(from_hdr)
        from_addr = parsed_from[1] if parsed_from[1] else from_hdr
        results.append({{
            'message_id': mid,
            'from': from_addr,
            'subject': str(msg.get('Subject', '(no subject)')),
            'date': date_str,
            'body': body.strip(),
            'epoch': epoch
        }})
    m.close()
    m.logout()
    print(json.dumps(results))
except Exception as e:
    print(json.dumps({{'error': str(e)}}))
    sys.exit(0)
"#,
        host = config.imap_host,
        port = config.imap_port,
        user = config.username,
        passwd = config.password,
    );

    let output = tokio::process::Command::new("python3")
        .args(["-c", &script])
        .output()
        .await?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    if stdout.trim().is_empty() {
        return Ok(vec![]);
    }
    let parsed: serde_json::Value = serde_json::from_str(stdout.trim())?;
    if let Some(err) = parsed.get("error") {
        anyhow::bail!("IMAP error: {}", err);
    }
    let emails: Vec<IncomingEmail> = serde_json::from_value(parsed)?;
    Ok(emails)
}

// ---------------------------------------------------------------------------
// SMTP helpers
// ---------------------------------------------------------------------------

/// Send an email (stub -- uses python's smtplib).
pub async fn send_email(to: &str, subject: &str, body: &str) -> anyhow::Result<()> {
    let config = EmailConfig::from_env().ok_or_else(|| anyhow::anyhow!("Email not configured"))?;
    send_email_with_config(&config, to, subject, body, None, None).await
}

/// Send a reply email with In-Reply-To and References headers for threading.
async fn send_email_with_config(
    config: &EmailConfig,
    to: &str,
    subject: &str,
    body: &str,
    in_reply_to: Option<&str>,
    references: Option<&str>,
) -> anyhow::Result<()> {
    let extra_headers = {
        let mut h = String::new();
        if let Some(irt) = in_reply_to {
            h.push_str(&format!(
                "    msg['In-Reply-To'] = '{}'\n",
                irt.replace('\'', "\\'")
            ));
        }
        if let Some(refs) = references {
            h.push_str(&format!(
                "    msg['References'] = '{}'\n",
                refs.replace('\'', "\\'")
            ));
        }
        h
    };

    let script = format!(
        r#"
import smtplib
from email.mime.text import MIMEText
try:
    msg = MIMEText('''{body}''')
    msg['Subject'] = '{subject}'
    msg['From'] = '{from_addr}'
    msg['To'] = '{to}'
{extra_headers}    s = smtplib.SMTP('{smtp_host}', {smtp_port})
    s.starttls()
    s.login('{smtp_user}', '{smtp_pass}')
    s.send_message(msg)
    s.quit()
    print('ok')
except Exception as e:
    print('error:' + str(e))
"#,
        body = body.replace('\'', "\\'").replace('\n', "\\n"),
        subject = subject.replace('\'', "\\'"),
        from_addr = config.username,
        to = to,
        extra_headers = extra_headers,
        smtp_host = config.smtp_host,
        smtp_port = config.smtp_port,
        smtp_user = config.username,
        smtp_pass = config.password,
    );

    let output = tokio::process::Command::new("python3")
        .args(["-c", &script])
        .output()
        .await?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    if stdout.trim().starts_with("error:") {
        anyhow::bail!("SMTP error: {}", stdout.trim());
    }

    info!("Email sent to {}: {}", to, subject);
    Ok(())
}

// ---------------------------------------------------------------------------
// Safety helpers
// ---------------------------------------------------------------------------

/// Addresses that should never receive auto-replies.
#[cfg(feature = "telegram")]
fn is_noreply_address(addr: &str) -> bool {
    let lower = addr.to_lowercase();
    lower.contains("noreply")
        || lower.contains("no-reply")
        || lower.contains("donotreply")
        || lower.contains("do-not-reply")
        || lower.contains("mailer-daemon")
        || lower.contains("postmaster")
        || lower.starts_with("bounce")
}

// ---------------------------------------------------------------------------
// Conversational email loop (requires telegram feature for agentic_chat)
// ---------------------------------------------------------------------------

/// Run the conversational email loop: poll IMAP for unread emails,
/// process each through the agentic LLM loop, and send a reply.
///
/// This is the email equivalent of `telegram_bridge::run_telegram_bot`.
/// Requires the `telegram` feature because it reuses `telegram_tools::agentic_chat`.
#[cfg(feature = "telegram")]
pub async fn run_conversational_email_loop(
    config: ConversationalEmailConfig,
    task_queue: std::sync::Arc<crate::task_queue::TaskQueue>,
    router: std::sync::Arc<tokio::sync::RwLock<crate::llm_router::LlmRouter>>,
    memory: Option<std::sync::Arc<tokio::sync::RwLock<crate::memory_plane::MemoryPlaneManager>>>,
    knowledge_graph: Option<
        std::sync::Arc<tokio::sync::RwLock<crate::knowledge_graph::KnowledgeGraph>>,
    >,
) {
    use crate::telegram_tools::{self, ConversationHistory, CronStore, SddStore, ToolContext};
    use std::sync::Arc;

    info!(
        "Starting conversational email loop (poll every {}s, {} allowed senders)",
        config.poll_interval.as_secs(),
        config.allowed_senders.len(),
    );

    let tool_ctx = ToolContext {
        router,
        task_queue,
        memory,
        knowledge_graph,
        history: Arc::new(ConversationHistory::new()),
        cron_store: Arc::new(CronStore::new()),
        sdd_store: Arc::new(SddStore::new()),
    };

    // Use a fixed "chat_id" for the email channel so conversation history
    // is maintained across email exchanges.
    const EMAIL_CHAT_ID: i64 = 0x454D_4149_4C00_0001;

    let mut seen_ids: HashSet<String> = HashSet::new();
    let mut interval = tokio::time::interval(config.poll_interval);

    // Rate-limit tracking: timestamps of replies in the current hour window.
    let mut reply_timestamps: Vec<std::time::Instant> = Vec::new();

    loop {
        interval.tick().await;

        // Prune rate-limit window (keep only last hour)
        let one_hour_ago = std::time::Instant::now() - Duration::from_secs(3600);
        reply_timestamps.retain(|t| *t > one_hour_ago);

        // Fetch unseen emails
        let emails = match fetch_unseen_emails(&config.email).await {
            Ok(e) => e,
            Err(e) => {
                warn!("[email_bridge] IMAP fetch error: {}", e);
                continue;
            }
        };

        let now_epoch = chrono::Utc::now().timestamp();

        for email in emails {
            // Skip already-processed
            if email.message_id.is_empty() || seen_ids.contains(&email.message_id) {
                continue;
            }
            seen_ids.insert(email.message_id.clone());

            // Skip emails older than 24h (prevents replaying old inbox)
            if let Some(epoch) = email.epoch {
                if now_epoch - epoch > 86_400 {
                    info!(
                        "[email_bridge] Skipping old email ({}h): {}",
                        (now_epoch - epoch) / 3600,
                        email.subject
                    );
                    continue;
                }
            }

            // Sender whitelist
            let sender_lower = email.from.to_lowercase();
            if !config.allowed_senders.contains(&sender_lower) {
                info!(
                    "[email_bridge] Sender not in whitelist, ignoring: {}",
                    email.from
                );
                continue;
            }

            // Skip noreply addresses
            if is_noreply_address(&sender_lower) {
                info!("[email_bridge] Skipping noreply address: {}", email.from);
                continue;
            }

            // Rate limit check
            if reply_timestamps.len() as u32 >= config.max_replies_per_hour {
                warn!(
                    "[email_bridge] Rate limit reached ({}/h), skipping email from {}",
                    config.max_replies_per_hour, email.from
                );
                continue;
            }

            // Build prompt similar to how Telegram formats incoming messages
            let prompt = format!(
                "Email from {}, subject: {}\n\n{}",
                email.from, email.subject, email.body
            );

            info!(
                "[email_bridge] Processing email from {} -- subject: {}",
                email.from, email.subject
            );

            // Run through the agentic chat loop (same as Telegram)
            let (response, _screenshot) =
                telegram_tools::agentic_chat(&tool_ctx, EMAIL_CHAT_ID, &prompt, None).await;

            // Build reply subject with "Re: " prefix (avoid double "Re: ")
            let reply_subject = if email.subject.to_lowercase().starts_with("re:") {
                email.subject.clone()
            } else {
                format!("Re: {}", email.subject)
            };

            // Send reply with threading headers
            let in_reply_to = if email.message_id.is_empty() {
                None
            } else {
                Some(email.message_id.as_str())
            };

            if let Err(e) = send_email_with_config(
                &config.email,
                &email.from,
                &reply_subject,
                &response,
                in_reply_to,
                in_reply_to, // References = same as In-Reply-To for first reply
            )
            .await
            {
                warn!(
                    "[email_bridge] Failed to send reply to {}: {}",
                    email.from, e
                );
            } else {
                reply_timestamps.push(std::time::Instant::now());
                info!(
                    "[email_bridge] Replied to {} -- subject: {}",
                    email.from, reply_subject
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(feature = "telegram")]
    #[test]
    fn test_noreply_detection() {
        assert!(is_noreply_address("noreply@github.com"));
        assert!(is_noreply_address("no-reply@example.com"));
        assert!(is_noreply_address("MAILER-DAEMON@mail.com"));
        assert!(is_noreply_address("donotreply@corp.com"));
        assert!(is_noreply_address("bounce+abc@mail.com"));
        assert!(!is_noreply_address("user@example.com"));
        assert!(!is_noreply_address("john@gmail.com"));
    }

    #[cfg(feature = "telegram")]
    #[test]
    fn test_conversational_config_requires_allowed_senders() {
        // Without env vars set, should return None
        assert!(ConversationalEmailConfig::from_env().is_none());
    }

    #[test]
    fn test_email_config_not_configured() {
        // Without env vars, should not be configured
        assert!(!EmailConfig::is_configured());
    }
}
