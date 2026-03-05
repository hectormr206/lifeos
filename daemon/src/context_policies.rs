//! Context Policies (Workplace)
//!
//! Manages different user contexts with automatic rule application:
//! - Context detection (Home, Work, Gaming, etc.)
//! - Profiles and rules per context
//! - Automatic context switching
//! - Integration with experience modes

use anyhow::{Context, Result};
use chrono::{DateTime, Datelike, Local, Timelike, Utc};
use log::{info, warn};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;

/// User context type
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub enum ContextType {
    Home,
    Work,
    Gaming,
    Creative,
    Development,
    Social,
    Learning,
    Travel,
    Custom(String),
}

impl std::fmt::Display for ContextType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ContextType::Home => write!(f, "home"),
            ContextType::Work => write!(f, "work"),
            ContextType::Gaming => write!(f, "gaming"),
            ContextType::Creative => write!(f, "creative"),
            ContextType::Development => write!(f, "development"),
            ContextType::Social => write!(f, "social"),
            ContextType::Learning => write!(f, "learning"),
            ContextType::Travel => write!(f, "travel"),
            ContextType::Custom(name) => write!(f, "{}", name),
        }
    }
}

impl std::str::FromStr for ContextType {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self> {
        match s.to_lowercase().as_str() {
            "home" => Ok(ContextType::Home),
            "work" => Ok(ContextType::Work),
            "gaming" => Ok(ContextType::Gaming),
            "creative" => Ok(ContextType::Creative),
            "development" => Ok(ContextType::Development),
            "social" => Ok(ContextType::Social),
            "learning" => Ok(ContextType::Learning),
            "travel" => Ok(ContextType::Travel),
            custom => Ok(ContextType::Custom(custom.to_string())),
        }
    }
}

/// Context detection method
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum DetectionMethod {
    Manual,
    TimeBased,
    LocationBased,
    ApplicationBased,
    NetworkBased,
}

/// Context rule
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContextRule {
    pub id: String,
    pub name: String,
    pub description: String,
    pub rule_type: RuleType,
    pub enabled: bool,
    pub priority: u32,
}

/// Rule type
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum RuleType {
    /// Disable notifications
    DisableNotifications,
    /// Set experience mode
    SetExperienceMode(String),
    /// Set AI model
    SetAiModel(String),
    /// Enable/disable screen capture
    ScreenCapture(bool),
    /// Set update channel
    SetUpdateChannel(String),
    /// Disable specific applications
    BlockApplication(String),
    /// Set privacy level
    SetPrivacyLevel(String),
}

/// Context profile
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContextProfile {
    pub context: ContextType,
    pub name: String,
    pub description: String,
    pub detection_method: DetectionMethod,
    pub rules: Vec<ContextRule>,
    /// Time-based detection schedule
    pub time_schedule: Option<TimeSchedule>,
    /// Applications that trigger this context
    pub trigger_applications: Vec<String>,
    /// Network SSID that triggers this context
    pub trigger_network: Option<String>,
    /// Priority for automatic switching
    pub priority: u32,
}

/// Time schedule for automatic context switching
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimeSchedule {
    pub start_hour: u8,
    pub start_minute: u8,
    pub end_hour: u8,
    pub end_minute: u8,
    pub days: Vec<u8>, // 0=Sunday, 6=Saturday
}

/// Context state
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContextState {
    pub current_context: ContextType,
    pub active_profile: String,
    pub last_switch: DateTime<Utc>,
    pub detection_method: DetectionMethod,
}

/// Context policies manager
pub struct ContextPoliciesManager {
    profiles: Arc<RwLock<HashMap<String, ContextProfile>>>,
    current_state: Arc<RwLock<ContextState>>,
    config_dir: PathBuf,
}

