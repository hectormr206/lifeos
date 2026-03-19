//! Global Keyboard Shortcut Handler
//!
//! Handles global keyboard shortcuts for LifeOS.
//! Super+Space opens the web dashboard in the default browser.

use anyhow::{Context, Result};
use log::{error, info, warn};
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};

/// Global keyboard shortcut manager
pub struct ShortcutManager {
    shortcuts: Vec<Shortcut>,
    active: AtomicBool,
    /// Full dashboard URL including token query param.
    dashboard_url: String,
}

/// Keyboard shortcut definition
#[derive(Debug, Clone)]
pub struct Shortcut {
    pub name: String,
    pub keys: String,
    pub action: ShortcutAction,
    pub description: String,
}

/// Actions triggered by shortcuts
#[derive(Debug, Clone)]
pub enum ShortcutAction {
    /// Open dashboard in browser
    OpenDashboard,
    /// Capture screen for AI context
    CaptureScreen,
    /// Execute custom command
    Execute(String),
}

impl ShortcutManager {
    pub fn new(dashboard_url: String) -> Self {
        Self {
            shortcuts: vec![
                Shortcut {
                    name: "open-dashboard".to_string(),
                    keys: "Super+space".to_string(),
                    action: ShortcutAction::OpenDashboard,
                    description: "Open LifeOS dashboard".to_string(),
                },
                Shortcut {
                    name: "capture-screen".to_string(),
                    keys: "Super+Shift+S".to_string(),
                    action: ShortcutAction::CaptureScreen,
                    description: "Capture screen for AI".to_string(),
                },
            ],
            active: AtomicBool::new(false),
            dashboard_url,
        }
    }

    /// Register all global shortcuts using xdg-desktop-portal
    pub async fn register_shortcuts(&self) -> Result<()> {
        info!("Registering global shortcuts with xdg-desktop-portal");

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

        for shortcut in &self.shortcuts {
            self.create_shortcut_entry(shortcut).await?;
        }

        info!("Global shortcuts registered successfully");
        self.active.store(true, Ordering::Relaxed);
        Ok(())
    }

    async fn create_shortcut_entry(&self, shortcut: &Shortcut) -> Result<()> {
        let exec_cmd = match &shortcut.action {
            ShortcutAction::OpenDashboard => {
                format!("xdg-open {}", self.dashboard_url)
            }
            ShortcutAction::CaptureScreen => "life voice describe-screen".to_string(),
            ShortcutAction::Execute(cmd) => cmd.clone(),
        };

        let desktop_file = format!(
            "[Desktop Entry]\nName={}\nComment={}\nType=Application\nExec={}\nTerminal=false\nNoDisplay=true\n",
            shortcut.name, shortcut.description, exec_cmd,
        );

        let desktop_path = PathBuf::from(format!(
            "/usr/share/applications/lifeos-shortcut-{}.desktop",
            shortcut.name
        ));

        tokio::fs::write(&desktop_path, desktop_file)
            .await
            .with_context(|| format!("Failed to write desktop entry for {}", shortcut.name))
            .inspect_err(|e| error!("{}", e))?;

        info!("Created shortcut entry: {}", desktop_path.display());
        Ok(())
    }

    pub async fn unregister_shortcuts(&self) -> Result<()> {
        info!("Unregistering global shortcuts");
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

    pub fn is_active(&self) -> bool {
        self.active.load(Ordering::Relaxed)
    }

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
            ShortcutAction::OpenDashboard => {
                Command::new("xdg-open")
                    .arg(&self.dashboard_url)
                    .spawn()
                    .with_context(|| "Failed to open dashboard")?;
            }
            ShortcutAction::CaptureScreen | ShortcutAction::Execute(_) => {
                let cmd = match &shortcut.action {
                    ShortcutAction::CaptureScreen => "life voice describe-screen",
                    ShortcutAction::Execute(c) => c.as_str(),
                    _ => unreachable!(),
                };
                let output = Command::new("sh")
                    .arg("-c")
                    .arg(cmd)
                    .output()
                    .with_context(|| format!("Command execution failed for '{}'", cmd))
                    .inspect_err(|e| error!("{}", e))?;
                if !output.status.success() {
                    warn!("Command '{}' exited with code: {}", cmd, output.status);
                }
            }
        }

        Ok(())
    }

    pub fn list_shortcuts(&self) -> Vec<&Shortcut> {
        self.shortcuts.iter().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_shortcut_manager_creation() {
        let mgr = ShortcutManager::new("http://127.0.0.1:8081/dashboard?token=test".to_string());
        assert!(!mgr.shortcuts.is_empty());
        assert_eq!(mgr.shortcuts[0].name, "open-dashboard");
    }

    #[test]
    fn test_shortcut_list() {
        let mgr = ShortcutManager::new("http://127.0.0.1:8081/dashboard?token=test".to_string());
        let shortcuts = mgr.list_shortcuts();
        assert_eq!(shortcuts.len(), 2);
    }
}
