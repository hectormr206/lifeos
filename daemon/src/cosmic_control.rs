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

use crate::llm_router::{ChatMessage, LlmRouter, RouterRequest, TaskComplexity};

/// Resolve the user config directory ($XDG_CONFIG_HOME or $HOME/.config).
fn resolve_config_dir() -> Result<std::path::PathBuf, String> {
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        return Ok(std::path::PathBuf::from(xdg));
    }
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    Ok(std::path::PathBuf::from(home).join(".config"))
}

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

/// Information about an output (monitor).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OutputInfo {
    pub name: String,
    pub make: String,
    pub model: String,
    pub width: u32,
    pub height: u32,
    pub x: i32,
    pub y: i32,
    pub focused: bool,
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

    /// Create a new workspace via swaymsg.
    pub async fn create_workspace(&self, name: &str) -> Result<()> {
        info!("[cosmic] Creating workspace: {}", name);
        let output = tokio::process::Command::new("swaymsg")
            .args(["workspace", name])
            .output()
            .await
            .map_err(|e| anyhow::anyhow!("Failed to run swaymsg: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("swaymsg workspace failed: {}", stderr);
        }
        info!("[cosmic] Workspace '{}' created/switched", name);
        Ok(())
    }

    /// List all workspaces via swaymsg.
    pub async fn list_workspaces(&self) -> Result<Vec<WorkspaceInfo>> {
        let output = tokio::process::Command::new("swaymsg")
            .args(["-t", "get_workspaces"])
            .output()
            .await
            .map_err(|e| anyhow::anyhow!("Failed to run swaymsg: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("swaymsg get_workspaces failed: {}", stderr);
        }

        let json_str = String::from_utf8_lossy(&output.stdout);
        let raw: Vec<serde_json::Value> = serde_json::from_str(&json_str)
            .map_err(|e| anyhow::anyhow!("Failed to parse workspaces JSON: {}", e))?;

        let workspaces = raw
            .iter()
            .map(|ws| WorkspaceInfo {
                name: ws["name"].as_str().unwrap_or("").to_string(),
                active: ws["focused"].as_bool().unwrap_or(false),
                window_count: 0, // swaymsg does not report per-workspace window count
            })
            .collect();

        Ok(workspaces)
    }

    // -----------------------------------------------------------------------
    // Feature 1: System Settings via cosmic-settings CLI / config files
    // -----------------------------------------------------------------------

    /// Apply a system setting by mapping common keys to COSMIC config files or CLI tools.
    pub async fn set_system_setting(&self, setting: &str, value: &str) -> Result<String, String> {
        info!("[cosmic] Setting '{}' = '{}'", setting, value);

        match setting {
            "wallpaper" => {
                let config_dir = resolve_config_dir()?;
                let wallpaper_dir = config_dir.join("cosmic/com.system76.CosmicBackground/v1");
                std::fs::create_dir_all(&wallpaper_dir)
                    .map_err(|e| format!("Failed to create wallpaper config dir: {}", e))?;
                let wallpaper_file = wallpaper_dir.join("all");
                std::fs::write(&wallpaper_file, value)
                    .map_err(|e| format!("Failed to write wallpaper config: {}", e))?;
                Ok(format!("Wallpaper set to '{}' (restart cosmic-bg to apply)", value))
            }
            "dark-mode" => {
                let config_dir = resolve_config_dir()?;
                let theme_dir =
                    config_dir.join("cosmic/com.system76.CosmicTheme.Mode/v1");
                std::fs::create_dir_all(&theme_dir)
                    .map_err(|e| format!("Failed to create theme config dir: {}", e))?;
                let dark_file = theme_dir.join("is_dark");
                let is_dark = matches!(value.to_lowercase().as_str(), "true" | "1" | "on" | "yes");
                std::fs::write(&dark_file, if is_dark { "true" } else { "false" })
                    .map_err(|e| format!("Failed to write dark-mode config: {}", e))?;
                Ok(format!("Dark mode set to {}", is_dark))
            }
            "default-browser" => {
                let output = tokio::process::Command::new("xdg-settings")
                    .args(["set", "default-web-browser", value])
                    .output()
                    .await
                    .map_err(|e| format!("Failed to run xdg-settings: {}", e))?;
                if output.status.success() {
                    Ok(format!("Default browser set to '{}'", value))
                } else {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    Err(format!("xdg-settings failed: {}", stderr))
                }
            }
            "keyboard-shortcut" => {
                // Expected value format: "binding:action" e.g. "Super+T:cosmic-terminal"
                let parts: Vec<&str> = value.splitn(2, ':').collect();
                if parts.len() != 2 {
                    return Err(
                        "keyboard-shortcut value must be 'binding:action' (e.g. 'Super+T:cosmic-terminal')"
                            .to_string(),
                    );
                }
                let config_dir = resolve_config_dir()?;
                let keybindings_dir =
                    config_dir.join("cosmic/com.system76.CosmicSettings.Shortcuts/v1");
                std::fs::create_dir_all(&keybindings_dir)
                    .map_err(|e| format!("Failed to create keybindings dir: {}", e))?;
                let custom_file = keybindings_dir.join("custom");

                // Append the new binding as a line
                let entry = format!("{}={}\n", parts[0], parts[1]);
                let mut existing = std::fs::read_to_string(&custom_file).unwrap_or_default();
                existing.push_str(&entry);
                std::fs::write(&custom_file, &existing)
                    .map_err(|e| format!("Failed to write keybinding: {}", e))?;
                Ok(format!("Keyboard shortcut '{}' -> '{}' added", parts[0], parts[1]))
            }
            _ => Err(format!(
                "Unknown setting '{}'. Supported: wallpaper, dark-mode, default-browser, keyboard-shortcut",
                setting
            )),
        }
    }

    // -----------------------------------------------------------------------
    // Feature 2: Window Search via swaymsg get_tree
    // -----------------------------------------------------------------------

    /// Find a window matching a query by title or app_id (case-insensitive substring).
    pub async fn find_window(&self, query: &str) -> Result<Option<WindowInfo>, String> {
        let output = tokio::process::Command::new("swaymsg")
            .args(["-t", "get_tree"])
            .output()
            .await
            .map_err(|e| format!("Failed to run swaymsg: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("swaymsg get_tree failed: {}", stderr));
        }

        let json_str = String::from_utf8_lossy(&output.stdout);
        let tree: serde_json::Value = serde_json::from_str(&json_str)
            .map_err(|e| format!("Failed to parse tree JSON: {}", e))?;

        let query_lower = query.to_lowercase();
        Ok(Self::search_tree_for_window(&tree, &query_lower))
    }

    /// Recursively search the sway tree for a window matching the query.
    fn search_tree_for_window(node: &serde_json::Value, query: &str) -> Option<WindowInfo> {
        let title = node["name"].as_str().unwrap_or("");
        let app_id = node["app_id"].as_str().unwrap_or("");

        // Check if this node is a window (has app_id or is a leaf with a title)
        let is_window = node["type"].as_str() == Some("con")
            || node["type"].as_str() == Some("floating_con")
            || !app_id.is_empty();

        if is_window
            && (!title.is_empty() || !app_id.is_empty())
            && (title.to_lowercase().contains(query) || app_id.to_lowercase().contains(query))
        {
            return Some(WindowInfo {
                title: title.to_string(),
                app_id: app_id.to_string(),
                workspace: node["workspace"].as_str().map(|s| s.to_string()),
                maximized: node["fullscreen_mode"].as_u64().unwrap_or(0) == 1,
                minimized: false,
                fullscreen: node["fullscreen_mode"].as_u64().unwrap_or(0) == 1,
                focused: node["focused"].as_bool().unwrap_or(false),
            });
        }

        // Recurse into child nodes
        if let Some(nodes) = node["nodes"].as_array() {
            for child in nodes {
                if let Some(found) = Self::search_tree_for_window(child, query) {
                    return Some(found);
                }
            }
        }
        if let Some(floating) = node["floating_nodes"].as_array() {
            for child in floating {
                if let Some(found) = Self::search_tree_for_window(child, query) {
                    return Some(found);
                }
            }
        }

        None
    }

    // -----------------------------------------------------------------------
    // Feature 3: Multi-Monitor Awareness
    // -----------------------------------------------------------------------

    /// List all outputs (monitors) via swaymsg.
    pub async fn list_outputs(&self) -> Result<Vec<OutputInfo>, String> {
        let output = tokio::process::Command::new("swaymsg")
            .args(["-t", "get_outputs"])
            .output()
            .await
            .map_err(|e| format!("Failed to run swaymsg: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("swaymsg get_outputs failed: {}", stderr));
        }

        let json_str = String::from_utf8_lossy(&output.stdout);
        let raw: Vec<serde_json::Value> = serde_json::from_str(&json_str)
            .map_err(|e| format!("Failed to parse outputs JSON: {}", e))?;

        let outputs = raw
            .iter()
            .map(|o| {
                let rect = &o["rect"];
                let mode = &o["current_mode"];
                OutputInfo {
                    name: o["name"].as_str().unwrap_or("").to_string(),
                    make: o["make"].as_str().unwrap_or("").to_string(),
                    model: o["model"].as_str().unwrap_or("").to_string(),
                    width: mode["width"].as_u64().unwrap_or(0) as u32,
                    height: mode["height"].as_u64().unwrap_or(0) as u32,
                    x: rect["x"].as_i64().unwrap_or(0) as i32,
                    y: rect["y"].as_i64().unwrap_or(0) as i32,
                    focused: o["focused"].as_bool().unwrap_or(false),
                }
            })
            .collect();

        Ok(outputs)
    }

    /// Move a window matching the query to a specific output (monitor).
    pub async fn move_window_to_output(
        &self,
        window_query: &str,
        output_name: &str,
    ) -> Result<(), String> {
        info!(
            "[cosmic] Moving window '{}' to output '{}'",
            window_query, output_name
        );

        // First, find and focus the window
        let window = self
            .find_window(window_query)
            .await?
            .ok_or_else(|| format!("No window found matching '{}'", window_query))?;

        // Focus the window by its title using swaymsg criteria
        let focus_criteria = if !window.app_id.is_empty() {
            format!("[app_id=\"{}\"]", window.app_id)
        } else {
            format!("[title=\"{}\"]", window.title)
        };

        let focus_cmd = format!("{} focus", focus_criteria);
        let output = tokio::process::Command::new("swaymsg")
            .arg(&focus_cmd)
            .output()
            .await
            .map_err(|e| format!("Failed to focus window: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            warn!("[cosmic] Focus via criteria failed: {}", stderr);
        }

        // Move the focused window to the target output
        let move_cmd = format!("move container to output {}", output_name);
        let output = tokio::process::Command::new("swaymsg")
            .arg(&move_cmd)
            .output()
            .await
            .map_err(|e| format!("Failed to move window: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("swaymsg move failed: {}", stderr));
        }

        Ok(())
    }

    // -----------------------------------------------------------------------
    // Feature 5: Smart Coordinates (vision LLM + grim + ydotool)
    // -----------------------------------------------------------------------

    /// Take a screenshot and ask the vision LLM for the pixel coordinates of a UI element.
    pub async fn find_element_coordinates(
        &self,
        description: &str,
        router: &LlmRouter,
    ) -> Result<(i32, i32), String> {
        info!(
            "[cosmic] Finding element coordinates for: '{}'",
            description
        );

        // 1. Capture screenshot via grim
        let screenshot_path = "/tmp/lifeos-find-element.png";
        let grim_output = tokio::process::Command::new("grim")
            .arg(screenshot_path)
            .output()
            .await
            .map_err(|e| format!("Failed to run grim: {}", e))?;

        if !grim_output.status.success() {
            let stderr = String::from_utf8_lossy(&grim_output.stderr);
            return Err(format!("grim screenshot failed: {}", stderr));
        }

        // 2. Read the screenshot and encode as base64
        let image_bytes = std::fs::read(screenshot_path)
            .map_err(|e| format!("Failed to read screenshot: {}", e))?;

        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&image_bytes);
        let data_url = format!("data:image/png;base64,{}", b64);

        // 3. Send to vision LLM via router
        let prompt = format!(
            "Find the exact pixel coordinates (x, y) of the UI element described as: '{}'. \
             Return ONLY the coordinates in format: x,y",
            description
        );

        let request = RouterRequest {
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: serde_json::json!([
                    { "type": "text", "text": prompt },
                    { "type": "image_url", "image_url": { "url": data_url } }
                ]),
            }],
            complexity: Some(TaskComplexity::Vision),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(50),
        };

        let response = router
            .chat(&request)
            .await
            .map_err(|e| format!("LLM vision request failed: {}", e))?;

        // 4. Parse "x,y" from the response text
        let text = response.text.trim();
        let coords: Vec<&str> = text
            .trim_matches(|c: char| !c.is_ascii_digit() && c != ',' && c != '-')
            .split(',')
            .collect();

        if coords.len() != 2 {
            return Err(format!(
                "Could not parse coordinates from LLM response: '{}'",
                text
            ));
        }

        let x: i32 = coords[0]
            .trim()
            .parse()
            .map_err(|_| format!("Invalid x coordinate: '{}'", coords[0]))?;
        let y: i32 = coords[1]
            .trim()
            .parse()
            .map_err(|_| format!("Invalid y coordinate: '{}'", coords[1]))?;

        info!("[cosmic] Found element '{}' at ({}, {})", description, x, y);
        Ok((x, y))
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
