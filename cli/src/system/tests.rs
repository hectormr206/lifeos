//! Tests for system module

#[cfg(test)]
mod system_module_tests {
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
        assert_eq!(
            status.rollback_slot,
            Some("ghcr.io/example/lifeos:previous".to_string())
        );
    }

    #[test]
    fn test_bootc_status_parsing_nested_version() {
        let json = serde_json::json!({
            "status": {
                "booted": {
                    "image": {
                        "reference": "ghcr.io/hectormr206/lifeos:edge",
                        "version": "edge-20260408-f6f80ec"
                    }
                },
                "rollback": {
                    "image": {
                        "reference": "ghcr.io/hectormr206/lifeos:previous"
                    }
                }
            }
        });

        let status = parse_bootc_status(json).unwrap();
        assert_eq!(status.booted_slot, "ghcr.io/hectormr206/lifeos:edge");
        assert_eq!(status.slots[0].version, "edge-20260408-f6f80ec");
        assert_eq!(
            status.rollback_slot,
            Some("ghcr.io/hectormr206/lifeos:previous".to_string())
        );
    }

    #[test]
    fn test_bootc_status_text_parsing() {
        let text = r#"
● Booted image: ghcr.io/hectormr206/lifeos:edge
        Digest: sha256:abc123
        Version: edge-20260408-f6f80ec

Rollback image: ghcr.io/hectormr206/lifeos:edge-20260403-b369513
        Digest: sha256:def456
        Version: edge-20260403-b369513
"#;

        let status = parse_bootc_status_text(text).unwrap();
        assert_eq!(status.booted_slot, "ghcr.io/hectormr206/lifeos:edge");
        assert_eq!(status.slots[0].version, "edge-20260408-f6f80ec");
        assert_eq!(
            status.rollback_slot,
            Some("ghcr.io/hectormr206/lifeos:edge-20260403-b369513".to_string())
        );
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
            HealthStatus::Healthy | HealthStatus::Degraded(_) | HealthStatus::Unhealthy(_) => (), // Pass
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

    fn system_state(
        scope: &'static str,
        load_state: &str,
        active_state: &str,
        sub_state: &str,
        result: &str,
    ) -> SystemdUnitState {
        SystemdUnitState {
            scope,
            load_state: load_state.to_string(),
            active_state: active_state.to_string(),
            sub_state: sub_state.to_string(),
            result: result.to_string(),
        }
    }

    #[test]
    fn test_assess_ai_service_treats_clean_inactive_as_on_demand() {
        let assessment = assess_ai_service(
            Some(system_state(
                "system", "loaded", "inactive", "dead", "success",
            )),
            None,
            None,
        );

        assert_eq!(assessment.issue, None);
        assert!(assessment.status_message.contains("on-demand"));
        assert!(!assessment.restart_recommended);
    }

    #[test]
    fn test_assess_ai_service_reports_persisted_preflight_reason() {
        let assessment = assess_ai_service(
            Some(system_state(
                "system", "loaded", "inactive", "dead", "success",
            )),
            None,
            Some("llama-server preflight: unsupported CPU".to_string()),
        );

        assert_eq!(
            assessment.issue,
            Some("llama-server preflight: unsupported CPU".to_string())
        );
        assert!(!assessment.restart_recommended);
    }

    #[test]
    fn test_assess_ai_service_reports_failed_unit() {
        let assessment = assess_ai_service(
            Some(system_state(
                "system",
                "loaded",
                "failed",
                "failed",
                "exit-code",
            )),
            None,
            None,
        );

        assert_eq!(
            assessment.issue,
            Some("llama-server system service failed (exit-code)".to_string())
        );
        assert!(assessment.restart_recommended);
    }

    /// Phase 3 cutover canonicalization: `lifeosd_status_message` must
    /// return a message that references either the canonical post-pivot
    /// unit name `lifeos-lifeosd.service` or the legacy `lifeosd` name
    /// (rollback path). Anchors the display-string contract so a future
    /// rename does not silently regress what the user sees in `life check`.
    #[test]
    fn test_lifeosd_status_message_running_mentions_lifeosd() {
        let msg = lifeosd_status_message(true);
        assert!(
            msg.contains("lifeosd"),
            "expected message to reference lifeosd; got {:?}",
            msg
        );
    }
}
