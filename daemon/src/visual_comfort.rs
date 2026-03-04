//! Visual Comfort Engine for LifeOS
//!
//! Provides:
//! - Color temperature adjustment (red shift at night)
//! - Adaptive typography scaling
//! - Contrast profiles by task type
//! - Smart animation reduction after long usage

use chrono::{DateTime, TimeZone, Timelike, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use tokio::process::Command;
use tokio::sync::RwLock;

const CONFIG_FILE: &str = "visual_comfort.toml";

#[derive(Debug, Clone, Default)]
struct DisplayContext {
    run_as_user: Option<String>,
    wayland_display: Option<String>,
    x11_display: Option<String>,
    xdg_runtime_dir: Option<String>,
    dbus_session_bus_address: Option<String>,
}

impl DisplayContext {
    fn has_wayland(&self) -> bool {
        self.wayland_display.is_some()
    }

    fn has_x11(&self) -> bool {
        self.x11_display.is_some()
    }

    fn is_headless(&self) -> bool {
        !self.has_wayland() && !self.has_x11()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VisualComfortConfig {
    pub color_temperature_day: u32,
    pub color_temperature_night: u32,
    pub night_start_hour: u8,
    pub night_end_hour: u8,
    pub font_scale_base: f32,
    pub font_scale_max: f32,
    pub animation_reduction_threshold_minutes: u32,
    pub transition_duration_secs: u32,
    pub enabled: bool,
}

impl Default for VisualComfortConfig {
    fn default() -> Self {
        Self {
            color_temperature_day: 6500,
            color_temperature_night: 3500,
            night_start_hour: 20,
            night_end_hour: 6,
            font_scale_base: 1.0,
            font_scale_max: 1.2,
            animation_reduction_threshold_minutes: 60,
            transition_duration_secs: 30,
            enabled: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ComfortProfile {
    Default,
    Coding,
    Reading,
    Design,
    Meeting,
}

impl ComfortProfile {
    pub fn as_str(&self) -> &'static str {
        match self {
            ComfortProfile::Default => "default",
            ComfortProfile::Coding => "coding",
            ComfortProfile::Reading => "reading",
            ComfortProfile::Design => "design",
            ComfortProfile::Meeting => "meeting",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "default" => Some(ComfortProfile::Default),
            "coding" => Some(ComfortProfile::Coding),
            "reading" => Some(ComfortProfile::Reading),
            "design" => Some(ComfortProfile::Design),
            "meeting" => Some(ComfortProfile::Meeting),
            _ => None,
        }
    }

    pub fn display_name(&self) -> &'static str {
        match self {
            ComfortProfile::Default => "Default",
            ComfortProfile::Coding => "Coding",
            ComfortProfile::Reading => "Reading",
            ComfortProfile::Design => "Design",
            ComfortProfile::Meeting => "Meeting",
        }
    }

    pub fn temperature(&self) -> u32 {
        match self {
            ComfortProfile::Coding => 6000,
            ComfortProfile::Reading => 4000,
            ComfortProfile::Design => 6500,
            ComfortProfile::Meeting => 4500,
            ComfortProfile::Default => 6500,
        }
    }

    pub fn font_scale(&self) -> f32 {
        match self {
            ComfortProfile::Coding => 0.95,
            ComfortProfile::Reading => 1.15,
            ComfortProfile::Design => 1.0,
            ComfortProfile::Meeting => 1.05,
            ComfortProfile::Default => 1.0,
        }
    }

    pub fn contrast_level(&self) -> f32 {
        match self {
            ComfortProfile::Coding => 1.2,
            ComfortProfile::Reading => 1.0,
            ComfortProfile::Design => 1.0,
            ComfortProfile::Meeting => 0.9,
            ComfortProfile::Default => 1.0,
        }
    }

    pub fn animations_enabled(&self) -> bool {
        match self {
            ComfortProfile::Coding => false,
            ComfortProfile::Reading => true,
            ComfortProfile::Design => true,
            ComfortProfile::Meeting => false,
            ComfortProfile::Default => true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VisualComfortState {
    pub current_temperature: u32,
    pub target_temperature: u32,
    pub current_font_scale: f32,
    pub target_font_scale: f32,
    pub animations_enabled: bool,
    pub active_profile: ComfortProfile,
    pub session_duration_minutes: u32,
    pub is_night_time: bool,
    pub transitioning: bool,
}

impl Default for VisualComfortState {
    fn default() -> Self {
        Self {
            current_temperature: 6500,
            target_temperature: 6500,
            current_font_scale: 1.0,
            target_font_scale: 1.0,
            animations_enabled: true,
            active_profile: ComfortProfile::Default,
            session_duration_minutes: 0,
            is_night_time: false,
            transitioning: false,
        }
    }
}

pub struct VisualComfortManager {
    config: RwLock<VisualComfortConfig>,
    state: RwLock<VisualComfortState>,
    session_start: RwLock<DateTime<Utc>>,
    data_dir: PathBuf,
}

impl VisualComfortManager {
    pub fn new(data_dir: PathBuf) -> Self {
        let config_path = data_dir.join(CONFIG_FILE);
        let config = if config_path.exists() {
            std::fs::read_to_string(&config_path)
                .ok()
                .and_then(|s| toml::from_str(&s).ok())
                .unwrap_or_default()
        } else {
            VisualComfortConfig::default()
        };

        let now = Utc::now();
        let is_night = Self::is_night_time(&config, &now);

        let initial_state = VisualComfortState {
            current_temperature: if is_night {
                config.color_temperature_night
            } else {
                config.color_temperature_day
            },
            target_temperature: if is_night {
                config.color_temperature_night
            } else {
                config.color_temperature_day
            },
            is_night_time: is_night,
            ..Default::default()
        };

        Self {
            config: RwLock::new(config),
            state: RwLock::new(initial_state),
            session_start: RwLock::new(now),
            data_dir,
        }
    }

    fn is_night_time(config: &VisualComfortConfig, now: &DateTime<Utc>) -> bool {
        let local = chrono::Local::from_utc_datetime(&chrono::Local, &now.naive_utc());
        let hour = local.hour() as u8;

        if config.night_start_hour > config.night_end_hour {
            hour >= config.night_start_hour || hour < config.night_end_hour
        } else {
            hour >= config.night_start_hour && hour < config.night_end_hour
        }
    }

    pub async fn initialize(&self) -> anyhow::Result<()> {
        self.update_time_based_settings().await?;
        self.save_config().await?;
        Ok(())
    }

    async fn save_config(&self) -> anyhow::Result<()> {
        let config = self.config.read().await;
        let config_path = self.data_dir.join(CONFIG_FILE);
        std::fs::create_dir_all(&self.data_dir)?;
        let content = toml::to_string_pretty(&*config)?;
        std::fs::write(&config_path, content)?;
        Ok(())
    }

    pub async fn get_state(&self) -> VisualComfortState {
        let mut state = self.state.write().await;
        let session_start = *self.session_start.read().await;
        let elapsed = (Utc::now() - session_start).num_minutes() as u32;
        state.session_duration_minutes = elapsed;
        state.clone()
    }

    pub async fn get_config(&self) -> VisualComfortConfig {
        self.config.read().await.clone()
    }

    pub async fn update_config(&self, new_config: VisualComfortConfig) -> anyhow::Result<()> {
        let mut config = self.config.write().await;
        *config = new_config;
        drop(config);
        self.save_config().await?;
        self.update_time_based_settings().await?;
        Ok(())
    }

    pub async fn set_profile(&self, profile: ComfortProfile) -> anyhow::Result<()> {
        let config = self.config.read().await;
        let mut state = self.state.write().await;

        let is_night = Self::is_night_time(&config, &Utc::now());

        let base_temp = if is_night {
            config.color_temperature_night
        } else {
            config.color_temperature_day
        };

        let profile_temp = profile.temperature();
        let target_temp = if is_night {
            profile_temp.min(base_temp)
        } else {
            profile_temp
        };

        state.target_temperature = target_temp;
        state.target_font_scale = profile.font_scale().min(config.font_scale_max);
        state.animations_enabled = profile.animations_enabled();
        state.active_profile = profile.clone();
        state.transitioning = true;

        drop(state);
        drop(config);

        self.apply_temperature(target_temp).await?;
        self.apply_font_scale(profile.font_scale()).await?;
        self.apply_animation_state(profile.animations_enabled()).await?;

        let mut state = self.state.write().await;
        state.current_temperature = target_temp;
        state.current_font_scale = profile.font_scale();
        state.transitioning = false;

        Ok(())
    }

    pub async fn set_temperature(&self, temperature: u32) -> anyhow::Result<()> {
        let temp = temperature.clamp(2500, 6500);

        {
            let mut state = self.state.write().await;
            state.target_temperature = temp;
            state.transitioning = true;
        }

        self.apply_temperature(temp).await?;

        let mut state = self.state.write().await;
        state.current_temperature = temp;
        state.transitioning = false;

        Ok(())
    }

    pub async fn set_font_scale(&self, scale: f32) -> anyhow::Result<()> {
        let config = self.config.read().await;
        let scale = scale.clamp(0.8, config.font_scale_max);
        drop(config);

        {
            let mut state = self.state.write().await;
            state.target_font_scale = scale;
        }

        self.apply_font_scale(scale).await?;

        let mut state = self.state.write().await;
        state.current_font_scale = scale;

        Ok(())
    }

    pub async fn set_animations(&self, enabled: bool) -> anyhow::Result<()> {
        {
            let mut state = self.state.write().await;
            state.animations_enabled = enabled;
        }

        self.apply_animation_state(enabled).await?;
        Ok(())
    }

    async fn apply_temperature(&self, temperature: u32) -> anyhow::Result<()> {
        let context = self.resolve_display_context().await;

        if context.has_wayland() {
            if let Err(e) = self.apply_wlsunset(temperature, &context).await {
                log::warn!("wlsunset failed, trying gammastep: {}", e);
                self.apply_gammastep(temperature, &context).await?;
            }
        } else if context.has_x11() {
            self.apply_gammastep(temperature, &context).await?;
        } else {
            log::info!("Headless environment, skipping color temperature adjustment");
        }

        Ok(())
    }

    async fn resolve_display_context(&self) -> DisplayContext {
        let local_context = DisplayContext {
            run_as_user: None,
            wayland_display: std::env::var("WAYLAND_DISPLAY").ok(),
            x11_display: std::env::var("DISPLAY").ok(),
            xdg_runtime_dir: std::env::var("XDG_RUNTIME_DIR").ok(),
            dbus_session_bus_address: std::env::var("DBUS_SESSION_BUS_ADDRESS").ok(),
        };

        if !local_context.is_headless() {
            return local_context;
        }

        if let Some(session_context) = Self::detect_active_session_context().await {
            if let Some(user) = &session_context.run_as_user {
                log::info!(
                    "Visual comfort using active graphical session context for user '{}'",
                    user
                );
            }
            return session_context;
        }

        local_context
    }

    async fn detect_active_session_context() -> Option<DisplayContext> {
        let sessions_output = Command::new("loginctl")
            .arg("list-sessions")
            .arg("--no-legend")
            .output()
            .await
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
                .await
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
                if let Some(uid) = Self::lookup_user_uid(&user).await {
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

    async fn lookup_user_uid(user: &str) -> Option<String> {
        let output = Command::new("id")
            .arg("-u")
            .arg(user)
            .output()
            .await
            .ok()?;

        if !output.status.success() {
            return None;
        }

        let uid = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if uid.is_empty() {
            None
        } else {
            Some(uid)
        }
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
                    .map(|(k, v)| (k.to_string(), v.to_string()))
            })
            .collect()
    }

    fn command_for_context(context: &DisplayContext, program: &str, args: &[String]) -> Command {
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

            cmd
        } else {
            let mut cmd = Command::new(program);

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

            for arg in args {
                cmd.arg(arg);
            }

            cmd
        }
    }

    async fn kill_existing_color_tool(process_name: &str, context: &DisplayContext) {
        let mut cmd = Command::new("pkill");
        if let Some(user) = &context.run_as_user {
            cmd.arg("-u").arg(user);
        }
        cmd.arg("-f").arg(process_name);
        let _ = cmd.output().await;
    }

    async fn apply_wlsunset(&self, temperature: u32, context: &DisplayContext) -> anyhow::Result<()> {
        Self::kill_existing_color_tool("wlsunset", context).await;

        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

        let args = vec![
            "-t".to_string(),
            temperature.to_string(),
            "-T".to_string(),
            temperature.to_string(),
        ];

        let mut command = Self::command_for_context(context, "wlsunset", &args);
        command.stdin(Stdio::null());
        command.stdout(Stdio::null());
        command.stderr(Stdio::null());

        match command.spawn() {
            Ok(_) => {
                log::info!("Applied color temperature {}K via wlsunset", temperature);
                Ok(())
            }
            Err(e) => anyhow::bail!("Failed to execute wlsunset: {}", e),
        }
    }

    async fn apply_gammastep(
        &self,
        temperature: u32,
        context: &DisplayContext,
    ) -> anyhow::Result<()> {
        Self::kill_existing_color_tool("gammastep", context).await;

        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

        let args = vec!["-O".to_string(), temperature.to_string()];
        let output = Self::command_for_context(context, "gammastep", &args)
            .output()
            .await;

        match output {
            Ok(o) if o.status.success() => {
                log::info!("Applied color temperature {}K via gammastep", temperature);
                Ok(())
            }
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr);
                anyhow::bail!("gammastep failed: {}", stderr)
            }
            Err(e) => anyhow::bail!("Failed to execute gammastep: {}", e),
        }
    }

    async fn apply_font_scale(&self, scale: f32) -> anyhow::Result<()> {
        let scale_percent = (scale * 100.0) as u32;

        if let Err(e) = self.apply_cosmic_font_scale(scale_percent).await {
            log::debug!("COSMIC font scale failed: {}, trying env var fallback", e);
        }

        std::env::set_var("LIFEOS_FONT_SCALE", scale.to_string());
        std::env::set_var("GDK_SCALE", scale.ceil().to_string());
        std::env::set_var("QT_SCALE_FACTOR", scale.to_string());

        log::info!("Applied font scale {:.2}", scale);
        Ok(())
    }

    async fn apply_cosmic_font_scale(&self, scale_percent: u32) -> anyhow::Result<()> {
        let cosmic_config_path = std::env::var("XDG_CONFIG_HOME")
            .unwrap_or_else(|_| format!("{}/.config", std::env::var("HOME").unwrap_or_default()));
        
        let settings_path = format!("{}/cosmic/com.system.settings/Font", cosmic_config_path);
        
        std::fs::create_dir_all(std::path::Path::new(&settings_path).parent().unwrap())?;
        
        let settings = serde_json::json!({
            "scale": scale_percent,
        });
        
        std::fs::write(&settings_path, serde_json::to_string_pretty(&settings)?)?;
        
        log::info!("Applied COSMIC font scale {}%", scale_percent);
        Ok(())
    }

    async fn apply_animation_state(&self, enabled: bool) -> anyhow::Result<()> {
        if !enabled {
            std::env::set_var("GTK_MODULES", "gtk3-nocsd");
            std::env::set_var("LIFEOS_ANIMATIONS", "disabled");
            std::env::set_var("QT_QPA_PLATFORM", "xcb:no-composite");
        } else {
            std::env::remove_var("GTK_MODULES");
            std::env::set_var("LIFEOS_ANIMATIONS", "enabled");
        }

        if let Err(e) = self.apply_cosmic_animation_state(enabled).await {
            log::debug!("COSMIC animation control failed: {}", e);
        }

        log::info!("Applied animation state: {}", if enabled { "enabled" } else { "disabled" });
        Ok(())
    }

    async fn apply_cosmic_animation_state(&self, enabled: bool) -> anyhow::Result<()> {
        let cosmic_config_path = std::env::var("XDG_CONFIG_HOME")
            .unwrap_or_else(|_| format!("{}/.config", std::env::var("HOME").unwrap_or_default()));
        
        let settings_path = format!("{}/cosmic/com.system.settings/Animations", cosmic_config_path);
        
        std::fs::create_dir_all(std::path::Path::new(&settings_path).parent().unwrap())?;
        
        let settings = serde_json::json!({
            "enabled": enabled,
        });
        
        std::fs::write(&settings_path, serde_json::to_string_pretty(&settings)?)?;
        
        Ok(())
    }

    pub async fn update_time_based_settings(&self) -> anyhow::Result<()> {
        let config = self.config.read().await;
        
        if !config.enabled {
            return Ok(());
        }

        let now = Utc::now();
        let is_night = Self::is_night_time(&config, &now);

        {
            let mut state = self.state.write().await;
            if state.is_night_time != is_night {
                state.is_night_time = is_night;
                
                let target_temp = if is_night {
                    config.color_temperature_night
                } else {
                    config.color_temperature_day
                };
                
                state.target_temperature = target_temp;
                state.transitioning = true;
                
                drop(state);
                
                self.apply_temperature(target_temp).await?;
                
                let mut state = self.state.write().await;
                state.current_temperature = target_temp;
                state.transitioning = false;
            }
        }

        self.check_animation_reduction().await?;

        Ok(())
    }

    async fn check_animation_reduction(&self) -> anyhow::Result<()> {
        let config = self.config.read().await;
        let state = self.state.read().await;
        
        if state.session_duration_minutes >= config.animation_reduction_threshold_minutes
            && state.animations_enabled
            && state.active_profile == ComfortProfile::Default
        {
            drop(state);

            let mut state = self.state.write().await;
            state.animations_enabled = false;
            drop(state);

            self.apply_animation_state(false).await?;
            log::info!(
                "Reduced animations after {} minutes of usage",
                config.animation_reduction_threshold_minutes
            );
        }

        Ok(())
    }

    pub async fn reset_session(&self) -> anyhow::Result<()> {
        let now = Utc::now();
        
        {
            let mut session_start = self.session_start.write().await;
            *session_start = now;
        }
        
        {
            let mut state = self.state.write().await;
            state.session_duration_minutes = 0;
            state.animations_enabled = true;
        }
        
        self.update_time_based_settings().await?;
        
        log::info!("Visual comfort session reset");
        Ok(())
    }
}
