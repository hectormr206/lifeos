//! AI Overlay module for LifeOS
//!
//! Provides a floating overlay window that appears on Super+Space:
//! - Displays AI chat interface
//! - Shows current screen context
//! - Allows quick AI assistance without leaving workflow
//! - Integrates with multimodal AI capabilities
//!
//! Targets COSMIC desktop (Wayland-based) with GTK4.

use crate::ai::{AiChatResponse, AiManager};
use anyhow::{Context, Result};
use log::{info, warn};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;
use utoipa::ToSchema;

/// Overlay window configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OverlayConfig {
    /// Whether overlay is enabled
    pub enabled: bool,
    /// Keyboard shortcut (e.g., "Super+space")
    pub shortcut: String,
    /// Default window position
    pub default_position: WindowPosition,
    /// Window opacity (0.0-1.0)
    pub opacity: f32,
    /// Theme variant
    pub theme: OverlayTheme,
    /// Whether to show screen preview in overlay
    pub show_preview: bool,
}

impl Default for OverlayConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            shortcut: "Super+space".to_string(),
            default_position: WindowPosition::Center,
            opacity: 0.95,
            theme: OverlayTheme::Dark,
            show_preview: true,
        }
    }
}

/// Window position
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub enum WindowPosition {
    #[default]
    Center,
    TopRight,
    TopLeft,
    BottomRight,
    BottomLeft,
    Custom {
        x: i32,
        y: i32,
    },
}

/// Overlay theme
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub enum OverlayTheme {
    #[default]
    Dark,
    Light,
    Auto,
}

/// Animated Axi state shown by the overlay and mini-widget.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum AxiState {
    #[default]
    Idle,
    Listening,
    Thinking,
    Speaking,
    Watching,
    Error,
    Offline,
    Night,
}

impl AxiState {
    fn aura(&self) -> &'static str {
        match self {
            Self::Idle => "green",
            Self::Listening => "cyan",
            Self::Thinking => "yellow",
            Self::Speaking => "blue",
            Self::Watching => "teal",
            Self::Error => "red",
            Self::Offline => "gray",
            Self::Night => "indigo",
        }
    }
}

/// Persistent sensor indicators for privacy-by-design UX.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SensorIndicators {
    pub mic_active: bool,
    pub camera_active: bool,
    pub screen_active: bool,
    pub kill_switch_active: bool,
}

/// Live pipeline feedback used by the overlay and compact widget.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct OverlayFeedback {
    pub stage: Option<String>,
    pub tokens_per_second: Option<f32>,
    pub eta_ms: Option<u64>,
    pub audio_level: Option<f32>,
    pub updated_at: Option<String>,
}

/// Compact persistent widget state for desktop chrome integrations.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MiniWidgetState {
    pub visible: bool,
    pub aura: String,
    pub badge: Option<String>,
}

impl Default for MiniWidgetState {
    fn default() -> Self {
        Self {
            visible: true,
            aura: "green".to_string(),
            badge: None,
        }
    }
}

/// Lightweight proactive notification emitted by the overlay.
#[derive(Debug, Clone, Serialize, Deserialize, ToSchema)]
pub struct ProactiveNotification {
    pub priority: String,
    pub message: String,
    pub created_at: String,
}

/// Overlay state
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OverlayState {
    pub visible: bool,
    pub focused: bool,
    pub chat_history: Vec<ChatMessage>,
    pub last_message_timestamp: String,
    pub window_position: Option<(i32, i32)>,
    pub axi_state: AxiState,
    pub sensor_indicators: SensorIndicators,
    pub feedback: OverlayFeedback,
    pub mini_widget: MiniWidgetState,
    pub proactive_notifications: Vec<ProactiveNotification>,
    pub last_error: Option<String>,
}

