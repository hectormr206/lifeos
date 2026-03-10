//! FollowAlong - Contextual AI Assistant
//!
//! Monitors user actions and provides contextual assistance:
//! - Keyboard/mouse event monitoring
//! - Action pattern detection
//! - Automatic summarization (with consent)
//! - Translation and explanation
//! - Context-aware suggestions

use anyhow::{Context, Result};
use chrono::{DateTime, Duration, Utc};
use log::{debug, info};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;

/// FollowAlong consent status
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub enum ConsentStatus {
    #[default]
    NotAsked,
    Granted,
    Revoked,
}

/// Event type
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum EventType {
    KeyPress,
    KeyRelease,
    MouseMove,
    MouseClick,
    MouseScroll,
    WindowFocus,
    WindowChange,
    ApplicationLaunch,
    ApplicationClose,
}

/// User event
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserEvent {
    pub id: String,
    pub event_type: EventType,
    pub timestamp: DateTime<Utc>,
    pub application: Option<String>,
    pub window_title: Option<String>,
    pub details: EventDetails,
}

/// Event details
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum EventDetails {
    Keyboard {
        key_code: u32,
        key_name: String,
        modifiers: Vec<String>,
    },
    Mouse {
        x: i32,
        y: i32,
        button: Option<u8>,
        scroll_delta: Option<i32>,
    },
    Window {
        window_id: u64,
        title: String,
        class: String,
    },
    Application {
        executable: String,
        pid: u32,
        command_line: Option<String>,
    },
}

/// Action pattern
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActionPattern {
    pub id: String,
    pub name: String,
    pub description: String,
    pub trigger_events: Vec<EventType>,
    pub confidence: f64,
    pub last_seen: DateTime<Utc>,
}

/// Context state
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContextState {
    pub current_application: Option<String>,
    pub current_window: Option<String>,
    pub active_pattern: Option<String>,
    pub session_duration: Duration,
    pub last_event: Option<DateTime<Utc>>,
}

/// FollowAlong configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FollowAlongConfig {
    pub enabled: bool,
    pub consent_status: ConsentStatus,
    pub auto_summarize: bool,
    pub auto_translate: bool,
    pub auto_explain: bool,
    pub summary_interval_seconds: u64,
    pub max_events_buffer: usize,
    pub detect_patterns: bool,
    pub learning_enabled: bool,
}

impl Default for FollowAlongConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            consent_status: ConsentStatus::NotAsked,
            auto_summarize: false,
            auto_translate: false,
            auto_explain: false,
            summary_interval_seconds: 300, // 5 minutes
            max_events_buffer: 1000,
            detect_patterns: true,
            learning_enabled: false,
        }
    }
}

/// FollowAlong manager
#[derive(Clone)]
pub struct FollowAlongManager {
    config: Arc<RwLock<FollowAlongConfig>>,
    events_buffer: Arc<RwLock<Vec<UserEvent>>>,
    action_patterns: Arc<RwLock<HashMap<String, ActionPattern>>>,
    context_state: Arc<RwLock<ContextState>>,
    config_dir: PathBuf,
    session_start: DateTime<Utc>,
}

impl FollowAlongManager {
    /// Create new FollowAlong manager
    pub fn new(config_dir: PathBuf) -> Result<Self> {
        let manager = Self {
            config: Arc::new(RwLock::new(FollowAlongConfig::default())),
            events_buffer: Arc::new(RwLock::new(Vec::new())),
            action_patterns: Arc::new(RwLock::new(HashMap::new())),
            context_state: Arc::new(RwLock::new(ContextState {
                current_application: None,
                current_window: None,
                active_pattern: None,
                session_duration: Duration::zero(),
                last_event: None,
            })),
            config_dir,
            session_start: Utc::now(),
        };

        info!("FollowAlong manager initialized");

        Ok(manager)
    }

    /// Initialize manager state from disk.
    pub async fn initialize(&self) -> Result<()> {
        self.load_config().await?;
        self.load_patterns().await?;
        Ok(())
    }

