//! Global Keyboard Shortcut Handler
//!
//! Handles global keyboard shortcuts (e.g., Super+Space) for LifeOS overlay.
//! Uses xdg-desktop-portal for Wayland compatibility.

use anyhow::{Context, Result};
use log::{error, info, warn};
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};

/// Global keyboard shortcut manager
pub struct ShortcutManager {
    /// Shortcuts that can be registered
    shortcuts: Vec<Shortcut>,
    /// Whether shortcuts are active
    active: AtomicBool,
    /// API endpoint for triggering overlay
    overlay_api_url: String,
}

/// Keyboard shortcut definition
#[derive(Debug, Clone)]
pub struct Shortcut {
    /// Shortcut name
    pub name: String,
    /// Key combination (e.g., "Super+space")
    pub keys: String,
    /// Action to execute when shortcut is pressed
    pub action: ShortcutAction,
    /// Description
    pub description: String,
}

/// Actions triggered by shortcuts
#[derive(Debug, Clone)]
pub enum ShortcutAction {
    /// Toggle overlay visibility
    ToggleOverlay,
    /// Hide overlay
    HideOverlay,
    /// Show overlay
    ShowOverlay,
    /// Capture screen
    CaptureScreen,
    /// Execute custom command
    Execute(String),
}

impl ShortcutManager {
    /// Create new shortcut manager
    pub fn new(overlay_api_url: String) -> Self {
        Self {
            shortcuts: vec![
                Shortcut {
                    name: "toggle-overlay".to_string(),
                    keys: "Super+space".to_string(),
                    action: ShortcutAction::ToggleOverlay,
                    description: "Toggle LifeOS AI overlay".to_string(),
                },
                Shortcut {
                    name: "hide-overlay".to_string(),
                    keys: "Escape".to_string(),
                    action: ShortcutAction::HideOverlay,
                    description: "Hide LifeOS AI overlay".to_string(),
                },
                Shortcut {
                    name: "show-overlay".to_string(),
                    keys: "Super+Shift+A".to_string(),
                    action: ShortcutAction::ShowOverlay,
                    description: "Show LifeOS AI overlay".to_string(),
                },
                Shortcut {
                    name: "capture-screen".to_string(),
                    keys: "Super+Shift+S".to_string(),
                    action: ShortcutAction::CaptureScreen,
                    description: "Capture screen for AI".to_string(),
                },
            ],
            active: AtomicBool::new(false),
            overlay_api_url,
        }
    }

    /// Register all global shortcuts using xdg-desktop-portal
    pub async fn register_shortcuts(&self) -> Result<()> {
        info!("Registering global shortcuts with xdg-desktop-portal");

        // Check if xdg-desktop-portal is available
        if !Command::new("which")
            .arg("xdg-desktop-portal")
            .output()?
            .status
            .success()
        {
            return Err(anyhow::anyhow!(
                "xdg-desktop-portal not found. Install with: sudo dnf install xdg-desktop-portal"
            ));
        }

        // For each shortcut, create a desktop entry
        for shortcut in &self.shortcuts {
            self.create_shortcut_entry(shortcut).await?;
        }

        info!("Global shortcuts registered successfully");
        self.active.store(true, Ordering::Relaxed);

        Ok(())
    }

    /// Create a desktop entry for a shortcut
    async fn create_shortcut_entry(&self, shortcut: &Shortcut) -> Result<()> {
        let desktop_file = format!(
            r#"[Desktop Entry]
Name={}
Comment={}
Type=Application
Exec={} toggle-overlay
Terminal=false
NoDisplay=true
"#,
            shortcut.name, shortcut.description, self.overlay_api_url
        );

        let desktop_path = PathBuf::from(format!(
            "/usr/share/applications/lifeos-shortcut-{}.desktop",
            shortcut.name
        ));

        // Write desktop entry
        tokio::fs::write(&desktop_path, desktop_file)
            .await
            .with_context(|| format!("Failed to write desktop entry for {}", shortcut.name))
            .inspect_err(|e| error!("{}", e))?;

        info!("Created shortcut entry: {}", desktop_path.display());

        Ok(())
    }

