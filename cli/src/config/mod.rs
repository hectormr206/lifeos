//! Configuration management for LifeOS
use std::path::PathBuf;
use serde::{Deserialize, Serialize};

#[cfg(test)]
mod tests;

/// LifeOS configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LifeConfig {
    pub version: String,
    pub system: SystemConfig,
    pub ai: AiConfig,
    pub security: SecurityConfig,
    #[serde(default)]
    pub updates: UpdateConfig,
}

impl Default for LifeConfig {
    fn default() -> Self {
        Self {
            version: "1".to_string(),
            system: SystemConfig::default(),
            ai: AiConfig::default(),
            security: SecurityConfig::default(),
            updates: UpdateConfig::default(),
        }
    }
}

/// System configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SystemConfig {
    pub hostname: String,
    pub timezone: String,
    #[serde(default)]
    pub locale: String,
    #[serde(default)]
    pub keyboard: String,
}

impl Default for SystemConfig {
    fn default() -> Self {
        Self {
            hostname: "lifeos".to_string(),
            timezone: "UTC".to_string(),
            locale: "en_US.UTF-8".to_string(),
            keyboard: "us".to_string(),
        }
    }
}

/// AI configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub provider: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub ollama_host: String,
}

impl Default for AiConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            provider: "ollama".to_string(),
            model: "llama3.2".to_string(),
            ollama_host: "http://localhost:11434".to_string(),
        }
    }
}

/// Security configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecurityConfig {
    #[serde(default)]
    pub encryption: bool,
    #[serde(default)]
    pub secure_boot: bool,
    #[serde(default)]
    pub auto_lock: bool,
    #[serde(default)]
    pub auto_lock_timeout: u32,
}

impl Default for SecurityConfig {
    fn default() -> Self {
        Self {
            encryption: true,
            secure_boot: true,
            auto_lock: true,
            auto_lock_timeout: 300,
        }
    }
}

/// Update configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateConfig {
    #[serde(default = "default_channel")]
    pub channel: String,
    #[serde(default)]
    pub auto_check: bool,
    #[serde(default)]
    pub auto_apply: bool,
    #[serde(default = "default_schedule")]
    pub schedule: String,
}

fn default_channel() -> String {
    "stable".to_string()
}

fn default_schedule() -> String {
    "daily".to_string()
}

impl Default for UpdateConfig {
    fn default() -> Self {
        Self {
            channel: default_channel(),
            auto_check: true,
            auto_apply: false,
            schedule: default_schedule(),
        }
    }
}

/// Load configuration from file
pub fn load_config() -> anyhow::Result<LifeConfig> {
    let path = find_config_file()
        .ok_or_else(|| anyhow::anyhow!("No configuration file found"))?;
    
    load_config_from(&path)
}

/// Load configuration from specific path
pub fn load_config_from(path: &std::path::Path) -> anyhow::Result<LifeConfig> {
    let contents = std::fs::read_to_string(path)?;
    let config: LifeConfig = toml::from_str(&contents)?;
    Ok(config)
}

/// Save configuration to file
pub fn save_config(config: &LifeConfig, path: &std::path::Path) -> anyhow::Result<()> {
    let contents = toml::to_string_pretty(config)?;
    std::fs::write(path, contents)?;
    Ok(())
}

/// Find configuration file in standard locations
pub fn find_config_file() -> Option<PathBuf> {
    // Check XDG config directory
    if let Some(config_dir) = dirs::config_dir() {
        let path = config_dir.join("lifeos").join("lifeos.toml");
        if path.exists() {
            return Some(path);
        }
    }

    // Check /etc
    let etc_path = PathBuf::from("/etc/lifeos/lifeos.toml");
    if etc_path.exists() {
        return Some(etc_path);
    }

    // Check current directory
    let local_path = PathBuf::from("lifeos.toml");
    if local_path.exists() {
        return Some(local_path);
    }

    None
}

/// Get the default configuration path
#[allow(dead_code)]
pub fn default_config_path() -> PathBuf {
    dirs::config_dir()
        .map(|d| d.join("lifeos").join("lifeos.toml"))
        .unwrap_or_else(|| PathBuf::from("lifeos.toml"))
}

/// Ensure config directory exists
pub fn ensure_config_dir() -> anyhow::Result<PathBuf> {
    let config_dir = dirs::config_dir()
        .ok_or_else(|| anyhow::anyhow!("Could not find config directory"))?
        .join("lifeos");
    
    std::fs::create_dir_all(&config_dir)?;
    Ok(config_dir)
}

/// Create default configuration file
pub fn create_default_config() -> anyhow::Result<PathBuf> {
    let config_dir = ensure_config_dir()?;
    let config_path = config_dir.join("lifeos.toml");
    
    let config = LifeConfig::default();
    save_config(&config, &config_path)?;
    
    Ok(config_path)
}

/// Set a configuration value by key path
pub fn set_config_value(config: &mut LifeConfig, key: &str, value: &str) -> anyhow::Result<()> {
    let parts: Vec<&str> = key.split('.').collect();
    
    match parts.as_slice() {
        ["system", "hostname"] => config.system.hostname = value.to_string(),
        ["system", "timezone"] => config.system.timezone = value.to_string(),
        ["system", "locale"] => config.system.locale = value.to_string(),
        ["ai", "enabled"] => config.ai.enabled = value.parse()?,        ["ai", "provider"] => config.ai.provider = value.to_string(),
        ["ai", "model"] => config.ai.model = value.to_string(),
        ["ai", "ollama_host"] => config.ai.ollama_host = value.to_string(),
        ["security", "encryption"] => config.security.encryption = value.parse()?,
        ["security", "secure_boot"] => config.security.secure_boot = value.parse()?,
        ["security", "auto_lock"] => config.security.auto_lock = value.parse()?,
        ["security", "auto_lock_timeout"] => {
            config.security.auto_lock_timeout = value.parse()?;
        }
        ["updates", "channel"] => config.updates.channel = value.to_string(),
        ["updates", "auto_check"] => config.updates.auto_check = value.parse()?,
        ["updates", "auto_apply"] => config.updates.auto_apply = value.parse()?,
        ["updates", "schedule"] => config.updates.schedule = value.to_string(),
        _ => anyhow::bail!("Unknown configuration key: {}", key),
    }
    
    Ok(())
}

/// Get a configuration value by key path
pub fn get_config_value(config: &LifeConfig, key: &str) -> anyhow::Result<String> {
    let parts: Vec<&str> = key.split('.').collect();
    
    let value = match parts.as_slice() {
        ["system", "hostname"] => config.system.hostname.clone(),
        ["system", "timezone"] => config.system.timezone.clone(),
        ["system", "locale"] => config.system.locale.clone(),
        ["ai", "enabled"] => config.ai.enabled.to_string(),
        ["ai", "provider"] => config.ai.provider.clone(),
        ["ai", "model"] => config.ai.model.clone(),
        ["security", "encryption"] => config.security.encryption.to_string(),
        ["security", "secure_boot"] => config.security.secure_boot.to_string(),
        ["updates", "channel"] => config.updates.channel.clone(),
        ["updates", "auto_check"] => config.updates.auto_check.to_string(),
        ["updates", "auto_apply"] => config.updates.auto_apply.to_string(),
        _ => anyhow::bail!("Unknown configuration key: {}", key),
    };
    
    Ok(value)
}