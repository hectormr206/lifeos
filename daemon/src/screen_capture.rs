//! Screen capture module for LifeOS
//!
//! Provides cross-platform screen capture functionality for:
//! - AI Overlay context (what user is seeing)
//! - FollowAlong (monitoring user actions)
//! - Documentation of issues
//!
//! Supports both X11 and Wayland (COSMIC) backends.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::Command;
use tokio::fs;

/// Screen capture configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaptureConfig {
    /// Capture resolution (width x height)
    pub resolution: Resolution,
    /// JPEG quality (1-100)
    pub quality: u8,
    /// Capture format
    pub format: CaptureFormat,
    /// Whether to capture all monitors
    pub all_monitors: bool,
}

impl Default for CaptureConfig {
    fn default() -> Self {
        Self {
            resolution: Resolution::Full,
            quality: 85,
            format: CaptureFormat::Jpeg,
            all_monitors: true,
        }
    }
}

/// Capture resolution
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub enum Resolution {
    /// Full screen resolution
    #[default]
    Full,
    /// HD (1920x1080)
    Hd,
    /// SD (1280x720)
    Sd,
    /// Custom resolution
    Custom { width: u32, height: u32 },
}

/// Capture format
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub enum CaptureFormat {
    /// JPEG format (smaller, faster)
    #[default]
    Jpeg,
    /// PNG format (lossless, larger)
    Png,
    /// WebP format (modern, efficient)
    WebP,
}

/// Captured screenshot metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Screenshot {
    pub filename: String,
    pub path: PathBuf,
    pub width: u32,
    pub height: u32,
    pub format: CaptureFormat,
    pub size_bytes: u64,
    pub timestamp: String,
    pub monitor: Option<String>,
}

/// Screen capture manager
pub struct ScreenCapture {
    config: CaptureConfig,
    output_dir: PathBuf,
}

impl ScreenCapture {
    /// Create new screen capture manager
    pub fn new(output_dir: PathBuf) -> Self {
        Self {
            config: CaptureConfig::default(),
            output_dir,
        }
    }

    /// Create with custom config
    pub fn with_config(output_dir: PathBuf, config: CaptureConfig) -> Self {
        Self { config, output_dir }
    }

    /// Capture screenshot
    pub async fn capture(&self) -> Result<Screenshot> {
        // Ensure output directory exists
        fs::create_dir_all(&self.output_dir)
            .await
            .context("Failed to create output directory")?;

        // Detect display server type
        let display_type = self.detect_display_type().await?;
        log::debug!("Display type detected: {:?}", display_type);

        // Capture based on display type
        match display_type {
            DisplayType::Wayland => self.capture_wayland().await,
            DisplayType::X11 => self.capture_x11().await,
            DisplayType::Unknown => anyhow::bail!("Unsupported display type"),
        }
    }

