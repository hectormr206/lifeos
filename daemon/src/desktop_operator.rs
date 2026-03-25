//! Desktop Operator — Axi controls the Linux desktop like a human would.
//!
//! Capabilities:
//! - Install/remove Flatpak apps
//! - Open applications (browser, LibreOffice, terminals)
//! - Navigate browser to URLs
//! - Type text and send keyboard shortcuts via ydotool
//! - Take screenshots and analyze UI via vision models
//! - Manage system settings (night mode, volume, brightness)
//! - Interact with files (open, move, rename)

use anyhow::{Context, Result};
use log::{info, warn};
use serde::{Deserialize, Serialize};
use tokio::process::Command;

/// Actions the desktop operator can perform.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum DesktopAction {
    /// Install a Flatpak application
    FlatpakInstall { app_id: String },
    /// Remove a Flatpak application
    FlatpakRemove { app_id: String },
    /// Open a URL in the default browser
    OpenUrl { url: String },
    /// Open an application by name or .desktop file
    OpenApp { name: String },
    /// Open a file with its default application
    OpenFile { path: String },
    /// Type text into the focused window
    TypeText { text: String },
    /// Send a keyboard shortcut (e.g., "ctrl+s", "alt+F4")
    SendKeys { combo: String },
    /// Set system volume (0-100)
    SetVolume { percent: u32 },
    /// Set screen brightness (0-100)
    SetBrightness { percent: u32 },
    /// Enable/disable night mode (blue light filter)
    NightMode { enabled: bool },
    /// Take a screenshot and return the path
    Screenshot,
    /// List installed Flatpak applications
    FlatpakList,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DesktopActionResult {
    pub success: bool,
    pub output: String,
}

pub struct DesktopOperator;

impl DesktopOperator {
    pub async fn execute(action: &DesktopAction) -> DesktopActionResult {
        match Self::execute_inner(action).await {
            Ok(output) => DesktopActionResult {
                success: true,
                output,
            },
            Err(e) => DesktopActionResult {
                success: false,
                output: format!("Error: {}", e),
            },
        }
    }

    async fn execute_inner(action: &DesktopAction) -> Result<String> {
        match action {
            DesktopAction::FlatpakInstall { app_id } => {
                info!("[desktop] Installing flatpak: {}", app_id);
                let output = Command::new("flatpak")
                    .args(["install", "-y", "--user", "flathub", app_id])
                    .output()
                    .await
                    .context("flatpak install failed")?;
                Ok(format_output(&output))
            }

            DesktopAction::FlatpakRemove { app_id } => {
                info!("[desktop] Removing flatpak: {}", app_id);
                let output = Command::new("flatpak")
                    .args(["uninstall", "-y", "--user", app_id])
                    .output()
                    .await
                    .context("flatpak uninstall failed")?;
                Ok(format_output(&output))
            }

            DesktopAction::FlatpakList => {
                let output = Command::new("flatpak")
                    .args(["list", "--app", "--columns=application,name,version"])
                    .output()
                    .await
                    .context("flatpak list failed")?;
                Ok(format_output(&output))
            }

            DesktopAction::OpenUrl { url } => {
                info!("[desktop] Opening URL: {}", url);
                Command::new("xdg-open")
                    .arg(url)
                    .output()
                    .await
                    .context("xdg-open failed")?;
                Ok(format!("Opened: {}", url))
            }

            DesktopAction::OpenApp { name } => {
                info!("[desktop] Opening app: {}", name);
                // Try gtk-launch first, fallback to direct execution
                let result = Command::new("gtk-launch").arg(name).output().await;
                match result {
                    Ok(o) if o.status.success() => Ok(format!("Launched: {}", name)),
                    _ => {
                        // Fallback: try running the command directly
                        let child = Command::new(name)
                            .spawn()
                            .context("Failed to launch application")?;
                        Ok(format!(
                            "Spawned: {} (pid {})",
                            name,
                            child.id().unwrap_or(0)
                        ))
                    }
                }
            }

            DesktopAction::OpenFile { path } => {
                info!("[desktop] Opening file: {}", path);
                let _child = Command::new("xdg-open")
                    .arg(path)
                    .spawn()
                    .context("xdg-open failed")?;
                Ok(format!("Opened: {}", path))
            }

            DesktopAction::TypeText { text } => {
                // Use ydotool for Wayland, xdotool for X11
                let result = Command::new("ydotool")
                    .args(["type", "--", text])
                    .output()
                    .await;
                match result {
                    Ok(o) if o.status.success() => Ok("Text typed via ydotool".into()),
                    _ => {
                        Command::new("xdotool")
                            .args(["type", "--", text])
                            .output()
                            .await
                            .context("Failed to type text (ydotool and xdotool both failed)")?;
                        Ok("Text typed via xdotool".into())
                    }
                }
            }

            DesktopAction::SendKeys { combo } => {
                let result = Command::new("ydotool").args(["key", combo]).output().await;
                match result {
                    Ok(o) if o.status.success() => Ok(format!("Key sent: {}", combo)),
                    _ => {
                        Command::new("xdotool")
                            .args(["key", combo])
                            .output()
                            .await
                            .context("Failed to send keys")?;
                        Ok(format!("Key sent via xdotool: {}", combo))
                    }
                }
            }

            DesktopAction::SetVolume { percent } => {
                let vol = percent.min(&100);
                Command::new("wpctl")
                    .args(["set-volume", "@DEFAULT_AUDIO_SINK@", &format!("{}%", vol)])
                    .output()
                    .await
                    .context("wpctl set-volume failed")?;
                Ok(format!("Volume set to {}%", vol))
            }

            DesktopAction::SetBrightness { percent } => {
                let pct = percent.min(&100);
                // Try brightnessctl first
                let result = Command::new("brightnessctl")
                    .args(["set", &format!("{}%", pct)])
                    .output()
                    .await;
                match result {
                    Ok(o) if o.status.success() => Ok(format!("Brightness set to {}%", pct)),
                    _ => {
                        // Fallback: write to sysfs
                        warn!("[desktop] brightnessctl not available, trying sysfs");
                        anyhow::bail!("brightnessctl not found — install it for brightness control")
                    }
                }
            }

            DesktopAction::NightMode { enabled } => {
                if *enabled {
                    // Try wlsunset for Wayland
                    let _ = Command::new("wlsunset")
                        .args(["-T", "4500", "-t", "3500"])
                        .spawn();
                    Ok("Night mode enabled (4500K → 3500K)".into())
                } else {
                    let _ = Command::new("pkill").arg("wlsunset").output().await;
                    Ok("Night mode disabled".into())
                }
            }

            DesktopAction::Screenshot => {
                // Try grim (Wayland), fallback to gnome-screenshot
                let path = format!(
                    "/tmp/lifeos-screenshot-{}.png",
                    chrono::Utc::now().format("%Y%m%d-%H%M%S")
                );
                let result = Command::new("grim").arg(&path).output().await;
                match result {
                    Ok(o) if o.status.success() => Ok(path),
                    _ => {
                        Command::new("gnome-screenshot")
                            .args(["-f", &path])
                            .output()
                            .await
                            .context("Screenshot failed (grim and gnome-screenshot)")?;
                        Ok(path)
                    }
                }
            }
        }
    }
}

fn format_output(output: &std::process::Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if output.status.success() {
        stdout.trim().to_string()
    } else {
        format!("Exit {}: {}{}", output.status, stdout.trim(), stderr.trim())
    }
}
