//! Tests for notification management module

#[cfg(test)]
mod tests {
    use super::super::*;

    #[test]
    fn test_notification_manager_creation() {
        let _manager = NotificationManager::new(true);
        // Just verify it doesn't panic
        assert!(true);
    }

    #[test]
    fn test_notification_manager_disabled() {
        let _manager = NotificationManager::new(false);
        // Just verify it doesn't panic
        assert!(true);
    }
}
