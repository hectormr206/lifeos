//! Notification management module
//! Handles desktop notifications for system events

use notify_rust::Notification;
use log::{info, error};

#[cfg(test)]
mod notifications_tests;

/// Notification manager
#[derive(Debug)]
pub struct NotificationManager {
    enabled: bool,
    app_name: String,
    icon: String,
}

impl NotificationManager {
    pub fn new(enabled: bool) -> Self {
        Self {
            enabled,
            app_name: "LifeOS".to_string(),
            icon: "lifeos".to_string(),
        }
    }

    /// Send a system notification
    fn send(&self,
        summary: &str,
        body: &str,
        urgency: notify_rust::Urgency,
    ) -> anyhow::Result<()> {
        if !self.enabled {
            info!("Notification (disabled): {} - {}", summary, body);
            return Ok(());
        }

        Notification::new()
            .summary(summary)
            .body(body)
            .icon(&self.icon)
            .appname(&self.app_name)
            .urgency(urgency)
            .show()
            .map_err(|e| anyhow::anyhow!("Failed to show notification: {}", e))?;

        Ok(())
    }

    /// Send health alert notification
    pub async fn send_health_alert(
        &self,
        issue: &super::health::HealthIssue,
    ) -> anyhow::Result<()> {
        let urgency = match issue.severity {
            super::health::Severity::Critical => notify_rust::Urgency::Critical,
            super::health::Severity::Warning => notify_rust::Urgency::Normal,
            super::health::Severity::Info => notify_rust::Urgency::Low,
        };

        let suggestion = issue.suggestion.as_ref()
            .map(|s| format!("\n\nSuggestion: {}", s))
            .unwrap_or_default();

        self.send(
            &format!("LifeOS Alert: {}", issue.component),
            &format!("{}{}", issue.message, suggestion),
            urgency,
        )
    }

    /// Send update available notification
    pub async fn send_update_notification(
        &self,
        version: &str,
    ) -> anyhow::Result<()> {
        self.send(
            "LifeOS Update Available",
            &format!("Version {} is available. Run 'life update' to install.", version),
            notify_rust::Urgency::Normal,
        )
    }

    /// Send disk warning notification
    pub async fn send_disk_warning(
        &self,
        usage_percent: f32,
    ) -> anyhow::Result<()> {
        self.send(
            "LifeOS: Low Disk Space",
            &format!("Disk usage is at {:.1}%. Consider freeing up space.", usage_percent),
            notify_rust::Urgency::Critical,
        )
    }

    /// Send generic system notification
    pub async fn send_system_notification(
        &self,
        title: &str,
        message: &str,
    ) -> anyhow::Result<()> {
        self.send(title, message, notify_rust::Urgency::Normal)
    }
}

impl Default for NotificationManager {
    fn default() -> Self {
        Self::new(true)
    }
}