    /// Load configuration
    async fn load_config(&self) -> Result<()> {
        let config_file = self.config_dir.join("follow_along.conf");
        if !config_file.exists() {
            return Ok(());
        }

        let config_content = tokio::fs::read_to_string(&config_file).await?;
        let config: FollowAlongConfig =
            serde_json::from_str(&config_content).context("Failed to parse FollowAlong config")?;

        *self.config.write().await = config;

        info!("FollowAlong configuration loaded");

        Ok(())
    }

    /// Save configuration
    pub async fn save_config(&self) -> Result<()> {
        let config = self.config.read().await;
        let config_file = self.config_dir.join("follow_along.conf");
        let config_content = serde_json::to_string_pretty(&*config)?;

        tokio::fs::write(&config_file, config_content)
            .await
            .context("Failed to save FollowAlong config")?;

        info!("FollowAlong configuration saved");

        Ok(())
    }

    /// Load action patterns
    async fn load_patterns(&self) -> Result<()> {
        let patterns_file = self.config_dir.join("action_patterns.json");
        if !patterns_file.exists() {
            // Create default patterns
            self.create_default_patterns().await;
            return Ok(());
        }

        let patterns_content = tokio::fs::read_to_string(&patterns_file).await?;
        let patterns: HashMap<String, ActionPattern> =
            serde_json::from_str(&patterns_content).context("Failed to parse action patterns")?;

        let pattern_count = patterns.len();
        *self.action_patterns.write().await = patterns;

        info!("Action patterns loaded: {} patterns", pattern_count);

        Ok(())
    }

    /// Create default action patterns
    async fn create_default_patterns(&self) {
        let patterns = vec![
            ActionPattern {
                id: "typing_document".to_string(),
                name: "Typing Document".to_string(),
                description: "User is typing in a text editor or word processor".to_string(),
                trigger_events: vec![EventType::KeyPress],
                confidence: 0.8,
                last_seen: Utc::now(),
            },
            ActionPattern {
                id: "navigating_filesystem".to_string(),
                name: "Navigating Filesystem".to_string(),
                description: "User is browsing files and folders".to_string(),
                trigger_events: vec![EventType::MouseClick, EventType::MouseMove],
                confidence: 0.7,
                last_seen: Utc::now(),
            },
            ActionPattern {
                id: "coding_session".to_string(),
                name: "Coding Session".to_string(),
                description: "User is writing code in an IDE or editor".to_string(),
                trigger_events: vec![EventType::KeyPress, EventType::MouseClick],
                confidence: 0.85,
                last_seen: Utc::now(),
            },
            ActionPattern {
                id: "web_browsing".to_string(),
                name: "Web Browsing".to_string(),
                description: "User is browsing the web".to_string(),
                trigger_events: vec![EventType::MouseMove, EventType::MouseScroll],
                confidence: 0.75,
                last_seen: Utc::now(),
            },
        ];

        let mut patterns_map = self.action_patterns.write().await;
        for pattern in patterns {
            patterns_map.insert(pattern.id.clone(), pattern);
        }
    }

    /// Record user event
    pub async fn record_event(&self, event: UserEvent) -> Result<()> {
        let config = self.config.read().await;
        if !config.enabled || config.consent_status != ConsentStatus::Granted {
            debug!("FollowAlong not enabled or consent not granted");
            return Ok(());
        }

        // Update context state
        self.update_context(&event).await;

        // Add to buffer
        let mut buffer = self.events_buffer.write().await;
        buffer.push(event.clone());

        // Trim buffer if needed
        if buffer.len() > config.max_events_buffer {
            let trim_count = buffer.len() - config.max_events_buffer;
            buffer.drain(0..trim_count);
        }

        // Detect patterns
        if config.detect_patterns {
            self.detect_patterns(&event).await;
        }

        drop(buffer);

        // Auto-summarize if configured
        if config.auto_summarize {
            self.check_summary_interval().await?;
        }

        Ok(())
    }

