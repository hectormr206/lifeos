//! Tests for notification management module

#[cfg(test)]
mod tests {
    use super::super::*;

    #[test]
    fn test_notification_manager_creation() {
        let manager = NotificationManager::new(true);
        let debug_repr = format!("{manager:?}");
        assert!(debug_repr.contains("enabled: true"));
    }

    #[tokio::test]
    async fn test_notification_manager_disabled() {
        let manager = NotificationManager::new(false);
        assert!(manager
            .send_system_notification("title", "message")
            .await
            .is_ok());
    }
}