impl ContextPoliciesManager {
    /// Create new context policies manager
    pub fn new(config_dir: PathBuf) -> Result<Self> {
        let manager = Self {
            profiles: Arc::new(RwLock::new(HashMap::new())),
            current_state: Arc::new(RwLock::new(ContextState {
                current_context: ContextType::Home,
                active_profile: "default".to_string(),
                last_switch: Utc::now(),
                detection_method: DetectionMethod::Manual,
            })),
            config_dir,
        };

        // Profiles and state will be loaded lazily via async methods

        info!("Context policies manager initialized");

        Ok(manager)
    }

    /// Initialize profiles and state from disk.
    pub async fn initialize(&self) -> Result<()> {
        self.load_profiles().await?;
        self.load_state().await?;
        Ok(())
    }

    /// Load context profiles
    async fn load_profiles(&self) -> Result<()> {
        let profiles_file = self.config_dir.join("context_profiles.json");
        if !profiles_file.exists() {
            // Create default profiles
            self.create_default_profiles().await;
            return Ok(());
        }

        let profiles_content = tokio::fs::read_to_string(&profiles_file).await?;
        let profiles: HashMap<String, ContextProfile> =
            serde_json::from_str(&profiles_content).context("Failed to parse context profiles")?;

        let profiles_count = profiles.len();
        *self.profiles.write().await = profiles;

        info!("Context profiles loaded: {} profiles", profiles_count);

        Ok(())
    }

    /// Save context profiles
    pub async fn save_profiles(&self) -> Result<()> {
        let profiles = self.profiles.read().await;
        let profiles_file = self.config_dir.join("context_profiles.json");
        let profiles_content = serde_json::to_string_pretty(&*profiles)?;

        tokio::fs::write(&profiles_file, profiles_content)
            .await
            .context("Failed to save context profiles")?;

        info!("Context profiles saved");

        Ok(())
    }