    /// Update context state
    async fn update_context(&self, event: &UserEvent) {
        let mut context = self.context_state.write().await;

        match &event.details {
            EventDetails::Application { executable, .. } => {
                context.current_application = Some(executable.clone());
            }
            EventDetails::Window { title, .. } => {
                context.current_window = Some(title.clone());
            }
            _ => {}
        }

        context.last_event = Some(event.timestamp);
        context.session_duration = event.timestamp - self.session_start;
    }

    /// Detect action patterns
    async fn detect_patterns(&self, event: &UserEvent) {
        let matched = {
            let patterns = self.action_patterns.read().await;
            patterns
                .values()
                .find(|p| p.trigger_events.contains(&event.event_type))
                .map(|p| (p.id.clone(), p.name.clone()))
        };

        if let Some((pattern_id, pattern_name)) = matched {
            debug!("Detected pattern: {}", pattern_name);

            let mut patterns_mut = self.action_patterns.write().await;
            if let Some(p) = patterns_mut.get_mut(&pattern_id) {
                p.last_seen = event.timestamp;
            }
            drop(patterns_mut);

            let mut context = self.context_state.write().await;
            context.active_pattern = Some(pattern_id);
        }
    }

    /// Check if summary interval has elapsed
    async fn check_summary_interval(&self) -> Result<()> {
        let context = self.context_state.read().await;
        let config = self.config.read().await;

        if let Some(last_event) = context.last_event {
            let elapsed = Utc::now() - last_event;
            let interval = Duration::seconds(config.summary_interval_seconds as i64);

            if elapsed > interval {
                drop(context);
                drop(config);
                let _ = self.generate_summary().await?;
                return Ok(());
            }
        }

        Ok(())
    }

    /// Generate summary of recent activity
    pub async fn generate_summary(&self) -> Result<String> {
        let buffer = self.events_buffer.read().await;
        let context = self.context_state.read().await;

        if buffer.is_empty() {
            return Ok("No activity to summarize".to_string());
        }

        // Count events by type
        let mut event_counts: HashMap<String, usize> = HashMap::new();
        for event in buffer.iter() {
            let type_name = format!("{:?}", event.event_type);
            *event_counts.entry(type_name).or_insert(0) += 1;
        }

        // Build summary
        let mut summary = String::new();
        summary.push_str("Activity Summary:\n\n");

        if let Some(app) = &context.current_application {
            summary.push_str(&format!("Current Application: {}\n", app));
        }

        if let Some(window) = &context.current_window {
            summary.push_str(&format!("Current Window: {}\n", window));
        }

        if let Some(pattern) = &context.active_pattern {
            summary.push_str(&format!("Active Pattern: {}\n", pattern));
        }

        summary.push_str(&format!(
            "Session Duration: {} minutes\n",
            context.session_duration.num_minutes()
        ));

        summary.push_str("\nEvent Statistics:\n");
        for (event_type, count) in event_counts.iter() {
            summary.push_str(&format!("  - {}: {}\n", event_type, count));
        }

        // Clear buffer after summary
        drop(buffer);
        drop(context);
        self.events_buffer.write().await.clear();

        info!("Activity summary generated");

        Ok(summary)
    }

    /// Translate recent activity summary
    pub async fn translate_summary(&self, target_language: &str) -> Result<String> {
        let summary = self.generate_summary().await?;

        // In a real implementation, this would call the AI manager
        // For now, return a placeholder
        let translated = format!("[Translated to {}]\n\n{}", target_language, summary);

        info!("Summary translated to {}", target_language);

        Ok(translated)
    }

    /// Explain recent activity
    pub async fn explain_activity(&self, question: &str) -> Result<String> {
        let context = self.context_state.read().await;
        let buffer = self.events_buffer.read().await;

        if buffer.is_empty() {
            return Ok("No recent activity to explain".to_string());
        }

        // Build explanation
        let mut explanation = String::new();
        explanation.push_str(&format!("Question: {}\n\n", question));

        if let Some(app) = &context.current_application {
            explanation.push_str(&format!("You are currently working in: {}\n", app));
        }

        if let Some(pattern) = &context.active_pattern {
            explanation.push_str(&format!(
                "Your recent activity suggests you are: {}\n",
                pattern
            ));
        }

        // In a real implementation, this would call the AI manager
        explanation.push_str("\nBased on your recent actions, I can help you with:\n");
        explanation.push_str("- Summarizing your work\n");
        explanation.push_str("- Translating content\n");
        explanation.push_str("- Providing context-aware suggestions\n");

        info!("Activity explanation generated");

        Ok(explanation)
    }

