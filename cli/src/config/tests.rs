//! Tests for configuration module

#[cfg(test)]
mod tests {
    use super::super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn test_default_config() {
        let config = LifeConfig::default();
        assert_eq!(config.version, "1");
        assert!(config.ai.enabled);
        assert_eq!(config.ai.provider, "llama-server");
        assert_eq!(config.security.encryption, true);
    }

    #[test]
    fn test_system_config_default() {
        let sys = SystemConfig::default();
        assert_eq!(sys.hostname, "lifeos");
        assert_eq!(sys.timezone, "UTC");
        assert_eq!(sys.locale, "en_US.UTF-8");
        assert_eq!(sys.keyboard, "us");
    }

    #[test]
    fn test_ai_config_default() {
        let ai = AiConfig::default();
        assert!(ai.enabled);
        assert_eq!(ai.provider, "llama-server");
        assert_eq!(ai.model, "Qwen3.5-4B-Q4_K_M.gguf");
        assert_eq!(ai.llama_server_host, "http://localhost:8082");
    }

    #[test]
    fn test_security_config_default() {
        let sec = SecurityConfig::default();
        assert!(sec.encryption);
        assert!(sec.secure_boot);
        assert!(sec.auto_lock);
        assert_eq!(sec.auto_lock_timeout, 300);
    }

    #[test]
    fn test_update_config_default() {
        let upd = UpdateConfig::default();
        assert_eq!(upd.channel, "stable");
        assert!(upd.auto_check);
        assert!(!upd.auto_apply);
        assert_eq!(upd.schedule, "daily");
    }

    #[test]
    fn test_load_config_from_valid_file() {
        let config_str = r#"
version = "1"

[system]
hostname = "testhost"
timezone = "America/New_York"

[ai]
enabled = false
provider = "openai"
model = "gpt-4"

[security]
encryption = true
secure_boot = false
auto_lock = true
auto_lock_timeout = 300

[updates]
channel = "stable"
auto_check = true
auto_apply = false
schedule = "weekly"
"#;

        let mut file = NamedTempFile::new().unwrap();
        file.write_all(config_str.as_bytes()).unwrap();

        let config = load_config_from(file.path()).unwrap();
        assert_eq!(config.system.hostname, "testhost");
        assert_eq!(config.system.timezone, "America/New_York");
        assert!(!config.ai.enabled);
        assert_eq!(config.ai.provider, "openai");
    }

    #[test]
    fn test_load_config_from_invalid_toml() {
        let mut file = NamedTempFile::new().unwrap();
        file.write_all(b"invalid toml content {{").unwrap();

        let result = load_config_from(file.path());
        assert!(result.is_err());
    }

    #[test]
    fn test_load_config_with_missing_required_system_fields_uses_defaults() {
        let config_str = r#"
version = "1"

[system]
timezone = "America/Mexico_City"

[updates]
channel = "edge"
"#;

        let mut file = NamedTempFile::new().unwrap();
        file.write_all(config_str.as_bytes()).unwrap();

        let config = load_config_from(file.path()).unwrap();
        assert_eq!(config.system.hostname, "lifeos");
        assert_eq!(config.system.timezone, "America/Mexico_City");
        assert_eq!(config.updates.channel, "edge");
    }

    #[test]
    fn test_load_config_with_missing_sections_uses_defaults() {
        let config_str = r#"
[updates]
channel = "candidate"
"#;

        let mut file = NamedTempFile::new().unwrap();
        file.write_all(config_str.as_bytes()).unwrap();

        let config = load_config_from(file.path()).unwrap();
        assert_eq!(config.version, "1");
        assert_eq!(config.system.hostname, "lifeos");
        assert_eq!(config.ai.provider, "llama-server");
        assert_eq!(config.security.secure_boot, true);
        assert_eq!(config.updates.channel, "candidate");
    }

    #[test]
    fn test_load_config_from_nonexistent_file() {
        let path = std::path::PathBuf::from("/nonexistent/path/config.toml");
        let result = load_config_from(&path);
        assert!(result.is_err());
    }