    /// Unregister all shortcuts
    pub async fn unregister_shortcuts(&self) -> Result<()> {
        info!("Unregistering global shortcuts");

        // Remove all shortcut desktop entries
        for shortcut in &self.shortcuts {
            let desktop_path = PathBuf::from(format!(
                "/usr/share/applications/lifeos-shortcut-{}.desktop",
                shortcut.name
            ));

            if desktop_path.exists() {
                tokio::fs::remove_file(&desktop_path)
                    .await
                    .with_context(|| {
                        format!("Failed to remove shortcut entry {}", desktop_path.display())
                    })
                    .inspect_err(|e| warn!("{}", e))?;
            }
        }

        self.active.store(false, Ordering::Relaxed);
        info!("Global shortcuts unregistered");

        Ok(())
    }

    /// Check if shortcuts are active
    pub fn is_active(&self) -> bool {
        self.active.load(Ordering::Relaxed)
    }

    /// Trigger a shortcut action
    pub async fn trigger_shortcut(&self, shortcut_name: &str) -> Result<()> {
        let shortcut = self
            .shortcuts
            .iter()
            .find(|s| s.name == shortcut_name)
            .ok_or_else(|| anyhow::anyhow!("Shortcut '{}' not found", shortcut_name))?;

        info!(
            "Triggering shortcut: {} ({:?})",
            shortcut.name, shortcut.action
        );

        match &shortcut.action {
            ShortcutAction::ToggleOverlay => {
                self.trigger_overlay_toggle().await?;
            }
            ShortcutAction::HideOverlay => {
                self.trigger_overlay_hide().await?;
            }
            ShortcutAction::ShowOverlay => {
                self.trigger_overlay_show().await?;
            }
            ShortcutAction::CaptureScreen => {
                self.trigger_capture_screen().await?;
            }
            ShortcutAction::Execute(cmd) => {
                self.execute_command(cmd).await?;
            }
        }

        Ok(())
    }

    /// Trigger overlay toggle via API
    async fn trigger_overlay_toggle(&self) -> Result<()> {
        let client = reqwest::Client::new();
        let url = format!("{}/toggle", self.overlay_api_url);

        let response = client.post(&url).send().await?;

        if !response.status().is_success() {
            anyhow::bail!("Failed to toggle overlay: {}", response.status());
        }

        Ok(())
    }

    /// Trigger overlay hide via API
    async fn trigger_overlay_hide(&self) -> Result<()> {
        let client = reqwest::Client::new();
        let url = format!("{}/hide", self.overlay_api_url);

        let response = client.post(&url).send().await?;

        if !response.status().is_success() {
            anyhow::bail!("Failed to hide overlay: {}", response.status());
        }

        Ok(())
    }

    /// Trigger overlay show via API
    async fn trigger_overlay_show(&self) -> Result<()> {
        let client = reqwest::Client::new();
        let url = format!("{}/show", self.overlay_api_url);

        let response = client.post(&url).send().await?;

        if !response.status().is_success() {
            anyhow::bail!("Failed to show overlay: {}", response.status());
        }

        Ok(())
    }

    /// Trigger screen capture
    async fn trigger_capture_screen(&self) -> Result<()> {
        let client = reqwest::Client::new();
        let url = format!("{}/screenshot", self.overlay_api_url);

        let response = client.post(&url).send().await?;

        if !response.status().is_success() {
            anyhow::bail!("Failed to trigger screenshot: {}", response.status());
        }

        Ok(())
    }

    /// Execute a shell command
    async fn execute_command(&self, cmd: &str) -> Result<()> {
        info!("Executing command: {}", cmd);

        let output = Command::new("sh")
            .arg("-c")
            .arg(cmd)
            .output()
            .with_context(|| format!("Command execution failed for '{}'", cmd))
            .inspect_err(|e| error!("{}", e))?;

        if !output.status.success() {
            warn!("Command '{}' exited with code: {}", cmd, output.status);
        }

        info!("Command '{}' completed", cmd);

        Ok(())
    }

    /// Get list of registered shortcuts
    pub fn list_shortcuts(&self) -> Vec<&Shortcut> {
        self.shortcuts.iter().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_shortcut_manager_creation() {
        let mgr = ShortcutManager::new("http://127.0.0.1:8081/api/v1/overlay".to_string());
        assert!(!mgr.shortcuts.is_empty());
        assert_eq!(mgr.shortcuts[0].name, "toggle-overlay");
    }

    #[test]
    fn test_shortcut_list() {
        let mgr = ShortcutManager::new("http://127.0.0.1:8081/api/v1/overlay".to_string());
        let shortcuts = mgr.list_shortcuts();
        assert_eq!(shortcuts.len(), 4);
    }
}