    /// Detect display server type
    async fn detect_display_type(&self) -> Result<DisplayType> {
        // Check for WAYLAND_DISPLAY env var
        if std::env::var("WAYLAND_DISPLAY").is_ok() {
            return Ok(DisplayType::Wayland);
        }

        // Check for XDG_SESSION_TYPE
        if let Ok(session) = std::env::var("XDG_SESSION_TYPE") {
            if session.contains("wayland") {
                return Ok(DisplayType::Wayland);
            }
        }

        // Check for XDG_SESSION_ID (indicates X11)
        if std::env::var("XDG_SESSION_ID").is_ok() {
            return Ok(DisplayType::X11);
        }

        // Fallback: check for Xwayland
        let xwayland = Command::new("ps")
            .args(["-e"])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).contains("Xwayland"))
            .unwrap_or(false);

        if xwayland {
            return Ok(DisplayType::X11);
        }

        Ok(DisplayType::Unknown)
    }

    /// Capture screenshot on Wayland (COSMIC)
    async fn capture_wayland(&self) -> Result<Screenshot> {
        // Try grim (modern Wayland screenshot tool)
        if let Ok(output) = Command::new("which").arg("grim").output() {
            if output.status.success() {
                return self.capture_with_grim().await;
            }
        }

        // Try swaygrab for wlroots-based compositors
        if let Ok(output) = Command::new("which").arg("swaygrab").output() {
            if output.status.success() {
                return self.capture_with_swaygrab().await;
            }
        }

        // Fallback: try gnome-screenshot
        if let Ok(output) = Command::new("which").arg("gnome-screenshot").output() {
            if output.status.success() {
                return self.capture_with_gnome_screenshot().await;
            }
        }

        anyhow::bail!("No Wayland screenshot tool found. Please install grim.")
    }

    /// Capture using grim (recommended for COSMIC)
    async fn capture_with_grim(&self) -> Result<Screenshot> {
        let filename = self.generate_filename();
        let output_path = self.output_dir.join(&filename);

        let mut args = vec![output_path.to_string_lossy().to_string()];

        // Add monitor selection if needed
        if !self.config.all_monitors {
            // Get list of monitors and select first one
            if let Ok(output) = Command::new("grim").args(["-l"]).output() {
                let monitors = String::from_utf8_lossy(&output.stdout);
                if let Some(first_monitor) = monitors.lines().next() {
                    // Extract monitor name (format: "HDMI-A-1, 1920x1080, 0,0")
                    if let Some(monitor_name) = first_monitor.split(',').next() {
                        args.insert(1, monitor_name.to_string());
                    }
                }
            }
        }

        let output = Command::new("grim")
            .args(&args)
            .output()
            .context("Failed to execute grim")?;

        if !output.status.success() {
            anyhow::bail!("grim failed: {}", String::from_utf8_lossy(&output.stderr));
        }

        // Get image metadata
        let metadata = fs::metadata(&output_path).await?;
        let size_bytes = metadata.len();
        let timestamp = chrono::Local::now().to_rfc3339();

        // Try to get resolution using identify (ImageMagick)
        let (width, height) = self
            .get_image_resolution(&output_path)
            .await
            .unwrap_or((1920, 1080));

        Ok(Screenshot {
            filename: filename.clone(),
            path: output_path,
            width,
            height,
            format: self.config.format.clone(),
            size_bytes,
            timestamp,
            monitor: None,
        })
    }

    /// Capture using swaygrab
    async fn capture_with_swaygrab(&self) -> Result<Screenshot> {
        let filename = self.generate_filename();
        let output_path = self.output_dir.join(&filename);

        let output = Command::new("swaygrab")
            .arg("-o")
            .arg(&output_path)
            .output()
            .context("Failed to execute swaygrab")?;

        if !output.status.success() {
            anyhow::bail!(
                "swaygrab failed: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }

        let metadata = fs::metadata(&output_path).await?;
        let timestamp = chrono::Local::now().to_rfc3339();

        Ok(Screenshot {
            filename: filename.clone(),
            path: output_path,
            width: 1920,
            height: 1080,
            format: self.config.format.clone(),
            size_bytes: metadata.len(),
            timestamp,
            monitor: None,
        })
    }

    /// Capture using gnome-screenshot
    async fn capture_with_gnome_screenshot(&self) -> Result<Screenshot> {
        let filename = self.generate_filename();
        let output_path = self.output_dir.join(&filename);

        let output = Command::new("gnome-screenshot")
            .arg("-f")
            .arg(&output_path)
            .output()
            .context("Failed to execute gnome-screenshot")?;

        if !output.status.success() {
            anyhow::bail!("gnome-screenshot failed");
        }

        let metadata = fs::metadata(&output_path).await?;
        let timestamp = chrono::Local::now().to_rfc3339();

        Ok(Screenshot {
            filename: filename.clone(),
            path: output_path,
            width: 1920,
            height: 1080,
            format: self.config.format.clone(),
            size_bytes: metadata.len(),
            timestamp,
            monitor: None,
        })
    }

    /// Capture screenshot on X11
    async fn capture_x11(&self) -> Result<Screenshot> {
        // Try scrot (X11 screenshot tool)
        if let Ok(output) = Command::new("which").arg("scrot").output() {
            if output.status.success() {
                return self.capture_with_scrot().await;
            }
        }

        // Try maim (modern X11 screenshot tool)
        if let Ok(output) = Command::new("which").arg("maim").output() {
            if output.status.success() {
                return self.capture_with_maim().await;
            }
        }

        anyhow::bail!("No X11 screenshot tool found. Please install scrot or maim.")
    }

    /// Capture using scrot
    async fn capture_with_scrot(&self) -> Result<Screenshot> {
        let filename = self.generate_filename();
        let output_path = self.output_dir.join(&filename);

        let mut args = vec![];

        // Add resolution
        match &self.config.resolution {
            Resolution::Full => {}
            Resolution::Hd => args.push("--select=1920,0,1920,1080".to_string()),
            Resolution::Sd => args.push("--select=1280,0,1280,720".to_string()),
            Resolution::Custom { width, height } => {
                args.push(format!("--select=0,0,{},{}", width, height));
            }
        }

        args.push(output_path.to_str().unwrap().to_string());

        let output = Command::new("scrot")
            .args(&args)
            .output()
            .context("Failed to execute scrot")?;

        if !output.status.success() {
            anyhow::bail!("scrot failed: {}", String::from_utf8_lossy(&output.stderr));
        }

        let metadata = fs::metadata(&output_path).await?;
        let timestamp = chrono::Local::now().to_rfc3339();

        Ok(Screenshot {
            filename: filename.clone(),
            path: output_path,
            width: 1920,
            height: 1080,
            format: self.config.format.clone(),
            size_bytes: metadata.len(),
            timestamp,
            monitor: None,
        })
    }

    /// Capture using maim
    async fn capture_with_maim(&self) -> Result<Screenshot> {
        let filename = self.generate_filename();
        let output_path = self.output_dir.join(&filename);

        let mut args = vec![output_path.to_str().unwrap().to_string()];

        match &self.config.resolution {
            Resolution::Full => {}
            Resolution::Hd => args.extend(vec![
                "-g".to_string(),
                "1920x1080".to_string(),
                "-x".to_string(),
                "0".to_string(),
                "-y".to_string(),
                "0".to_string(),
            ]),
            Resolution::Sd => args.extend(vec![
                "-g".to_string(),
                "1280x720".to_string(),
                "-x".to_string(),
                "0".to_string(),
                "-y".to_string(),
                "0".to_string(),
            ]),
            Resolution::Custom { width, height } => {
                args.extend(vec![
                    "-g".to_string(),
                    format!("{}x{}", width, height),
                    "-x".to_string(),
                    "0".to_string(),
                    "-y".to_string(),
                    "0".to_string(),
                ]);
            }
        }

        let output = Command::new("maim")
            .args(&args)
            .output()
            .context("Failed to execute maim")?;

        if !output.status.success() {
            anyhow::bail!("maim failed: {}", String::from_utf8_lossy(&output.stderr));
        }

        let metadata = fs::metadata(&output_path).await?;
        let timestamp = chrono::Local::now().to_rfc3339();

        Ok(Screenshot {
            filename: filename.clone(),
            path: output_path,
            width: 1920,
            height: 1080,
            format: self.config.format.clone(),
            size_bytes: metadata.len(),
            timestamp,
            monitor: None,
        })
    }

    /// Get image resolution using identify
    async fn get_image_resolution(&self, path: &PathBuf) -> Result<(u32, u32)> {
        if let Ok(output) = Command::new("identify")
            .args(["-format", "%w %h", path.to_str().unwrap()])
            .output()
        {
            let stdout = String::from_utf8_lossy(&output.stdout);
            let parts: Vec<&str> = stdout.split_whitespace().collect();
            if parts.len() >= 2 {
                let width = parts[0].parse::<u32>().unwrap_or(1920);
                let height = parts[1].parse::<u32>().unwrap_or(1080);
                return Ok((width, height));
            }
        }
        Ok((1920, 1080))
    }

    /// Generate filename for screenshot
    fn generate_filename(&self) -> String {
        let timestamp = chrono::Local::now().format("%Y%m%d_%H%M%S");
        let ext = match self.config.format {
            CaptureFormat::Jpeg => "jpg",
            CaptureFormat::Png => "png",
            CaptureFormat::WebP => "webp",
        };
        format!("lifeos_screenshot_{}.{}", timestamp, ext)
    }

    /// Clean old screenshots
    pub async fn cleanup_old(&self, keep_days: u64) -> Result<u64> {
        let mut removed = 0u64;
        let threshold = chrono::Utc::now() - chrono::Duration::days(keep_days as i64);

        if !self.output_dir.exists() {
            return Ok(0);
        }

        let mut entries = fs::read_dir(&self.output_dir).await?;
        while let Some(entry) = entries
            .next_entry()
            .await
            .context("Failed to read directory entry")?
        {
            let path = entry.path();

            if path.is_file() {
                if let Ok(metadata) = fs::metadata(&path).await {
                    if let Ok(modified) = metadata.modified() {
                        let modified_datetime: chrono::DateTime<chrono::Utc> = modified.into();
                        if modified_datetime < threshold {
                            fs::remove_file(&path)
                                .await
                                .context("Failed to remove old screenshot")?;
                            removed += 1;
                            log::info!("Removed old screenshot: {}", path.display());
                        }
                    }
                }
            }
        }

        Ok(removed)
    }

    /// List all screenshots
    pub async fn list_screenshots(&self) -> Result<Vec<Screenshot>> {
        if !self.output_dir.exists() {
            return Ok(Vec::new());
        }

        let mut screenshots = Vec::new();
        let mut entries = fs::read_dir(&self.output_dir).await?;

        while let Some(entry) = entries
            .next_entry()
            .await
            .context("Failed to read directory entry")?
        {
            let path = entry.path();

            if path.is_file() {
                if let Some(filename) = path.file_name() {
                    if let Some(name) = filename.to_str() {
                        if name.starts_with("lifeos_screenshot_") {
                            if let Ok(metadata) = fs::metadata(&path).await {
                                let size_bytes = metadata.len();
                                let timestamp = if let Ok(modified) = metadata.modified() {
                                    let dt: chrono::DateTime<chrono::Utc> = modified.into();
                                    dt.to_rfc3339()
                                } else {
                                    "unknown".to_string()
                                };

                                let format = if name.ends_with(".png") {
                                    CaptureFormat::Png
                                } else if name.ends_with(".webp") {
                                    CaptureFormat::WebP
                                } else {
                                    CaptureFormat::Jpeg
                                };

                                let (width, height) = self
                                    .get_image_resolution(&path)
                                    .await
                                    .unwrap_or((1920, 1080));

                                screenshots.push(Screenshot {
                                    filename: name.to_string(),
                                    path,
                                    width,
                                    height,
                                    format,
                                    size_bytes,
                                    timestamp,
                                    monitor: None,
                                });
                            }
                        }
                    }
                }
            }
        }

        screenshots.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
        Ok(screenshots)
    }

    /// Delete specific screenshot
    pub async fn delete_screenshot(&self, filename: &str) -> Result<bool> {
        let path = self.output_dir.join(filename);

        if !path.exists() {
            return Ok(false);
        }

        fs::remove_file(&path)
            .await
            .context("Failed to delete screenshot")?;

        log::info!("Deleted screenshot: {}", filename);
        Ok(true)
    }
}

/// Display server type
#[derive(Debug, Clone, Copy)]
pub enum DisplayType {
    Wayland,
    X11,
    Unknown,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_filename() {
        let capture = ScreenCapture::new(PathBuf::from("/tmp"));
        let filename = capture.generate_filename();
        assert!(filename.starts_with("lifeos_screenshot_"));
        assert!(filename.ends_with(".jpg"));
    }

    #[test]
    fn test_capture_config_default() {
        let config = CaptureConfig::default();
        assert_eq!(config.quality, 85);
        assert!(matches!(config.format, CaptureFormat::Jpeg));
        assert!(config.all_monitors);
    }
}