impl Default for OverlayState {
    fn default() -> Self {
        Self {
            visible: false,
            focused: false,
            chat_history: Vec::new(),
            last_message_timestamp: chrono::Utc::now().to_rfc3339(),
            window_position: None,
            axi_state: AxiState::Idle,
            sensor_indicators: SensorIndicators::default(),
            feedback: OverlayFeedback::default(),
            mini_widget: MiniWidgetState::default(),
            proactive_notifications: Vec::new(),
            last_error: None,
        }
    }
}

/// Chat message
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub id: String,
    pub role: ChatRole,
    pub content: String,
    pub timestamp: String,
    pub has_screen_context: bool,
}

/// Chat role
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum ChatRole {
    User,
    Assistant,
    System,
}

/// AI Overlay manager
#[derive(Clone)]
pub struct OverlayManager {
    config: Arc<RwLock<OverlayConfig>>,
    state: Arc<RwLock<OverlayState>>,
    screenshot_dir: PathBuf,
}

impl OverlayManager {
    /// Create new overlay manager
    pub fn new(screenshot_dir: PathBuf) -> Self {
        Self {
            config: Arc::new(RwLock::new(OverlayConfig::default())),
            state: Arc::new(RwLock::new(OverlayState::default())),
            screenshot_dir,
        }
    }

    /// Create with custom config
    pub fn with_config(screenshot_dir: PathBuf, config: OverlayConfig) -> Self {
        Self {
            config: Arc::new(RwLock::new(config)),
            state: Arc::new(RwLock::new(OverlayState::default())),
            screenshot_dir,
        }
    }

    /// Check if overlay is currently visible
    pub async fn is_visible(&self) -> bool {
        let state = self.state.read().await;
        state.visible
    }

    /// Show overlay window
    pub async fn show(&self) -> Result<()> {
        let config = self.config.read().await;
        if !config.enabled {
            info!("Overlay disabled in config");
            return Ok(());
        }
        let shortcut = config.shortcut.clone();
        drop(config);

        let mut state = self.state.write().await;

        if state.visible {
            info!("Overlay already visible");
            return Ok(());
        }

        info!("Showing AI overlay window");

        // In production, this would launch a GTK4 overlay window
        // For now, we'll use a placeholder implementation
        state.visible = true;
        state.last_message_timestamp = chrono::Utc::now().to_rfc3339();

        info!("Overlay window shown with shortcut: {}", shortcut);
        Ok(())
    }

    /// Hide overlay window
    pub async fn hide(&self) -> Result<()> {
        let mut state = self.state.write().await;

        if !state.visible {
            return Ok(());
        }

        info!("Hiding AI overlay window");

        // In production, this would close the GTK4 overlay window
        state.visible = false;

        info!("Overlay window hidden");
        Ok(())
    }

    /// Toggle overlay visibility
    pub async fn toggle(&self) -> Result<()> {
        if self.is_visible().await {
            self.hide().await
        } else {
            self.show().await
        }
    }

