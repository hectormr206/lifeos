//! Tests for system module

#[cfg(test)]
mod tests {
    use super::super::*;

    #[test]
    fn test_health_status_display_healthy() {
        let status = HealthStatus::Healthy;
        assert_eq!(status.to_string(), "healthy");
    }

    #[test]
    fn test_health_status_display_degraded() {
        let status = HealthStatus::Degraded("disk full".to_string());
        assert_eq!(status.to_string(), "degraded: disk full");
    }

    #[test]
    fn test_health_status_display_unhealthy() {
        let status = HealthStatus::Unhealthy("critical error".to_string());
        assert_eq!(status.to_string(), "unhealthy: critical error");
    }

    #[test]
    fn test_bootc_status_parsing() {
        let json = serde_json::json!({
            "status": {
                "booted": {
                    "image": {
                        "image": "ghcr.io/example/lifeos:latest"
                    },
                    "version": "v0.1.0"
                },
                "rollback": {
                    "image": {
                        "image": "ghcr.io/example/lifeos:previous"
                    }
                }
            }
        });

        let status = parse_bootc_status(json).unwrap();
        assert_eq!(status.booted_slot, "ghcr.io/example/lifeos:latest");
        assert_eq!(status.slots[0].version, "v0.1.0");
        assert_eq!(status.rollback_slot, Some("ghcr.io/example/lifeos:previous".to_string()));
    }

    #[test]
    fn test_bootc_status_parsing_missing_booted() {
        let json = serde_json::json!({
            "status": {
                "rollback": {}
            }
        });

        let result = parse_bootc_status(json);
        assert!(result.is_err());
    }

    #[test]
    fn test_bootc_status_parsing_missing_status() {
        let json = serde_json::json!({});

        let result = parse_bootc_status(json);
        assert!(result.is_err());
    }

    #[test]
    fn test_bootc_slot_struct() {
        let slot = BootcSlot {
            name: "test".to_string(),
            version: "v1.0.0".to_string(),
            image: Some("ghcr.io/test".to_string()),
            booted: true,
            rollback: false,
        };

        assert_eq!(slot.name, "test");
        assert!(slot.booted);
        assert!(!slot.rollback);
    }

    #[test]
    fn test_system_status_struct() {
        let status = SystemStatus {
            version: "0.1.0".to_string(),
            slot: "A".to_string(),
            channel: "stable".to_string(),
            mode: "personal".to_string(),
            health: HealthStatus::Healthy,
            updates_available: false,
            bootc_status: None,
        };

        assert_eq!(status.slot, "A");
        assert_eq!(status.channel, "stable");
    }

    #[test]
    fn test_update_result_struct() {
        let result = UpdateResult {
            would_update: true,
            from_version: "v0.1.0".to_string(),
            to_version: "v0.2.0".to_string(),
            changes: vec!["Fix bug".to_string(), "Add feature".to_string()],
        };

        assert!(result.would_update);
        assert_eq!(result.changes.len(), 2);
    }

    #[test]
    fn test_health_check_struct() {
        let check = HealthCheck {
            name: "bootc".to_string(),
            passed: true,
            message: "OK".to_string(),
        };

        assert!(check.passed);
        assert_eq!(check.name, "bootc");
    }

    #[test]
    fn test_recovery_report_struct() {
        let report = RecoveryReport {
            checks: vec![],
            repairs: vec!["Fixed permissions".to_string()],
            needs_reboot: true,
        };

        assert!(report.needs_reboot);
        assert_eq!(report.repairs.len(), 1);
    }

    #[test]
    fn test_check_health_returns_status() {
        // This test may vary depending on the environment
        let health = check_health();
        // Just verify it returns a valid status
        match health {
            HealthStatus::Healthy |
            HealthStatus::Degraded(_) |
            HealthStatus::Unhealthy(_) => (), // Pass
        }
    }

    #[test]
    fn test_bootc_availability_check() {
        // Just verify the function doesn't panic
        let _available = is_bootc_available();
    }

    #[test]
    fn test_check_updates_returns_result() {
        let result = check_updates("stable");
        assert!(result.is_ok());
    }
}
