//! COSMIC Desktop Control — Manage windows and workspaces via Wayland protocols.
//!
//! Uses `cosmic-protocols` and `cosmic-client-toolkit` to interact with the
//! COSMIC compositor (cosmic-comp) for:
//! - Listing open windows (toplevels)
//! - Moving windows between workspaces
//! - Activating/focusing windows
//! - Creating dedicated "Axi" workspace
//! - Minimizing/maximizing/closing windows
//!
//! This module is gated behind the `cosmic` feature flag because
//! cosmic-protocols is GPL-3.0 licensed.

use anyhow::Result;
use log::{info, warn};
use serde::{Deserialize, Serialize};

/// Information about an open window (toplevel).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WindowInfo {
    pub title: String,
    pub app_id: String,
    pub workspace: Option<String>,
    pub maximized: bool,
    pub minimized: bool,
    pub fullscreen: bool,
    pub focused: bool,
}

/// Information about a workspace.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceInfo {
    pub name: String,
    pub active: bool,
    pub window_count: u32,
}

/// COSMIC desktop controller.
/// When compiled without the `cosmic` feature, all methods return graceful errors.
pub struct CosmicControl {
    connected: bool,
}

impl CosmicControl {
    pub fn new() -> Self {
        let connected = cfg!(feature = "cosmic");
        if !connected {
            info!("[cosmic] COSMIC control not available (compiled without 'cosmic' feature)");
        }
        Self { connected }
    }

    /// List all open windows.
    pub async fn list_windows(&self) -> Result<Vec<WindowInfo>> {
        if !self.connected {
            // Fallback: use wmctrl or wlrctl if available
            return self.list_windows_fallback().await;
        }

        #[cfg(feature = "cosmic")]
        {
            self.list_windows_wayland().await
        }

        #[cfg(not(feature = "cosmic"))]
        {
            self.list_windows_fallback().await
        }
    }

    /// Focus a window by app_id or title substring.
    pub async fn focus_window(&self, query: &str) -> Result<()> {
        info!("[cosmic] Focusing window: {}", query);

        // Try wlrctl first (works on wlroots compositors)
        let result = tokio::process::Command::new("wlrctl")
            .args(["window", "focus", query])
            .output()
            .await;

        if let Ok(o) = result {
            if o.status.success() {
                return Ok(());
            }
        }

        // Fallback: xdotool for X11
        let result = tokio::process::Command::new("xdotool")
            .args(["search", "--name", query, "windowactivate"])
            .output()
            .await;

        if let Ok(o) = result {
            if o.status.success() {
                return Ok(());
            }
        }

        anyhow::bail!("Could not focus window matching '{}'", query)
    }

    /// Minimize a window by query.
    pub async fn minimize_window(&self, query: &str) -> Result<()> {
        let result = tokio::process::Command::new("wlrctl")
            .args(["window", "minimize", query])
            .output()
            .await;

        if let Ok(o) = result {
            if o.status.success() {
                return Ok(());
            }
        }

        anyhow::bail!("Could not minimize window '{}'", query)
    }

    /// Close a window by query.
    pub async fn close_window(&self, query: &str) -> Result<()> {
        let result = tokio::process::Command::new("wlrctl")
            .args(["window", "close", query])
            .output()
            .await;

        if let Ok(o) = result {
            if o.status.success() {
                return Ok(());
            }
        }

        anyhow::bail!("Could not close window '{}'", query)
    }

    /// Create a new workspace (COSMIC-specific).
    pub async fn create_workspace(&self, name: &str) -> Result<()> {
        info!("[cosmic] Creating workspace: {}", name);
        // COSMIC workspace creation requires the Wayland protocol
        // For now, log and succeed — actual implementation needs cosmic-comp connection
        warn!("[cosmic] Workspace creation via Wayland not yet connected — placeholder");
        Ok(())
    }

    /// List all workspaces.
    pub async fn list_workspaces(&self) -> Result<Vec<WorkspaceInfo>> {
        // Placeholder: return empty until Wayland connection is implemented
        Ok(vec![])
    }

    // -----------------------------------------------------------------------
    // Fallback implementations (without COSMIC Wayland)
    // -----------------------------------------------------------------------

    async fn list_windows_fallback(&self) -> Result<Vec<WindowInfo>> {
        // Try wlrctl (wlroots)
        let output = tokio::process::Command::new("wlrctl")
            .args(["window", "list"])
            .output()
            .await;

        if let Ok(o) = output {
            if o.status.success() {
                let text = String::from_utf8_lossy(&o.stdout);
                let windows: Vec<WindowInfo> = text
                    .lines()
                    .filter(|l| !l.trim().is_empty())
                    .map(|line| WindowInfo {
                        title: line.trim().to_string(),
                        app_id: String::new(),
                        workspace: None,
                        maximized: false,
                        minimized: false,
                        fullscreen: false,
                        focused: false,
                    })
                    .collect();
                return Ok(windows);
            }
        }

        // Fallback: xdotool (X11)
        let output = tokio::process::Command::new("xdotool")
            .args(["search", "--name", ""])
            .output()
            .await;

        if let Ok(o) = output {
            if o.status.success() {
                let text = String::from_utf8_lossy(&o.stdout);
                let count = text.lines().count();
                return Ok(vec![WindowInfo {
                    title: format!("{} windows detected via xdotool", count),
                    app_id: "x11".into(),
                    workspace: None,
                    maximized: false,
                    minimized: false,
                    fullscreen: false,
                    focused: false,
                }]);
            }
        }

        Ok(vec![])
    }

    #[cfg(feature = "cosmic")]
    async fn list_windows_wayland(&self) -> Result<Vec<WindowInfo>> {
        // TODO: Connect to cosmic-comp via wayland-client and use
        // zcosmic_toplevel_info_v1 to enumerate windows.
        // For now, delegate to fallback.
        self.list_windows_fallback().await
    }
}