    /// Send message to AI chat
    pub async fn send_message(
        &self,
        message: String,
        include_screen: bool,
    ) -> Result<AiChatResponse> {
        let chat_msg = ChatMessage {
            id: uuid::Uuid::new_v4().to_string(),
            role: ChatRole::User,
            content: message.clone(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            has_screen_context: include_screen,
        };

        {
            let mut state = self.state.write().await;
            state.chat_history.push(chat_msg.clone());
            state.last_message_timestamp = chat_msg.timestamp;
        }

        let history = self.get_chat_history().await;
        let response = self.generate_ai_response(&history, include_screen).await?;

        let assistant_msg = ChatMessage {
            id: uuid::Uuid::new_v4().to_string(),
            role: ChatRole::Assistant,
            content: response.response.clone(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            has_screen_context: include_screen,
        };

        let mut state = self.state.write().await;
        state.chat_history.push(assistant_msg);
        state.last_message_timestamp = chrono::Utc::now().to_rfc3339();
        state.last_error = None;

        Ok(response)
    }

    async fn generate_ai_response(
        &self,
        history: &[ChatMessage],
        include_screen: bool,
    ) -> Result<AiChatResponse> {
        const SYSTEM_PROMPT: &str = "You are Axi, the local LifeOS assistant. Be concise, practical, and prioritize the user's current desktop context.";

        let ai_manager = AiManager::new();
        let latest_user_message = history
            .iter()
            .rev()
            .find(|msg| msg.role == ChatRole::User)
            .map(|msg| msg.content.trim().to_string())
            .filter(|msg| !msg.is_empty())
            .ok_or_else(|| anyhow::anyhow!("No user message available for overlay chat"))?;

        if include_screen {
            let screenshot = self.include_screen_context().await?;
            let prompt = format!(
                "Recent overlay conversation:\n{}\n\nLatest request:\n{}",
                summarize_overlay_history(history),
                latest_user_message
            );
            let screenshot_path = screenshot.to_string_lossy().to_string();
            return ai_manager
                .chat_multimodal(None, Some(SYSTEM_PROMPT), &prompt, &screenshot_path)
                .await;
        }

        let mut messages = vec![("system".to_string(), SYSTEM_PROMPT.to_string())];
        messages.extend(history.iter().rev().take(12).rev().filter_map(|message| {
            let role = match message.role {
                ChatRole::User => "user",
                ChatRole::Assistant => "assistant",
                ChatRole::System => "system",
            };
            let content = message.content.trim();
            (!content.is_empty()).then(|| (role.to_string(), content.to_string()))
        }));

        ai_manager.chat(None, messages).await
    }

    /// Clear chat history
    pub async fn clear_chat(&self) -> Result<()> {
        let mut state = self.state.write().await;
        state.chat_history.clear();
        state.last_message_timestamp = chrono::Utc::now().to_rfc3339();
        info!("Chat history cleared");
        Ok(())
    }

    /// Get chat history
    pub async fn get_chat_history(&self) -> Vec<ChatMessage> {
        let state = self.state.read().await;
        state.chat_history.clone()
    }

    /// Capture and include current screen in next message
    pub async fn include_screen_context(&self) -> Result<PathBuf> {
        use super::screen_capture::ScreenCapture;

        let capture = ScreenCapture::new(self.screenshot_dir.clone());

        let screenshot = capture.capture().await?;
        info!("Screen captured for context: {}", screenshot.filename);

        Ok(screenshot.path)
    }

    /// Update overlay configuration
    pub async fn update_config(&self, config: OverlayConfig) -> Result<()> {
        let mut current = self.config.write().await;
        let enabled = config.enabled;
        let shortcut = config.shortcut.clone();
        *current = config;
        info!(
            "Overlay configuration updated: enabled={}, shortcut={}",
            enabled, shortcut
        );
        Ok(())
    }

    /// Get current configuration
    pub async fn get_config(&self) -> OverlayConfig {
        self.config.read().await.clone()
    }

    /// Get current state
    pub async fn get_state(&self) -> OverlayState {
        let state = self.state.read().await;
        state.clone()
    }

    /// Set the current Axi visual state and keep the mini-widget in sync.
    pub async fn set_axi_state(&self, axi_state: AxiState, reason: Option<&str>) -> Result<()> {
        let mut state = self.state.write().await;
        state.axi_state = axi_state.clone();
        state.mini_widget.aura = axi_state.aura().to_string();
        state.mini_widget.badge = reason
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty());
        if axi_state != AxiState::Error {
            state.last_error = None;
        }
        Ok(())
    }

    /// Update persistent privacy LEDs and kill-switch badge.
    pub async fn set_sensor_indicators(
        &self,
        mic_active: bool,
        camera_active: bool,
        screen_active: bool,
        kill_switch_active: bool,
    ) -> Result<()> {
        let mut state = self.state.write().await;
        state.sensor_indicators = SensorIndicators {
            mic_active,
            camera_active,
            screen_active,
            kill_switch_active,
        };
        if kill_switch_active {
            state.mini_widget.aura = AxiState::Offline.aura().to_string();
            state.mini_widget.badge = Some("kill-switch".to_string());
        }
        Ok(())
    }

    /// Publish live pipeline progress to the overlay.
    pub async fn set_processing_feedback(
        &self,
        stage: Option<&str>,
        tokens_per_second: Option<f32>,
        eta_ms: Option<u64>,
        audio_level: Option<f32>,
    ) -> Result<()> {
        let mut state = self.state.write().await;
        state.feedback = OverlayFeedback {
            stage: stage
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty()),
            tokens_per_second,
            eta_ms,
            audio_level,
            updated_at: Some(chrono::Utc::now().to_rfc3339()),
        };
        Ok(())
    }