    #[test]
    fn test_save_and_load_config() {
        let config = LifeConfig {
            version: "2".to_string(),
            system: SystemConfig {
                hostname: "myhost".to_string(),
                timezone: "Europe/London".to_string(),
                locale: "en_GB.UTF-8".to_string(),
                keyboard: "uk".to_string(),
            },
            ai: AiConfig {
                enabled: true,
                provider: "anthropic".to_string(),
                model: "claude-3".to_string(),
                llama_server_host: "http://localhost:8082".to_string(),
            },
            security: SecurityConfig::default(),
            updates: UpdateConfig::default(),
        };

        let file = NamedTempFile::new().unwrap();
        save_config(&config, file.path()).unwrap();

        let loaded = load_config_from(file.path()).unwrap();
        assert_eq!(loaded.version, "2");
        assert_eq!(loaded.system.hostname, "myhost");
        assert_eq!(loaded.ai.provider, "anthropic");
    }

    #[test]
    fn test_set_config_value_hostname() {
        let mut config = LifeConfig::default();
        set_config_value(&mut config, "system.hostname", "newhost").unwrap();
        assert_eq!(config.system.hostname, "newhost");
    }

    #[test]
    fn test_set_config_value_ai_enabled() {
        let mut config = LifeConfig::default();
        set_config_value(&mut config, "ai.enabled", "false").unwrap();
        assert!(!config.ai.enabled);

        set_config_value(&mut config, "ai.enabled", "true").unwrap();
        assert!(config.ai.enabled);
    }

    #[test]
    fn test_set_config_value_security_timeout() {
        let mut config = LifeConfig::default();
        set_config_value(&mut config, "security.auto_lock_timeout", "600").unwrap();
        assert_eq!(config.security.auto_lock_timeout, 600);
    }

    #[test]
    fn test_set_config_value_update_channel() {
        let mut config = LifeConfig::default();
        set_config_value(&mut config, "updates.channel", "beta").unwrap();
        assert_eq!(config.updates.channel, "beta");
    }

    #[test]
    fn test_set_config_value_unknown_key() {
        let mut config = LifeConfig::default();
        let result = set_config_value(&mut config, "unknown.key", "value");
        assert!(result.is_err());
    }

    #[test]
    fn test_set_config_value_invalid_bool() {
        let mut config = LifeConfig::default();
        let result = set_config_value(&mut config, "ai.enabled", "not_a_bool");
        assert!(result.is_err());
    }

    #[test]
    fn test_set_config_value_invalid_number() {
        let mut config = LifeConfig::default();
        let result = set_config_value(&mut config, "security.auto_lock_timeout", "not_a_number");
        assert!(result.is_err());
    }

    #[test]
    fn test_get_config_value_hostname() {
        let config = LifeConfig::default();
        let value = get_config_value(&config, "system.hostname").unwrap();
        assert_eq!(value, "lifeos");
    }

    #[test]
    fn test_get_config_value_ai_enabled() {
        let config = LifeConfig::default();
        let value = get_config_value(&config, "ai.enabled").unwrap();
        assert_eq!(value, "true");
    }

    #[test]
    fn test_get_config_value_unknown_key() {
        let config = LifeConfig::default();
        let result = get_config_value(&config, "unknown.key");
        assert!(result.is_err());
    }

    #[test]
    fn test_default_config_path() {
        let path = default_config_path();
        assert!(path.to_string_lossy().contains("lifeos.toml"));
    }

    #[test]
    fn test_serde_roundtrip() {
        let config = LifeConfig::default();
        let toml_str = toml::to_string_pretty(&config).unwrap();
        let parsed: LifeConfig = toml::from_str(&toml_str).unwrap();

        assert_eq!(config.version, parsed.version);
        assert_eq!(config.system.hostname, parsed.system.hostname);
        assert_eq!(config.ai.enabled, parsed.ai.enabled);
    }
}
