//! AI Overlay module for LifeOS
//!
//! Provides a floating overlay window that appears on Super+Space:
//! - Displays AI chat interface
//! - Shows current screen context
//! - Allows quick AI assistance without leaving workflow
//! - Integrates with multimodal AI capabilities
//!
//! Targets COSMIC desktop (Wayland-based) with GTK4.

use anyhow::{Context, Result};
use log::info;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;

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

/// Overlay state
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OverlayState {
    pub visible: bool,
    pub focused: bool,
    pub chat_history: Vec<ChatMessage>,
    pub last_message_timestamp: String,
    pub window_position: Option<(i32, i32)>,
}

impl Default for OverlayState {
    fn default() -> Self {
        Self {
            visible: false,
            focused: false,
            chat_history: Vec::new(),
            last_message_timestamp: chrono::Utc::now().to_rfc3339(),
            window_position: None,
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
    pub async fn send_message(&self, message: String, include_screen: bool) -> Result<String> {
        let chat_msg = ChatMessage {
            id: uuid::Uuid::new_v4().to_string(),
            role: ChatRole::User,
            content: message.clone(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            has_screen_context: include_screen,
        };

        let mut state = self.state.write().await;
        state.chat_history.push(chat_msg.clone());
        state.last_message_timestamp = chat_msg.timestamp;

        // Generate AI response
        let response = self.generate_ai_response(&message, include_screen).await?;

        let assistant_msg = ChatMessage {
            id: uuid::Uuid::new_v4().to_string(),
            role: ChatRole::Assistant,
            content: response,
            timestamp: chrono::Utc::now().to_rfc3339(),
            has_screen_context: include_screen,
        };

        state.chat_history.push(assistant_msg.clone());

        Ok(assistant_msg.content)
    }

    /// Generate AI response (placeholder - will call actual llama-server)
    async fn generate_ai_response(&self, message: &str, include_screen: bool) -> Result<String> {
        // In production, this would call llama-server API
        // For now, return a placeholder response
        let screen_context = if include_screen {
            " (with screen context)"
        } else {
            ""
        };

        Ok(format!(
            "I understand you're asking: {}{}",
            message, screen_context
        ))
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

/// Overlay statistics
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OverlayStats {
    pub total_messages: usize,
    pub visible: bool,
    pub focused: bool,
    pub theme: OverlayTheme,
    pub shortcut: String,
    pub enabled: bool,
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
}
