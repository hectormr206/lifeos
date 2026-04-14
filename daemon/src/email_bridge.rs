//! Email integration — IMAP/SMTP helpers for the dashboard and agent tools.
//!
//! Provides email read/send capabilities. This module is NOT a conversational
//! bridge; the auto-reply loop was removed when LifeOS narrowed its user-facing
//! channels to SimpleX + dashboard chat. What remains is:
//!
//! - `EmailConfig::from_env()` — read IMAP/SMTP settings from env
//! - `list_recent_emails(limit)` — list recent inbox messages (dashboard API)
//! - `send_email(to, subject, body)` — outbound send (dashboard API + tools)
//!
//! Configuration via environment variables:
//! - LIFEOS_EMAIL_IMAP_HOST, LIFEOS_EMAIL_IMAP_USER, LIFEOS_EMAIL_IMAP_PASS
//! - LIFEOS_EMAIL_SMTP_HOST, LIFEOS_EMAIL_SMTP_USER, LIFEOS_EMAIL_SMTP_PASS

use log::info;
use serde::{Deserialize, Serialize};

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
        results.append({{
            'from': str(msg.get('From', '')),
            'subject': str(msg.get('Subject', '(no subject)')),
            'date': str(msg.get('Date', '')),
            'preview': body.strip()
        }})
    m.close()
    m.logout()
    print(json.dumps(results))
except Exception as e:
    print(json.dumps({{'error': str(e)}}))
    sys.exit(0)
"#,
        config.imap_host, config.imap_port, config.username, config.password, limit,
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

    let emails: Vec<EmailSummary> = serde_json::from_value(parsed)?;
    Ok(emails)
}

// ---------------------------------------------------------------------------
// SMTP helpers
// ---------------------------------------------------------------------------

/// Send an email (stub -- uses python's smtplib).
pub async fn send_email(to: &str, subject: &str, body: &str) -> anyhow::Result<()> {
    let config = EmailConfig::from_env().ok_or_else(|| anyhow::anyhow!("Email not configured"))?;
    send_email_with_config(&config, to, subject, body).await
}

/// Send an email via SMTP.
async fn send_email_with_config(
    config: &EmailConfig,
    to: &str,
    subject: &str,
    body: &str,
) -> anyhow::Result<()> {
    let script = format!(
        r#"
import smtplib
from email.mime.text import MIMEText
try:
    msg = MIMEText('''{body}''')
    msg['Subject'] = '{subject}'
    msg['From'] = '{from_addr}'
    msg['To'] = '{to}'
    s = smtplib.SMTP('{smtp_host}', {smtp_port})
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
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_email_config_not_configured() {
        // Without env vars, should not be configured
        assert!(!EmailConfig::is_configured());
    }
}
