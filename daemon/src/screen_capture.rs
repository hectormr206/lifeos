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
use std::collections::HashMap;
use std::path::{Path, PathBuf};
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
#[derive(Clone)]
pub struct ScreenCapture {
    config: CaptureConfig,
    output_dir: PathBuf,
}

#[derive(Debug, Clone, Default)]
struct DisplayContext {
    run_as_user: Option<String>,
    wayland_display: Option<String>,
    x11_display: Option<String>,
    xdg_runtime_dir: Option<String>,
    dbus_session_bus_address: Option<String>,
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

        let display_context = self.active_display_context();

        // Detect display server type
        let display_type = self.detect_display_type(display_context.as_ref()).await?;
        log::debug!("Display type detected: {:?}", display_type);

        // Capture based on display type
        match display_type {
            DisplayType::Wayland => match self.capture_wayland(display_context.as_ref()).await {
                Ok(screenshot) => Ok(screenshot),
                Err(wayland_err) => {
                    log::warn!(
                        "Wayland capture failed, retrying with X11 tools: {}",
                        wayland_err
                    );
                    self.capture_x11(display_context.as_ref())
                        .await
                        .map_err(|x11_err| {
                        anyhow::anyhow!(
                            "Wayland capture failed: {}. X11 fallback failed: {}",
                            wayland_err,
                            x11_err
                        )
                        })
                }
            },
            DisplayType::X11 => match self.capture_x11(display_context.as_ref()).await {
                Ok(screenshot) => Ok(screenshot),
                Err(x11_err) => {
                    log::warn!(
                        "X11 capture failed, retrying with Wayland tools: {}",
                        x11_err
                    );
                    self.capture_wayland(display_context.as_ref())
                        .await
                        .map_err(|wayland_err| {
                        anyhow::anyhow!(
                            "X11 capture failed: {}. Wayland fallback failed: {}",
                            x11_err,
                            wayland_err
                        )
                        })
                }
            },
            DisplayType::Unknown => match self.capture_wayland(display_context.as_ref()).await {
                Ok(screenshot) => Ok(screenshot),
                Err(wayland_err) => self
                    .capture_x11(display_context.as_ref())
                    .await
                    .map_err(|x11_err| {
                    anyhow::anyhow!(
                        "Could not detect display type. Wayland capture failed: {}. X11 fallback failed: {}",
                        wayland_err,
                        x11_err
                    )
                    }),
            },
        }
    }

    /// Detect display server type
    async fn detect_display_type(&self, context: Option<&DisplayContext>) -> Result<DisplayType> {
        // Check for WAYLAND_DISPLAY env var
        if std::env::var("WAYLAND_DISPLAY")
            .ok()
            .filter(|value| !value.is_empty())
            .is_some()
        {
            return Ok(DisplayType::Wayland);
        }

        // Check for XDG_SESSION_TYPE
        if let Ok(session) = std::env::var("XDG_SESSION_TYPE") {
            if session.contains("wayland") {
                return Ok(DisplayType::Wayland);
            }
            if session.contains("x11") {
                return Ok(DisplayType::X11);
            }
        }

        // DISPLAY is a stronger X11 signal than session id in mixed Wayland/Xwayland sessions.
        if std::env::var("DISPLAY")
            .ok()
            .filter(|value| !value.is_empty())
            .is_some()
        {
            return Ok(DisplayType::X11);
        }

        if context
            .and_then(|ctx| ctx.wayland_display.as_ref())
            .is_some()
        {
            return Ok(DisplayType::Wayland);
        }

        if context.and_then(|ctx| ctx.x11_display.as_ref()).is_some() {
            return Ok(DisplayType::X11);
        }

        Ok(DisplayType::Unknown)
    }

    /// Capture screenshot on Wayland (COSMIC)
    async fn capture_wayland(&self, context: Option<&DisplayContext>) -> Result<Screenshot> {
        // Try grim (modern Wayland screenshot tool)
        if let Ok(output) = Command::new("which").arg("grim").output() {
            if output.status.success() {
                return self.capture_with_grim(context).await;
            }
        }

        // Try swaygrab for wlroots-based compositors
        if let Ok(output) = Command::new("which").arg("swaygrab").output() {
            if output.status.success() {
                return self.capture_with_swaygrab(context).await;
            }
        }

        // Fallback: try gnome-screenshot
        if let Ok(output) = Command::new("which").arg("gnome-screenshot").output() {
            if output.status.success() {
                return self.capture_with_gnome_screenshot(context).await;
            }
        }

        anyhow::bail!("No Wayland screenshot tool found. Please install grim.")
    }

    /// Capture using grim (recommended for COSMIC)
    async fn capture_with_grim(&self, context: Option<&DisplayContext>) -> Result<Screenshot> {
        let filename = self.generate_filename();
        let output_path = self.output_dir.join(&filename);
        let temp_path = self.capture_output_path(context, &filename);

        let mut args = vec![temp_path.to_string_lossy().to_string()];

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

        let output = self
            .command_for_display_context(context, "grim", &args)
            .output()
            .context("Failed to execute grim")?;

        if !output.status.success() {
            anyhow::bail!("grim failed: {}", String::from_utf8_lossy(&output.stderr));
        }

        self.finalize_capture_file(&temp_path, &output_path)
            .await
            .context("Failed to persist grim screenshot")?;

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
    async fn capture_with_swaygrab(&self, context: Option<&DisplayContext>) -> Result<Screenshot> {
        let filename = self.generate_filename();
        let output_path = self.output_dir.join(&filename);
        let temp_path = self.capture_output_path(context, &filename);

        let output = self
            .command_for_display_context(
                context,
                "swaygrab",
                &["-o".to_string(), temp_path.to_string_lossy().to_string()],
            )
            .output()
            .context("Failed to execute swaygrab")?;

        if !output.status.success() {
            anyhow::bail!(
                "swaygrab failed: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }

        self.finalize_capture_file(&temp_path, &output_path)
            .await
            .context("Failed to persist swaygrab screenshot")?;

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
    async fn capture_with_gnome_screenshot(
        &self,
        context: Option<&DisplayContext>,
    ) -> Result<Screenshot> {
        let filename = self.generate_filename();
        let output_path = self.output_dir.join(&filename);
        let temp_path = self.capture_output_path(context, &filename);

        let output = self
            .command_for_display_context(
                context,
                "gnome-screenshot",
                &["-f".to_string(), temp_path.to_string_lossy().to_string()],
            )
            .output()
            .context("Failed to execute gnome-screenshot")?;

        if !output.status.success() {
            anyhow::bail!(
                "gnome-screenshot failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }

        self.finalize_capture_file(&temp_path, &output_path)
            .await
            .context("Failed to persist gnome-screenshot capture")?;

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
    async fn capture_x11(&self, context: Option<&DisplayContext>) -> Result<Screenshot> {
        // Try scrot (X11 screenshot tool)
        if let Ok(output) = Command::new("which").arg("scrot").output() {
            if output.status.success() {
                return self.capture_with_scrot(context).await;
            }
        }

        // Try maim (modern X11 screenshot tool)
        if let Ok(output) = Command::new("which").arg("maim").output() {
            if output.status.success() {
                return self.capture_with_maim(context).await;
            }
        }

        // gnome-screenshot also works on many desktop sessions and is a useful fallback.
        if let Ok(output) = Command::new("which").arg("gnome-screenshot").output() {
            if output.status.success() {
                return self.capture_with_gnome_screenshot(context).await;
            }
        }

        anyhow::bail!(
            "No X11 screenshot tool found. Please install scrot, maim, or gnome-screenshot."
        )
    }

    /// Capture using scrot
    async fn capture_with_scrot(&self, context: Option<&DisplayContext>) -> Result<Screenshot> {
        let filename = self.generate_filename();
        let output_path = self.output_dir.join(&filename);
        let temp_path = self.capture_output_path(context, &filename);

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

        args.push(temp_path.to_string_lossy().to_string());

        let output = self
            .command_for_display_context(context, "scrot", &args)
            .output()
            .context("Failed to execute scrot")?;

        if !output.status.success() {
            anyhow::bail!("scrot failed: {}", String::from_utf8_lossy(&output.stderr));
        }

        self.finalize_capture_file(&temp_path, &output_path)
            .await
            .context("Failed to persist scrot screenshot")?;

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
    async fn capture_with_maim(&self, context: Option<&DisplayContext>) -> Result<Screenshot> {
        let filename = self.generate_filename();
        let output_path = self.output_dir.join(&filename);
        let temp_path = self.capture_output_path(context, &filename);

        let mut args = vec![temp_path.to_string_lossy().to_string()];

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

        let output = self
            .command_for_display_context(context, "maim", &args)
            .output()
            .context("Failed to execute maim")?;

        if !output.status.success() {
            anyhow::bail!("maim failed: {}", String::from_utf8_lossy(&output.stderr));
        }

        self.finalize_capture_file(&temp_path, &output_path)
            .await
            .context("Failed to persist maim screenshot")?;

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
    async fn get_image_resolution(&self, path: &Path) -> Result<(u32, u32)> {
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

    fn capture_output_path(&self, context: Option<&DisplayContext>, filename: &str) -> PathBuf {
        if let Some(context) = context {
            if context.run_as_user.is_some() {
                if let Some(runtime_dir) = &context.xdg_runtime_dir {
                    return PathBuf::from(runtime_dir).join(filename);
                }
                return PathBuf::from("/tmp").join(filename);
            }
        }

        self.output_dir.join(filename)
    }

    async fn finalize_capture_file(&self, source: &Path, dest: &Path) -> Result<()> {
        if source == dest {
            return Ok(());
        }

        let bytes = fs::read(source)
            .await
            .with_context(|| format!("Failed to read temporary capture {}", source.display()))?;
        fs::write(dest, bytes)
            .await
            .with_context(|| format!("Failed to write final capture {}", dest.display()))?;
        let _ = fs::remove_file(source).await;
        Ok(())
    }

    fn active_display_context(&self) -> Option<DisplayContext> {
        let sessions_output = Command::new("loginctl")
            .arg("list-sessions")
            .arg("--no-legend")
            .output()
            .ok()?;

        if !sessions_output.status.success() {
            return None;
        }

        let sessions = String::from_utf8_lossy(&sessions_output.stdout);
        for line in sessions.lines() {
            let Some(session_id) = line.split_whitespace().next() else {
                continue;
            };

            let props_output = Command::new("loginctl")
                .arg("show-session")
                .arg(session_id)
                .arg("-p")
                .arg("Active")
                .arg("-p")
                .arg("State")
                .arg("-p")
                .arg("Name")
                .arg("-p")
                .arg("Type")
                .arg("-p")
                .arg("Display")
                .arg("-p")
                .arg("Leader")
                .output()
                .ok()?;

            if !props_output.status.success() {
                continue;
            }

            let props = Self::parse_key_value_lines(&String::from_utf8_lossy(&props_output.stdout));
            if props.get("Active").map(String::as_str) != Some("yes") {
                continue;
            }

            let state = props.get("State").map(String::as_str).unwrap_or_default();
            if state != "active" && state != "online" {
                continue;
            }

            let user = props.get("Name").cloned().unwrap_or_default();
            if user.is_empty() || user == "root" {
                continue;
            }

            let leader_pid = props
                .get("Leader")
                .and_then(|value| value.parse::<u32>().ok())
                .unwrap_or(0);
            if leader_pid == 0 {
                continue;
            }

            let session_env = Self::read_proc_environ(leader_pid);
            let session_type = props.get("Type").map(String::as_str).unwrap_or_default();
            let display_prop = props.get("Display").cloned().unwrap_or_default();

            let wayland_display = session_env.get("WAYLAND_DISPLAY").cloned().or_else(|| {
                if session_type == "wayland" {
                    if !display_prop.is_empty() && !display_prop.starts_with(':') {
                        Some(display_prop.clone())
                    } else {
                        Some("wayland-0".to_string())
                    }
                } else {
                    None
                }
            });

            let x11_display = session_env.get("DISPLAY").cloned().or_else(|| {
                if !display_prop.is_empty() && display_prop.starts_with(':') {
                    Some(display_prop.clone())
                } else {
                    None
                }
            });

            if wayland_display.is_none() && x11_display.is_none() {
                continue;
            }

            let mut xdg_runtime_dir = session_env.get("XDG_RUNTIME_DIR").cloned();
            if xdg_runtime_dir.is_none() {
                if let Some(uid) = Self::lookup_user_uid(&user) {
                    xdg_runtime_dir = Some(format!("/run/user/{}", uid));
                }
            }

            let dbus_session_bus_address = session_env
                .get("DBUS_SESSION_BUS_ADDRESS")
                .cloned()
                .or_else(|| {
                    xdg_runtime_dir
                        .as_ref()
                        .map(|runtime| format!("unix:path={}/bus", runtime))
                });

            return Some(DisplayContext {
                run_as_user: Some(user),
                wayland_display,
                x11_display,
                xdg_runtime_dir,
                dbus_session_bus_address,
            });
        }

        None
    }

    fn lookup_user_uid(user: &str) -> Option<String> {
        let output = Command::new("id").arg("-u").arg(user).output().ok()?;
        if !output.status.success() {
            return None;
        }

        let uid = String::from_utf8_lossy(&output.stdout).trim().to_string();
        (!uid.is_empty()).then_some(uid)
    }

    fn parse_key_value_lines(raw: &str) -> HashMap<String, String> {
        raw.lines()
            .filter_map(|line| line.split_once('='))
            .map(|(key, value)| (key.trim().to_string(), value.trim().to_string()))
            .collect()
    }

    fn read_proc_environ(pid: u32) -> HashMap<String, String> {
        let path = format!("/proc/{}/environ", pid);
        let Ok(contents) = std::fs::read(path) else {
            return HashMap::new();
        };

        contents
            .split(|byte| *byte == 0)
            .filter_map(|entry| {
                if entry.is_empty() {
                    return None;
                }
                let pair = String::from_utf8_lossy(entry);
                pair.split_once('=')
                    .map(|(key, value)| (key.to_string(), value.to_string()))
            })
            .collect()
    }

    fn command_for_display_context(
        &self,
        context: Option<&DisplayContext>,
        program: &str,
        args: &[String],
    ) -> Command {
        if let Some(context) = context {
            if let Some(user) = &context.run_as_user {
                let mut cmd = Command::new("runuser");
                cmd.arg("-u").arg(user).arg("--").arg("env");
                if let Some(runtime) = &context.xdg_runtime_dir {
                    cmd.arg(format!("XDG_RUNTIME_DIR={}", runtime));
                }
                if let Some(display) = &context.wayland_display {
                    cmd.arg(format!("WAYLAND_DISPLAY={}", display));
                }
                if let Some(display) = &context.x11_display {
                    cmd.arg(format!("DISPLAY={}", display));
                }
                if let Some(bus) = &context.dbus_session_bus_address {
                    cmd.arg(format!("DBUS_SESSION_BUS_ADDRESS={}", bus));
                }
                cmd.arg(program);
                for arg in args {
                    cmd.arg(arg);
                }
                return cmd;
            }
        }

        let mut cmd = Command::new(program);
        if let Some(context) = context {
            if let Some(runtime) = &context.xdg_runtime_dir {
                cmd.env("XDG_RUNTIME_DIR", runtime);
            }
            if let Some(display) = &context.wayland_display {
                cmd.env("WAYLAND_DISPLAY", display);
            }
            if let Some(display) = &context.x11_display {
                cmd.env("DISPLAY", display);
            }
            if let Some(bus) = &context.dbus_session_bus_address {
                cmd.env("DBUS_SESSION_BUS_ADDRESS", bus);
            }
        }
        for arg in args {
            cmd.arg(arg);
        }
        cmd
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