    /// Get current context state
    pub async fn get_context(&self) -> ContextState {
        self.context_state.read().await.clone()
    }

    /// Set consent status
    pub async fn set_consent(&self, granted: bool) -> Result<()> {
        let mut config = self.config.write().await;
        config.consent_status = if granted {
            ConsentStatus::Granted
        } else {
            ConsentStatus::Revoked
        };

        if granted {
            info!("FollowAlong consent granted by user");
        } else {
            info!("FollowAlong consent revoked by user");
        }
        drop(config);

        self.save_config().await?;

        Ok(())
    }

    /// Enable or disable FollowAlong
    pub async fn set_enabled(&self, enabled: bool) -> Result<()> {
        let mut config = self.config.write().await;
        config.enabled = enabled;

        if enabled {
            info!("FollowAlong enabled");
        } else {
            info!("FollowAlong disabled");
        }
        drop(config);

        self.save_config().await?;

        Ok(())
    }

    /// Get configuration
    pub async fn get_config(&self) -> FollowAlongConfig {
        self.config.read().await.clone()
    }

    /// Update configuration
    pub async fn update_config(&self, updates: FollowAlongConfig) -> Result<()> {
        *self.config.write().await = updates;
        self.save_config().await?;
        Ok(())
    }

    /// Clear event buffer
    pub async fn clear_events(&self) -> Result<()> {
        self.events_buffer.write().await.clear();
        info!("Event buffer cleared");
        Ok(())
    }

    /// Get event statistics
    pub async fn get_event_stats(&self) -> EventStatistics {
        let buffer = self.events_buffer.read().await;
        let context = self.context_state.read().await;

        let mut event_counts: HashMap<String, usize> = HashMap::new();
        for event in buffer.iter() {
            let type_name = format!("{:?}", event.event_type);
            *event_counts.entry(type_name).or_insert(0) += 1;
        }

        EventStatistics {
            total_events: buffer.len(),
            event_counts,
            current_application: context.current_application.clone(),
            current_window: context.current_window.clone(),
            session_duration: context.session_duration,
            session_start: self.session_start,
        }
    }

    /// Export events
    pub async fn export_events(&self, path: PathBuf) -> Result<()> {
        let buffer = self.events_buffer.read().await;
        let json = serde_json::to_string_pretty(&*buffer)?;

        tokio::fs::write(&path, json)
            .await
            .context("Failed to export events")?;

        info!("Events exported to {}", path.display());

        Ok(())
    }
}

/// Event statistics
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventStatistics {
    pub total_events: usize,
    pub event_counts: HashMap<String, usize>,
    pub current_application: Option<String>,
    pub current_window: Option<String>,
    pub session_duration: Duration,
    pub session_start: DateTime<Utc>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let config = FollowAlongConfig::default();
        assert_eq!(config.enabled, false);
        assert_eq!(config.consent_status, ConsentStatus::NotAsked);
        assert_eq!(config.summary_interval_seconds, 300);
    }

    #[test]
    fn test_event_creation() {
        let event = UserEvent {
            id: uuid::Uuid::new_v4().to_string(),
            event_type: EventType::KeyPress,
            timestamp: Utc::now(),
            application: Some("test_app".to_string()),
            window_title: Some("Test Window".to_string()),
            details: EventDetails::Keyboard {
                key_code: 65,
                key_name: "A".to_string(),
                modifiers: vec![],
            },
        };

        assert_eq!(event.event_type, EventType::KeyPress);
        assert_eq!(event.application, Some("test_app".to_string()));
    }
}
