//! Tests for health monitoring module

#[cfg(test)]
mod tests {
    use super::super::*;

    #[test]
    fn test_health_report_struct() {
        let report = HealthReport {
            healthy: true,
            timestamp: chrono::Local::now(),
            issues: vec![],
            checks: vec![],
        };

        assert!(report.healthy);
        assert!(report.issues.is_empty());
    }

    #[test]
    fn test_health_issue_creation() {
        let issue = HealthIssue {
            severity: Severity::Warning,
            component: "disk".to_string(),
            message: "Low disk space".to_string(),
            suggestion: Some("Clean up files".to_string()),
        };

        assert_eq!(issue.component, "disk");
        assert_eq!(issue.severity, Severity::Warning);
    }

    #[test]
    fn test_severity_enum() {
        assert_ne!(Severity::Info, Severity::Warning);
        assert_ne!(Severity::Warning, Severity::Critical);
    }

    #[test]
    fn test_check_result() {
        let result = CheckResult {
            name: "bootc".to_string(),
            passed: true,
            message: "OK".to_string(),
        };

        assert!(result.passed);
        assert_eq!(result.name, "bootc");
    }
}