    pub async fn clear_processing_feedback(&self) -> Result<()> {
        let mut state = self.state.write().await;
        state.feedback = OverlayFeedback::default();
        Ok(())
    }

    /// Push a non-blocking proactive notification into overlay state.
    pub async fn push_proactive_notification(&self, priority: &str, message: &str) -> Result<()> {
        let message = message.trim();
        if message.is_empty() {
            return Ok(());
        }

        let mut state = self.state.write().await;
        let normalized_priority = priority.trim().to_lowercase();
        let recent_duplicate = state
            .proactive_notifications
            .iter()
            .rev()
            .find(|notification| {
                notification.priority == normalized_priority && notification.message == message
            });
        if let Some(notification) = recent_duplicate {
            if chrono::DateTime::parse_from_rfc3339(&notification.created_at)
                .ok()
                .map(|created_at| {
                    (chrono::Utc::now() - created_at.with_timezone(&chrono::Utc)).num_minutes() < 5
                })
                .unwrap_or(false)
            {
                return Ok(());
            }
        }

        state.proactive_notifications.push(ProactiveNotification {
            priority: normalized_priority,
            message: message.to_string(),
            created_at: chrono::Utc::now().to_rfc3339(),
        });
        if state.proactive_notifications.len() > 20 {
            let remove = state.proactive_notifications.len() - 20;
            state.proactive_notifications.drain(0..remove);
        }
        Ok(())
    }

    pub async fn set_error(&self, message: Option<&str>) -> Result<()> {
        let mut state = self.state.write().await;
        state.last_error = message
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty());
        if state.last_error.is_some() {
            state.axi_state = AxiState::Error;
            state.mini_widget.aura = AxiState::Error.aura().to_string();
        }
        Ok(())
    }

    /// Move overlay window
    pub async fn move_window(&self, x: i32, y: i32) -> Result<()> {
        let mut state = self.state.write().await;
        state.window_position = Some((x, y));
        info!("Overlay window moved to: {}, {}", x, y);
        Ok(())
    }

    /// Set overlay theme
    pub async fn set_theme(&self, theme: OverlayTheme) -> Result<()> {
        let mut config = self.config.write().await;
        config.theme = theme.clone();
        info!("Overlay theme set to: {:?}", theme);
        Ok(())
    }

    /// Get overlay statistics
    pub async fn get_stats(&self) -> OverlayStats {
        let state = self.state.read().await;
        let config = self.config.read().await;

        OverlayStats {
            total_messages: state.chat_history.len(),
            visible: state.visible,
            focused: state.focused,
            theme: config.theme.clone(),
            shortcut: config.shortcut.clone(),
            enabled: config.enabled,
            axi_state: state.axi_state.clone(),
            widget_aura: state.mini_widget.aura.clone(),
            active_notifications: state.proactive_notifications.len(),
        }
    }

    /// Export chat history to file
    pub async fn export_chat(&self, path: PathBuf) -> Result<()> {
        let state = self.state.read().await;

        let json = serde_json::to_string_pretty(&state.chat_history)
            .context("Failed to serialize chat history")?;

        tokio::fs::write(&path, json)
            .await
            .context("Failed to write chat history")?;

        info!("Chat history exported to: {}", path.display());
        Ok(())
    }

    /// Import chat history from file
    pub async fn import_chat(&self, path: PathBuf) -> Result<()> {
        if !path.exists() {
            anyhow::bail!("File does not exist: {}", path.display());
        }

        let content = tokio::fs::read_to_string(&path)
            .await
            .context("Failed to read chat history")?;

        let history: Vec<ChatMessage> =
            serde_json::from_str(&content).context("Failed to parse chat history")?;

        let mut state = self.state.write().await;
        state.chat_history = history;

        info!("Chat history imported from: {}", path.display());
        Ok(())
    }

    /// Prune chat history (keep last N messages)
    pub async fn prune_history(&self, keep_last: usize) -> Result<()> {
        let mut state = self.state.write().await;

        if state.chat_history.len() > keep_last {
            let removed = state.chat_history.len() - keep_last;
            state.chat_history.drain(0..removed);
            info!("Pruned {} old messages from history", removed);
        }

        Ok(())
    }

    /// Set overlay position
    pub async fn set_position(&self, position: WindowPosition) -> Result<()> {
        let mut config = self.config.write().await;
        config.default_position = position.clone();
        drop(config);
        match position {
            WindowPosition::Custom { x, y } => {
                let mut state = self.state.write().await;
                state.window_position = Some((x, y));
            }
            _ => {
                let mut state = self.state.write().await;
                state.window_position = None;
            }
        }
        info!("Overlay position set to: {:?}", position);
        Ok(())
    }
}

