//! Tests for update checking module

#[cfg(test)]
mod tests {
    use super::super::*;

    #[test]
    fn test_update_result_struct() {
        let result = UpdateResult {
            available: true,
            current_version: "0.1.0".to_string(),
            new_version: "0.2.0".to_string(),
            changelog: Some("New features".to_string()),
            size_mb: Some(100),
        };

        assert!(result.available);
        assert_eq!(result.current_version, "0.1.0");
        assert_eq!(result.new_version, "0.2.0");
    }

    #[test]
    fn test_update_result_default_not_available() {
        let result = UpdateResult {
            available: false,
            current_version: "0.1.0".to_string(),
            new_version: "0.1.0".to_string(),
            changelog: None,
            size_mb: None,
        };

        assert!(!result.available);
    }

    #[test]
    fn test_update_checker_creation() {
        let checker = UpdateChecker::new();
        let debug_repr = format!("{checker:?}");
        assert!(debug_repr.contains("UpdateChecker"));
    }
}