    /// Create default context profiles
    async fn create_default_profiles(&self) {
        let profiles = vec![
            ContextProfile {
                context: ContextType::Home,
                name: "Home".to_string(),
                description: "Personal use at home".to_string(),
                detection_method: DetectionMethod::Manual,
                rules: vec![
                    ContextRule {
                        id: "home-notifications".to_string(),
                        name: "Enable All Notifications".to_string(),
                        description: "Allow all notifications".to_string(),
                        rule_type: RuleType::DisableNotifications,
                        enabled: true,
                        priority: 1,
                    },
                    ContextRule {
                        id: "home-mode".to_string(),
                        name: "Simple Mode".to_string(),
                        description: "Use simple experience mode".to_string(),
                        rule_type: RuleType::SetExperienceMode("simple".to_string()),
                        enabled: true,
                        priority: 2,
                    },
                ],
                time_schedule: None,
                trigger_applications: vec![],
                trigger_network: None,
                priority: 1,
            },
            ContextProfile {
                context: ContextType::Work,
                name: "Work".to_string(),
                description: "Professional work environment".to_string(),
                detection_method: DetectionMethod::NetworkBased,
                rules: vec![
                    ContextRule {
                        id: "work-notifications".to_string(),
                        name: "Work Notifications".to_string(),
                        description: "Only important notifications".to_string(),
                        rule_type: RuleType::DisableNotifications,
                        enabled: true,
                        priority: 1,
                    },
                    ContextRule {
                        id: "work-mode".to_string(),
                        name: "Pro Mode".to_string(),
                        description: "Use pro experience mode".to_string(),
                        rule_type: RuleType::SetExperienceMode("pro".to_string()),
                        enabled: true,
                        priority: 2,
                    },
                    ContextRule {
                        id: "work-block-apps".to_string(),
                        name: "Block Gaming Apps".to_string(),
                        description: "Block gaming applications".to_string(),
                        rule_type: RuleType::BlockApplication("steam".to_string()),
                        enabled: true,
                        priority: 3,
                    },
                ],
                time_schedule: Some(TimeSchedule {
                    start_hour: 9,
                    start_minute: 0,
                    end_hour: 18,
                    end_minute: 0,
                    days: vec![1, 2, 3, 4, 5], // Monday-Friday
                }),
                trigger_applications: vec![],
                trigger_network: Some("work-ssid".to_string()),
                priority: 2,
            },
            ContextProfile {
                context: ContextType::Gaming,
                name: "Gaming".to_string(),
                description: "Gaming and entertainment".to_string(),
                detection_method: DetectionMethod::ApplicationBased,
                rules: vec![
                    ContextRule {
                        id: "gaming-notifications".to_string(),
                        name: "Disable Notifications".to_string(),
                        description: "Disable all notifications".to_string(),
                        rule_type: RuleType::DisableNotifications,
                        enabled: true,
                        priority: 1,
                    },
                    ContextRule {
                        id: "gaming-mode".to_string(),
                        name: "Simple Mode".to_string(),
                        description: "Use simple mode for gaming".to_string(),
                        rule_type: RuleType::SetExperienceMode("simple".to_string()),
                        enabled: true,
                        priority: 2,
                    },
                    ContextRule {
                        id: "gaming-capture".to_string(),
                        name: "Enable Screen Capture".to_string(),
                        description: "Allow screen capture for streaming".to_string(),
                        rule_type: RuleType::ScreenCapture(true),
                        enabled: true,
                        priority: 3,
                    },
                ],
                time_schedule: None,
                trigger_applications: vec![
                    "steam".to_string(),
                    "lutris".to_string(),
                    "heroic".to_string(),
                ],
                trigger_network: None,
                priority: 3,
            },
            ContextProfile {
                context: ContextType::Development,
                name: "Development".to_string(),
                description: "Software development".to_string(),
                detection_method: DetectionMethod::ApplicationBased,
                rules: vec![
                    ContextRule {
                        id: "dev-notifications".to_string(),
                        name: "Work Notifications".to_string(),
                        description: "Only important notifications".to_string(),
                        rule_type: RuleType::DisableNotifications,
                        enabled: true,
                        priority: 1,
                    },
                    ContextRule {
                        id: "dev-mode".to_string(),
                        name: "Builder Mode".to_string(),
                        description: "Use builder experience mode".to_string(),
                        rule_type: RuleType::SetExperienceMode("builder".to_string()),
                        enabled: true,
                        priority: 2,
                    },
                    ContextRule {
                        id: "dev-updates".to_string(),
                        name: "Edge Updates".to_string(),
                        description: "Use edge update channel".to_string(),
                        rule_type: RuleType::SetUpdateChannel("edge".to_string()),
                        enabled: true,
                        priority: 3,
                    },
                ],
                time_schedule: None,
                trigger_applications: vec![
                    "vscode".to_string(),
                    "vim".to_string(),
                    "neovim".to_string(),
                    "code-oss".to_string(),
                ],
                trigger_network: None,
                priority: 2,
            },
        ];

        let mut profiles_map = self.profiles.write().await;
        for profile in profiles {
            profiles_map.insert(profile.context.to_string(), profile);
        }

        info!("Default context profiles created");
    }

    /// Load current state
    async fn load_state(&self) -> Result<()> {
        let state_file = self.config_dir.join("context_state.json");
        if !state_file.exists() {
            return Ok(());
        }

        let state_content = tokio::fs::read_to_string(&state_file).await?;
        let state: ContextState =
            serde_json::from_str(&state_content).context("Failed to parse context state")?;

        let context_name = state.current_context.to_string();
        *self.current_state.write().await = state;

        info!("Context state loaded: {}", context_name);

        Ok(())
    }

    /// Save current state
    pub async fn save_state(&self) -> Result<()> {
        let state = self.current_state.read().await;
        let state_file = self.config_dir.join("context_state.json");
        let state_content = serde_json::to_string_pretty(&*state)?;

        tokio::fs::write(&state_file, state_content)
            .await
            .context("Failed to save context state")?;

        Ok(())
    }

    /// Get current context
    pub async fn get_current_context(&self) -> ContextType {
        self.current_state.read().await.current_context.clone()
    }

