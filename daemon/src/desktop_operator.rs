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
use std::sync::Arc;
use tokio::process::Command;
use tokio::sync::RwLock;

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
    /// Override Flatpak app permissions
    FlatpakOverride { app_id: String, permission: String },
    /// List/start/stop/restart a systemd user service
    SystemdService {
        operation: String, // "list", "start", "stop", "restart", "status"
        unit: Option<String>,
    },
    /// Compress a file or directory
    Compress {
        path: String,
        format: String, // "zip", "tar.gz", "7z"
    },
    /// Extract an archive
    Extract {
        path: String,
        destination: Option<String>,
    },
    /// OCR: read text from a screenshot or image file
    OcrRead { image_path: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DesktopActionResult {
    pub success: bool,
    pub output: String,
}

pub struct DesktopOperator;

impl DesktopOperator {
    /// Execute a DesktopAction with optional sensory-pipeline gating.
    /// The `sensory` argument is consulted for `Screenshot` so that
    /// MCP / supervisor callers cannot bypass kill-switch, master
    /// screen toggle, suspend, session lock, or sensitive-window
    /// policy. Pass `None` only when the caller has already gated
    /// the request upstream (currently no such caller exists).
    pub async fn execute(
        action: &DesktopAction,
        sensory: Option<Arc<RwLock<crate::sensory_pipeline::SensoryPipelineManager>>>,
    ) -> DesktopActionResult {
        match Self::execute_inner(action, sensory).await {
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

    async fn execute_inner(
        action: &DesktopAction,
        sensory: Option<Arc<RwLock<crate::sensory_pipeline::SensoryPipelineManager>>>,
    ) -> Result<String> {
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
                // Unified sense gate BEFORE shelling grim. Round-2 audit
                // C-NEW-3: MCP `desktop_action.screenshot` + the
                // browser-screenshot wrapper previously bypassed every
                // user policy and wrote /tmp 0o644. Fail-closed when the
                // sensory manager isn't plumbed — a caller that omits
                // the argument cannot capture.
                let sensory = sensory.ok_or_else(|| {
                    anyhow::anyhow!(
                        "desktop Screenshot refused: sensory pipeline not wired (fail-closed)"
                    )
                })?;
                {
                    let guard = sensory.read().await;
                    if let Err(reason) = guard
                        .ensure_sense_allowed(
                            crate::sensory_pipeline::Sense::Screen,
                            "desktop_operator.Screenshot",
                        )
                        .await
                    {
                        anyhow::bail!("desktop Screenshot refused: {}", reason);
                    }
                }

                // Try grim (Wayland), fallback to gnome-screenshot.
                // Output goes to /tmp with 0o600 — prior behavior was
                // 0o644 world-readable. We keep /tmp rather than moving
                // to /var/lib/lifeos/screenshots/ because this path is
                // used by MCP callers that consume the file immediately
                // and may run in contexts without write access to the
                // managed dir. The retention story for this path is
                // tmpreaper, not storage_housekeeping.
                let path = format!(
                    "/tmp/lifeos-screenshot-{}.png",
                    chrono::Utc::now().format("%Y%m%d-%H%M%S")
                );
                let result = Command::new("grim").arg(&path).output().await;
                let captured = match result {
                    Ok(o) if o.status.success() => true,
                    _ => {
                        Command::new("gnome-screenshot")
                            .args(["-f", &path])
                            .output()
                            .await
                            .context("Screenshot failed (grim and gnome-screenshot)")?;
                        true
                    }
                };
                if captured {
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::PermissionsExt;
                        if let Ok(md) = tokio::fs::metadata(&path).await {
                            let mut perms = md.permissions();
                            perms.set_mode(0o600);
                            let _ = tokio::fs::set_permissions(&path, perms).await;
                        }
                    }
                }
                Ok(path)
            }

            DesktopAction::FlatpakOverride { app_id, permission } => {
                info!(
                    "[desktop] Overriding flatpak permission: {} for {}",
                    permission, app_id
                );
                let output = Command::new("flatpak")
                    .args(["override", "--user", permission, app_id])
                    .output()
                    .await
                    .context("flatpak override failed")?;
                Ok(format_output(&output))
            }

            DesktopAction::SystemdService { operation, unit } => {
                let args: Vec<&str> = match operation.as_str() {
                    "list" => vec!["--user", "list-units", "--type=service", "--state=running"],
                    "start" | "stop" | "restart" | "status" => {
                        let u = unit.as_deref().ok_or_else(|| {
                            anyhow::anyhow!("unit name required for {}", operation)
                        })?;
                        vec!["--user", operation.as_str(), u]
                    }
                    _ => anyhow::bail!("Unknown systemd operation: {}", operation),
                };
                let output = Command::new("systemctl")
                    .args(&args)
                    .output()
                    .await
                    .context("systemctl failed")?;
                Ok(format_output(&output))
            }

            DesktopAction::Compress { path, format } => {
                info!("[desktop] Compressing: {} as {}", path, format);
                let output_file = format!("{}.{}", path, format);
                let output = match format.as_str() {
                    "zip" => Command::new("zip")
                        .args(["-r", &output_file, path])
                        .output()
                        .await
                        .context("zip failed")?,
                    "tar.gz" => Command::new("tar")
                        .args(["czf", &output_file, path])
                        .output()
                        .await
                        .context("tar failed")?,
                    "7z" => Command::new("7z")
                        .args(["a", &output_file, path])
                        .output()
                        .await
                        .context("7z failed")?,
                    _ => anyhow::bail!("Unknown format: {}", format),
                };
                if output.status.success() {
                    Ok(format!("Compressed to: {}", output_file))
                } else {
                    Ok(format!("Compression failed: {}", format_output(&output)))
                }
            }

            DesktopAction::Extract { path, destination } => {
                info!("[desktop] Extracting: {}", path);
                let dest = destination.as_deref().unwrap_or(".");
                let output = if path.ends_with(".zip") {
                    Command::new("unzip")
                        .args(["-o", path, "-d", dest])
                        .output()
                        .await
                        .context("unzip failed")?
                } else if path.ends_with(".tar.gz") || path.ends_with(".tgz") {
                    Command::new("tar")
                        .args(["xzf", path, "-C", dest])
                        .output()
                        .await
                        .context("tar failed")?
                } else if path.ends_with(".7z") {
                    Command::new("7z")
                        .args(["x", path, &format!("-o{}", dest)])
                        .output()
                        .await
                        .context("7z failed")?
                } else {
                    anyhow::bail!("Unknown archive format: {}", path)
                };
                Ok(format_output(&output))
            }

            DesktopAction::OcrRead { image_path } => {
                info!("[desktop] OCR reading: {}", image_path);
                let output = Command::new("tesseract")
                    .args([image_path.as_str(), "stdout", "-l", "eng+spa"])
                    .output()
                    .await
                    .context("tesseract OCR failed")?;
                if output.status.success() {
                    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
                } else {
                    anyhow::bail!("OCR failed: {}", String::from_utf8_lossy(&output.stderr))
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