fn summarize_overlay_history(history: &[ChatMessage]) -> String {
    let mut summary = history
        .iter()
        .rev()
        .take(8)
        .rev()
        .map(|message| {
            let role = match message.role {
                ChatRole::User => "user",
                ChatRole::Assistant => "assistant",
                ChatRole::System => "system",
            };
            format!("{}: {}", role, message.content.trim())
        })
        .collect::<Vec<_>>();

    if summary.is_empty() {
        warn!("Overlay multimodal chat invoked without prior history");
        summary.push("system: no prior overlay history".to_string());
    }

    summary.join("\n")
}

/// Overlay statistics
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OverlayStats {
    pub total_messages: usize,
    pub visible: bool,
    pub focused: bool,
    pub theme: OverlayTheme,
    pub shortcut: String,
    pub enabled: bool,
    pub axi_state: AxiState,
    pub widget_aura: String,
    pub active_notifications: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_overlay_config_default() {
        let config = OverlayConfig::default();
        assert!(config.enabled);
        assert_eq!(config.shortcut, "Super+space");
        assert!(matches!(config.theme, OverlayTheme::Dark));
    }

    #[test]
    fn test_chat_message_serialization() {
        let msg = ChatMessage {
            id: "test-id".to_string(),
            role: ChatRole::User,
            content: "test message".to_string(),
            timestamp: "2024-01-01T00:00:00Z".to_string(),
            has_screen_context: false,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("test message"));
    }

    #[tokio::test]
    async fn overlay_tracks_axi_state_and_leds() {
        let overlay = OverlayManager::new(PathBuf::from("/tmp"));
        overlay
            .set_axi_state(AxiState::Listening, Some("voice-loop"))
            .await
            .unwrap();
        overlay
            .set_sensor_indicators(true, false, true, false)
            .await
            .unwrap();
        overlay
            .set_processing_feedback(Some("thinking"), Some(21.5), Some(400), Some(0.4))
            .await
            .unwrap();
        overlay
            .push_proactive_notification("low", "break reminder")
            .await
            .unwrap();

        let state = overlay.get_state().await;
        assert_eq!(state.axi_state, AxiState::Listening);
        assert_eq!(state.mini_widget.aura, "cyan");
        assert!(state.sensor_indicators.mic_active);
        assert!(state.sensor_indicators.screen_active);
        assert_eq!(state.feedback.stage.as_deref(), Some("thinking"));
        assert_eq!(state.proactive_notifications.len(), 1);
    }
}