    /// Set current context
    pub async fn set_context(&self, context: ContextType) -> Result<()> {
        let profiles = self.profiles.read().await;
        let profile = profiles.get(&context.to_string());

        if let Some(profile) = profile {
            let mut state = self.current_state.write().await;
            state.current_context = context.clone();
            state.active_profile = profile.name.clone();
            state.last_switch = Utc::now();
            state.detection_method = DetectionMethod::Manual;

            info!("Context switched to: {}", context);
            info!("Applying {} rules", profile.rules.len());

            drop(state);

            self.save_state().await?;

            Ok(())
        } else {
            warn!("Profile not found for context: {}", context);
            Ok(())
        }
    }

    /// Get context profile
    pub async fn get_profile(&self, context: &ContextType) -> Option<ContextProfile> {
        self.profiles
            .read()
            .await
            .get(&context.to_string())
            .cloned()
    }

    /// List all profiles
    pub async fn list_profiles(&self) -> Vec<ContextProfile> {
        self.profiles.read().await.values().cloned().collect()
    }

    /// Add or update a profile
    pub async fn save_profile(&self, profile: ContextProfile) -> Result<()> {
        let mut profiles = self.profiles.write().await;
        profiles.insert(profile.context.to_string(), profile.clone());
        drop(profiles);

        self.save_profiles().await?;

        info!("Profile saved: {}", profile.context);

        Ok(())
    }

    /// Delete a profile
    pub async fn delete_profile(&self, context: &ContextType) -> Result<()> {
        let mut profiles = self.profiles.write().await;
        if profiles.remove(&context.to_string()).is_some() {
            drop(profiles);

            self.save_profiles().await?;

            info!("Profile deleted: {}", context);

            Ok(())
        } else {
            warn!("Profile not found: {}", context);
            Ok(())
        }
    }

    /// Detect current context based on various factors
    pub async fn detect_context(&self) -> Option<ContextType> {
        let profiles = self.profiles.read().await;
        let mut best_match: Option<(ContextProfile, u32)> = None;

        for profile in profiles.values() {
            let mut score = 0u32;

            // Check time schedule
            if let Some(ref schedule) = profile.time_schedule {
                let now = Local::now();
                let day_of_week = now.weekday().num_days_from_sunday() as u8;

                if schedule.days.contains(&day_of_week) {
                    let current_minutes = now.hour() * 60 + now.minute();
                    let start_minutes =
                        schedule.start_hour as u32 * 60 + schedule.start_minute as u32;
                    let end_minutes = schedule.end_hour as u32 * 60 + schedule.end_minute as u32;

                    if current_minutes >= start_minutes && current_minutes <= end_minutes {
                        score += 10;
                    }
                }
            }

            // Check network (if available)
            if let Some(ref network) = profile.trigger_network {
                if self.is_current_network(network).await {
                    score += 20;
                }
            }

            // Check running applications (if available)
            if !profile.trigger_applications.is_empty()
                && self.is_app_running(&profile.trigger_applications).await
            {
                score += 30;
            }

            // Add to best match
            if let Some((_, best_score)) = best_match {
                if score > best_score {
                    best_match = Some((profile.clone(), score));
                }
            } else if score > 0 {
                best_match = Some((profile.clone(), score));
            }
        }

        best_match.map(|(profile, _)| profile.context)
    }

    /// Check if current network matches
    async fn is_current_network(&self, _ssid: &str) -> bool {
        // In a real implementation, this would check current network SSID
        // For now, return false
        false
    }

    /// Check if any of the applications are running
    async fn is_app_running(&self, _apps: &[String]) -> bool {
        // In a real implementation, this would check running processes
        // For now, return false
        false
    }

    /// Apply context rules
    pub async fn apply_rules(&self, context: &ContextType) -> Result<Vec<AppliedRule>> {
        let profiles = self.profiles.read().await;
        let profile = match profiles.get(&context.to_string()) {
            Some(p) => p,
            None => return Ok(vec![]),
        };

        let mut applied_rules = Vec::new();

        for rule in &profile.rules {
            if rule.enabled {
                // Apply rule
                match &rule.rule_type {
                    RuleType::SetExperienceMode(mode) => {
                        applied_rules.push(AppliedRule {
                            rule_id: rule.id.clone(),
                            rule_name: rule.name.clone(),
                            action: format!("Set experience mode to {}", mode),
                            status: RuleStatus::Applied,
                        });
                    }
                    RuleType::SetUpdateChannel(channel) => {
                        applied_rules.push(AppliedRule {
                            rule_id: rule.id.clone(),
                            rule_name: rule.name.clone(),
                            action: format!("Set update channel to {}", channel),
                            status: RuleStatus::Applied,
                        });
                    }
                    RuleType::SetAiModel(model) => {
                        applied_rules.push(AppliedRule {
                            rule_id: rule.id.clone(),
                            rule_name: rule.name.clone(),
                            action: format!("Set AI model to {}", model),
                            status: RuleStatus::Applied,
                        });
                    }
                    RuleType::DisableNotifications => {
                        applied_rules.push(AppliedRule {
                            rule_id: rule.id.clone(),
                            rule_name: rule.name.clone(),
                            action: "Disable notifications".to_string(),
                            status: RuleStatus::Applied,
                        });
                    }
                    RuleType::ScreenCapture(enabled) => {
                        applied_rules.push(AppliedRule {
                            rule_id: rule.id.clone(),
                            rule_name: rule.name.clone(),
                            action: format!(
                                "Screen capture: {}",
                                if *enabled { "enabled" } else { "disabled" }
                            ),
                            status: RuleStatus::Applied,
                        });
                    }
                    RuleType::BlockApplication(app) => {
                        applied_rules.push(AppliedRule {
                            rule_id: rule.id.clone(),
                            rule_name: rule.name.clone(),
                            action: format!("Block application: {}", app),
                            status: RuleStatus::Applied,
                        });
                    }
                    RuleType::SetPrivacyLevel(level) => {
                        applied_rules.push(AppliedRule {
                            rule_id: rule.id.clone(),
                            rule_name: rule.name.clone(),
                            action: format!("Set privacy level to {}", level),
                            status: RuleStatus::Applied,
                        });
                    }
                }
            }
        }

        info!(
            "Applied {} rules for context {}",
            applied_rules.len(),
            context
        );

        Ok(applied_rules)
    }

    /// Get context statistics
    pub async fn get_statistics(&self) -> ContextStatistics {
        let state = self.current_state.read().await;
        let profiles = self.profiles.read().await;

        ContextStatistics {
            current_context: state.current_context.clone(),
            active_profile: state.active_profile.clone(),
            last_switch: state.last_switch,
            total_profiles: profiles.len(),
            detection_method: state.detection_method.clone(),
        }
    }
}

/// Applied rule
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppliedRule {
    pub rule_id: String,
    pub rule_name: String,
    pub action: String,
    pub status: RuleStatus,
}

/// Rule status
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum RuleStatus {
    Applied,
    Failed,
    Skipped,
}

/// Context statistics
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContextStatistics {
    pub current_context: ContextType,
    pub active_profile: String,
    pub last_switch: DateTime<Utc>,
    pub total_profiles: usize,
    pub detection_method: DetectionMethod,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    #[test]
    fn test_context_type_display() {
        assert_eq!(ContextType::Home.to_string(), "home");
        assert_eq!(ContextType::Work.to_string(), "work");
        assert_eq!(ContextType::Gaming.to_string(), "gaming");
    }

    #[test]
    fn test_context_type_from_str() {
        assert_eq!(ContextType::from_str("home").unwrap(), ContextType::Home);
        assert_eq!(ContextType::from_str("work").unwrap(), ContextType::Work);
        assert_eq!(
            ContextType::from_str("custom").unwrap(),
            ContextType::Custom("custom".to_string())
        );
    }

    #[test]
    fn test_time_schedule() {
        let schedule = TimeSchedule {
            start_hour: 9,
            start_minute: 0,
            end_hour: 17,
            end_minute: 0,
            days: vec![1, 2, 3, 4, 5],
        };

        assert_eq!(schedule.start_hour, 9);
        assert_eq!(schedule.days.len(), 5);
    }
}
