//! Gaming Agent — Axi can observe and eventually play games autonomously.
//!
//! This is the long-term vision (Fase P). Current implementation provides:
//! - Screen capture at configurable FPS for game observation
//! - Vision model analysis of game state
//! - Basic input generation via ydotool (gamepad/keyboard)
//!
//! Future: integrate with NitroGen-style models for real-time game control.
//! Reference: NVIDIA NitroGen (github.com/MineDojo/NitroGen),
//!            Google DeepMind SIMA 2 (arxiv.org/abs/2512.04797)

use anyhow::{Context, Result};
use log::{info, warn};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::process::Command;

// ---------------------------------------------------------------------------
// uinput constants for virtual gamepad
// ---------------------------------------------------------------------------

/// ioctl request codes for /dev/uinput (Linux x86_64).
const UINPUT_IOCTL_BASE: u8 = b'U';

/// UI_SET_EVBIT = _IOW('U', 100, int)
const UI_SET_EVBIT: libc::c_ulong = 0x4004_5564;
/// UI_SET_KEYBIT = _IOW('U', 101, int)
const UI_SET_KEYBIT: libc::c_ulong = 0x4004_5565;
/// UI_SET_ABSBIT = _IOW('U', 103, int)
const UI_SET_ABSBIT: libc::c_ulong = 0x4004_5567;
/// UI_DEV_CREATE = _IO('U', 1)
const UI_DEV_CREATE: libc::c_ulong = 0x5501;
/// UI_DEV_DESTROY = _IO('U', 2)
const UI_DEV_DESTROY: libc::c_ulong = 0x5502;

// Event types
const EV_SYN: u16 = 0x00;
const EV_KEY: u16 = 0x01;
const EV_ABS: u16 = 0x03;

// Gamepad button codes (BTN_GAMEPAD range)
const BTN_A: u16 = 0x130;
const BTN_B: u16 = 0x131;
const BTN_X: u16 = 0x133;
const BTN_Y: u16 = 0x134;
const BTN_TL: u16 = 0x136; // LB
const BTN_TR: u16 = 0x137; // RB
const BTN_TL2: u16 = 0x138; // LT
const BTN_TR2: u16 = 0x139; // RT
const BTN_START: u16 = 0x13b;
const BTN_SELECT: u16 = 0x13a;
const BTN_DPAD_UP: u16 = 0x220;
const BTN_DPAD_DOWN: u16 = 0x221;
const BTN_DPAD_LEFT: u16 = 0x222;
const BTN_DPAD_RIGHT: u16 = 0x223;

// Absolute axis codes
const ABS_X: u16 = 0x00;
const ABS_Y: u16 = 0x01;
const ABS_RX: u16 = 0x03;
const ABS_RY: u16 = 0x04;

// ---------------------------------------------------------------------------
// GameStateAnalysis — structured output from vision analysis
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GameStateAnalysis {
    pub health_percent: Option<f32>,
    pub ammo: Option<String>,
    pub objective: Option<String>,
    pub enemies_visible: u32,
    pub location: Option<String>,
    /// One of: low, medium, high, critical
    pub danger_level: String,
    /// The raw text returned by the LLM before parsing.
    pub raw_analysis: String,
}

impl Default for GameStateAnalysis {
    fn default() -> Self {
        Self {
            health_percent: None,
            ammo: None,
            objective: None,
            enemies_visible: 0,
            location: None,
            danger_level: "low".into(),
            raw_analysis: String::new(),
        }
    }
}

// ---------------------------------------------------------------------------
// GamepadButton / Stick enums
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum GamepadButton {
    A,
    B,
    X,
    Y,
    LB,
    RB,
    LT,
    RT,
    Start,
    Select,
    DpadUp,
    DpadDown,
    DpadLeft,
    DpadRight,
}

impl GamepadButton {
    /// Map to Linux BTN_* code.
    fn code(self) -> u16 {
        match self {
            Self::A => BTN_A,
            Self::B => BTN_B,
            Self::X => BTN_X,
            Self::Y => BTN_Y,
            Self::LB => BTN_TL,
            Self::RB => BTN_TR,
            Self::LT => BTN_TL2,
            Self::RT => BTN_TR2,
            Self::Start => BTN_START,
            Self::Select => BTN_SELECT,
            Self::DpadUp => BTN_DPAD_UP,
            Self::DpadDown => BTN_DPAD_DOWN,
            Self::DpadLeft => BTN_DPAD_LEFT,
            Self::DpadRight => BTN_DPAD_RIGHT,
        }
    }

    /// Fallback keyboard key name for ydotool when uinput is unavailable.
    fn ydotool_key(self) -> &'static str {
        match self {
            Self::A => "space",
            Self::B => "e",
            Self::X => "r",
            Self::Y => "f",
            Self::LB => "q",
            Self::RB => "tab",
            Self::LT => "z",
            Self::RT => "c",
            Self::Start => "escape",
            Self::Select => "m",
            Self::DpadUp => "up",
            Self::DpadDown => "down",
            Self::DpadLeft => "left",
            Self::DpadRight => "right",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Stick {
    Left,
    Right,
}

// ---------------------------------------------------------------------------
// VirtualGamepad — Linux uinput gamepad with ydotool fallback
// ---------------------------------------------------------------------------

pub struct VirtualGamepad {
    /// File descriptor for /dev/uinput, or None if using ydotool fallback.
    fd: Option<i32>,
}

impl VirtualGamepad {
    pub fn new() -> Result<Self, String> {
        match Self::try_uinput() {
            Ok(fd) => {
                info!("[gaming] Virtual gamepad created via uinput (fd={})", fd);
                Ok(Self { fd: Some(fd) })
            }
            Err(e) => {
                warn!(
                    "[gaming] uinput unavailable ({}), falling back to ydotool keyboard mapping",
                    e
                );
                Ok(Self { fd: None })
            }
        }
    }

    /// Attempt to open /dev/uinput and configure a virtual gamepad device.
    fn try_uinput() -> Result<i32, String> {
        use std::ffi::CString;
        use std::os::unix::io::RawFd;

        let path = CString::new("/dev/uinput").unwrap();
        let fd: RawFd = unsafe { libc::open(path.as_ptr(), libc::O_WRONLY | libc::O_NONBLOCK) };
        if fd < 0 {
            return Err(format!(
                "cannot open /dev/uinput: errno {}",
                std::io::Error::last_os_error()
            ));
        }

        // Helper for ioctl calls
        macro_rules! uinput_ioctl {
            ($req:expr, $val:expr) => {
                if unsafe { libc::ioctl(fd, $req, $val as libc::c_int) } < 0 {
                    let err = std::io::Error::last_os_error();
                    unsafe { libc::close(fd) };
                    return Err(format!("ioctl {:#x} failed: {}", $req, err));
                }
            };
        }

        // Enable event types
        uinput_ioctl!(UI_SET_EVBIT, EV_KEY);
        uinput_ioctl!(UI_SET_EVBIT, EV_ABS);
        uinput_ioctl!(UI_SET_EVBIT, EV_SYN);

        // Register buttons
        let buttons: &[u16] = &[
            BTN_A,
            BTN_B,
            BTN_X,
            BTN_Y,
            BTN_TL,
            BTN_TR,
            BTN_TL2,
            BTN_TR2,
            BTN_START,
            BTN_SELECT,
            BTN_DPAD_UP,
            BTN_DPAD_DOWN,
            BTN_DPAD_LEFT,
            BTN_DPAD_RIGHT,
        ];
        for &btn in buttons {
            uinput_ioctl!(UI_SET_KEYBIT, btn);
        }

        // Register axes
        let axes: &[u16] = &[ABS_X, ABS_Y, ABS_RX, ABS_RY];
        for &axis in axes {
            uinput_ioctl!(UI_SET_ABSBIT, axis);
        }

        // Write uinput_user_dev struct (legacy interface — 80-byte name + id + ff + absmax/min/fuzz/flat arrays)
        // Total size: 80 (name) + 8 (id: bustype+vendor+product+version) + 4 (ff_effects_max)
        //           + 4*64*4 (abs arrays) = 80 + 8 + 4 + 1024 = 1116 bytes
        let mut user_dev = vec![0u8; 1116];
        let name = b"LifeOS Virtual Gamepad";
        user_dev[..name.len()].copy_from_slice(name);

        // bustype = BUS_VIRTUAL (0x06), vendor = 0x1234, product = 0x5678, version = 1
        user_dev[80] = 0x06;
        user_dev[81] = 0x00;
        user_dev[82] = 0x34;
        user_dev[83] = 0x12;
        user_dev[84] = 0x78;
        user_dev[85] = 0x56;
        user_dev[86] = 0x01;
        user_dev[87] = 0x00;

        // Set abs range for each axis: absmax[axis] = 32767, absmin[axis] = -32768
        // absmax starts at offset 92 (80+8+4), absmin at 92+64*4=92+256=348
        let absmax_off = 92;
        let absmin_off = absmax_off + 64 * 4;
        for &axis in axes {
            let idx = axis as usize;
            // absmax[idx] = 32767 (0x7FFF) as i32 LE
            let max_off = absmax_off + idx * 4;
            let max_bytes = 32767i32.to_le_bytes();
            user_dev[max_off..max_off + 4].copy_from_slice(&max_bytes);
            // absmin[idx] = -32768 as i32 LE
            let min_off = absmin_off + idx * 4;
            let min_bytes = (-32768i32).to_le_bytes();
            user_dev[min_off..min_off + 4].copy_from_slice(&min_bytes);
        }

        let written =
            unsafe { libc::write(fd, user_dev.as_ptr() as *const libc::c_void, user_dev.len()) };
        if written < 0 {
            let err = std::io::Error::last_os_error();
            unsafe { libc::close(fd) };
            return Err(format!("write uinput_user_dev failed: {}", err));
        }

        // Create the device
        if unsafe { libc::ioctl(fd, UI_DEV_CREATE, 0) } < 0 {
            let err = std::io::Error::last_os_error();
            unsafe { libc::close(fd) };
            return Err(format!("UI_DEV_CREATE failed: {}", err));
        }

        Ok(fd)
    }

    /// Write a raw input_event to the uinput fd.
    fn write_event(&self, ev_type: u16, code: u16, value: i32) -> Result<(), String> {
        let fd = self.fd.ok_or_else(|| "uinput not available".to_string())?;

        // struct input_event: timeval (16 bytes on 64-bit), type (u16), code (u16), value (i32)
        // Total: 24 bytes on 64-bit Linux
        let mut buf = [0u8; 24];
        // timeval left as zero (kernel fills it)
        buf[16..18].copy_from_slice(&ev_type.to_le_bytes());
        buf[18..20].copy_from_slice(&code.to_le_bytes());
        buf[20..24].copy_from_slice(&value.to_le_bytes());

        let written = unsafe { libc::write(fd, buf.as_ptr() as *const libc::c_void, buf.len()) };
        if written < 0 {
            return Err(format!(
                "write input_event failed: {}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(())
    }

    /// Emit a SYN_REPORT to flush pending events.
    fn sync(&self) -> Result<(), String> {
        self.write_event(EV_SYN, 0, 0)
    }

    pub fn press_button(&self, button: GamepadButton) -> Result<(), String> {
        if self.fd.is_some() {
            self.write_event(EV_KEY, button.code(), 1)?;
            self.sync()
        } else {
            // ydotool fallback — key down
            std::process::Command::new("ydotool")
                .args(["key", &format!("{}:1", button.ydotool_key())])
                .output()
                .map_err(|e| format!("ydotool press failed: {}", e))?;
            Ok(())
        }
    }

    pub fn release_button(&self, button: GamepadButton) -> Result<(), String> {
        if self.fd.is_some() {
            self.write_event(EV_KEY, button.code(), 0)?;
            self.sync()
        } else {
            std::process::Command::new("ydotool")
                .args(["key", &format!("{}:0", button.ydotool_key())])
                .output()
                .map_err(|e| format!("ydotool release failed: {}", e))?;
            Ok(())
        }
    }

    pub fn move_stick(&self, stick: Stick, x: i16, y: i16) -> Result<(), String> {
        if self.fd.is_some() {
            let (ax, ay) = match stick {
                Stick::Left => (ABS_X, ABS_Y),
                Stick::Right => (ABS_RX, ABS_RY),
            };
            self.write_event(EV_ABS, ax, x as i32)?;
            self.write_event(EV_ABS, ay, y as i32)?;
            self.sync()
        } else {
            // ydotool fallback: map stick to WASD / arrow keys with threshold
            let threshold = 8000i16;
            let keys: &[(&str, bool)] = match stick {
                Stick::Left => &[
                    ("w", y < -threshold),
                    ("s", y > threshold),
                    ("a", x < -threshold),
                    ("d", x > threshold),
                ],
                Stick::Right => &[
                    ("up", y < -threshold),
                    ("down", y > threshold),
                    ("left", x < -threshold),
                    ("right", x > threshold),
                ],
            };
            for &(key, active) in keys {
                if active {
                    std::process::Command::new("ydotool")
                        .args(["key", &format!("{}:1", key)])
                        .output()
                        .map_err(|e| format!("ydotool stick failed: {}", e))?;
                }
            }
            Ok(())
        }
    }

    pub fn close(self) -> Result<(), String> {
        if let Some(fd) = self.fd {
            unsafe {
                libc::ioctl(fd, UI_DEV_DESTROY, 0);
                libc::close(fd);
            }
            info!("[gaming] Virtual gamepad destroyed");
        }
        Ok(())
    }
}

impl Drop for VirtualGamepad {
    fn drop(&mut self) {
        if let Some(fd) = self.fd.take() {
            unsafe {
                libc::ioctl(fd, UI_DEV_DESTROY, 0);
                libc::close(fd);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Core data types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GameObservation {
    pub frame_path: String,
    pub timestamp: String,
    pub analysis: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GamingAgentState {
    pub observing: bool,
    pub playing: bool,
    pub game_name: Option<String>,
    pub frames_captured: u64,
    pub fps: u32,
}

impl Default for GamingAgentState {
    fn default() -> Self {
        Self {
            observing: false,
            playing: false,
            game_name: None,
            frames_captured: 0,
            fps: 2, // 2 FPS for observation mode (saves resources)
        }
    }
}

pub struct GamingAgent {
    data_dir: PathBuf,
    state: GamingAgentState,
    /// When true, blocks autonomous play in online/competitive game modes.
    safety_online_play: bool,
}

impl GamingAgent {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            data_dir,
            state: GamingAgentState::default(),
            safety_online_play: false,
        }
    }

    pub fn state(&self) -> &GamingAgentState {
        &self.state
    }

    /// Start observing a game — captures frames at low FPS for analysis.
    pub async fn start_observing(&mut self, game_name: &str) -> Result<()> {
        info!("[gaming] Starting observation of: {}", game_name);
        self.state.observing = true;
        self.state.game_name = Some(game_name.to_string());
        self.state.frames_captured = 0;
        Ok(())
    }

    /// Capture a single frame of the current screen.
    pub async fn capture_frame(&mut self) -> Result<GameObservation> {
        let frames_dir = self.data_dir.join("game_frames");
        tokio::fs::create_dir_all(&frames_dir).await?;

        let frame_path = frames_dir.join(format!(
            "frame-{}.png",
            chrono::Utc::now().format("%Y%m%d-%H%M%S-%3f")
        ));

        // Use grim for Wayland screenshot
        let result = Command::new("grim")
            .arg(frame_path.to_str().unwrap_or("frame.png"))
            .output()
            .await;

        match result {
            Ok(o) if o.status.success() => {
                self.state.frames_captured += 1;
                Ok(GameObservation {
                    frame_path: frame_path.to_string_lossy().to_string(),
                    timestamp: chrono::Utc::now().to_rfc3339(),
                    analysis: None,
                })
            }
            _ => anyhow::bail!("Failed to capture game frame"),
        }
    }

    /// Send a keyboard input to the game.
    pub async fn send_key(&self, key: &str) -> Result<()> {
        Command::new("ydotool")
            .args(["key", key])
            .output()
            .await
            .context("Failed to send key to game")?;
        Ok(())
    }

    /// Send a mouse click at coordinates.
    pub async fn click(&self, x: i32, y: i32) -> Result<()> {
        Command::new("ydotool")
            .args(["mousemove", "--absolute", &x.to_string(), &y.to_string()])
            .output()
            .await
            .context("Failed to move mouse")?;

        Command::new("ydotool")
            .args(["click", "0x00"])
            .output()
            .await
            .context("Failed to click")?;

        Ok(())
    }

    /// Whether autonomous play is blocked for online/competitive modes.
    pub fn safety_online_play(&self) -> bool {
        self.safety_online_play
    }

    pub fn set_safety_online_play(&mut self, enabled: bool) {
        self.safety_online_play = enabled;
        info!(
            "[gaming] safety_online_play set to {}",
            if enabled {
                "ON (autonomous play blocked in online modes)"
            } else {
                "OFF"
            }
        );
    }

    /// Send captured frame paths + game name to the LLM and return a session summary.
    ///
    /// Example output: "Played RE9 Chapter 3, defeated 2 bosses"
    pub async fn tag_session(
        &self,
        router: &std::sync::Arc<tokio::sync::RwLock<crate::llm_router::LlmRouter>>,
        game_name: &str,
        frames_captured: u64,
        duration_secs: u64,
    ) -> Result<String> {
        let prompt = format!(
            "You are a gaming session tagger. Summarize this gaming session in ONE short sentence.\n\n\
             Game: {}\n\
             Frames captured: {}\n\
             Duration: {} seconds ({:.1} minutes)\n\n\
             Based on the game name and session length, generate a plausible summary like:\n\
             \"Played RE9 Chapter 3, defeated 2 bosses\"\n\
             \"Explored Hyrule Field for 45 minutes, found 3 Korok seeds\"\n\n\
             Respond with ONLY the summary sentence, nothing else.",
            game_name,
            frames_captured,
            duration_secs,
            duration_secs as f64 / 60.0,
        );

        let request = crate::llm_router::RouterRequest {
            messages: vec![crate::llm_router::ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(prompt),
            }],
            complexity: Some(crate::llm_router::TaskComplexity::Simple),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(128),
        };

        let router_guard = router.read().await;
        let response = router_guard
            .chat(&request)
            .await
            .context("LLM session tagging failed")?;

        let summary = response.text.trim().to_string();
        info!("[gaming] Session tagged: {}", summary);
        Ok(summary)
    }

    // -----------------------------------------------------------------------
    // Visual Game State Understanding
    // -----------------------------------------------------------------------

    /// Analyze a game screenshot via LLM vision to extract structured game state.
    pub async fn analyze_game_state(
        &self,
        frame_path: &str,
        game_name: &str,
        router: &crate::llm_router::LlmRouter,
    ) -> Result<GameStateAnalysis, String> {
        // Read the frame as base64 for vision input
        let frame_bytes = tokio::fs::read(frame_path)
            .await
            .map_err(|e| format!("Failed to read frame {}: {}", frame_path, e))?;
        let frame_b64 = base64_encode(&frame_bytes);

        let prompt = format!(
            "Analyze this game screenshot from '{}'. Extract: health/HP percentage, \
             ammo count, current objective, number of visible enemies, location/area name, \
             danger level (low/medium/high/critical). Return JSON format.",
            game_name
        );

        // Build a multimodal message with image_url content part
        let content = serde_json::json!([
            {
                "type": "image_url",
                "image_url": {
                    "url": format!("data:image/png;base64,{}", frame_b64)
                }
            },
            {
                "type": "text",
                "text": prompt
            }
        ]);

        let request = crate::llm_router::RouterRequest {
            messages: vec![crate::llm_router::ChatMessage {
                role: "user".into(),
                content,
            }],
            complexity: Some(crate::llm_router::TaskComplexity::Vision),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(512),
        };

        let response = router
            .chat(&request)
            .await
            .map_err(|e| format!("LLM vision analysis failed: {}", e))?;

        let raw = response.text.trim().to_string();
        info!(
            "[gaming] Game state analysis: {}",
            &raw[..raw.len().min(200)]
        );

        // Try to parse the LLM JSON response; fall back gracefully.
        let analysis = parse_game_state_json(&raw);
        Ok(analysis)
    }

    // -----------------------------------------------------------------------
    // Real-Time Suggestions
    // -----------------------------------------------------------------------

    /// Generate a brief tactical suggestion based on the current game state.
    pub async fn get_suggestion(
        &self,
        game_state: &GameStateAnalysis,
        game_name: &str,
        router: &crate::llm_router::LlmRouter,
    ) -> Result<String, String> {
        let state_json = serde_json::to_string(game_state).unwrap_or_else(|_| "{}".to_string());

        let prompt = format!(
            "You are a real-time gaming coach for '{}'. Based on the following game state, \
             give ONE brief tactical suggestion (max 15 words). Be specific and actionable.\n\n\
             Game state: {}\n\n\
             Examples: \"Health critical, use medkit now\", \"2 enemies ahead, use cover on the left\", \
             \"Reload before entering the next room\"\n\n\
             Respond with ONLY the suggestion, nothing else.",
            game_name, state_json
        );

        let request = crate::llm_router::RouterRequest {
            messages: vec![crate::llm_router::ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(prompt),
            }],
            complexity: Some(crate::llm_router::TaskComplexity::Simple),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(64),
        };

        let response = router
            .chat(&request)
            .await
            .map_err(|e| format!("LLM suggestion failed: {}", e))?;

        let suggestion = response.text.trim().to_string();
        info!("[gaming] Suggestion: {}", suggestion);
        Ok(suggestion)
    }

    // -----------------------------------------------------------------------
    // Overlay Hints
    // -----------------------------------------------------------------------

    /// Format a compact hint string for display in the overlay or notification.
    pub fn format_overlay_hint(suggestion: &str, game_state: &GameStateAnalysis) -> String {
        let mut parts: Vec<String> = Vec::new();

        // Health indicator
        if let Some(hp) = game_state.health_percent {
            let icon = if hp <= 25.0 {
                "!!"
            } else if hp <= 50.0 {
                "!"
            } else {
                ""
            };
            parts.push(format!("HP:{:.0}%{}", hp, icon));
        }

        // Enemies
        if game_state.enemies_visible > 0 {
            parts.push(format!("E:{}", game_state.enemies_visible));
        }

        // Danger level (only if medium or above)
        match game_state.danger_level.as_str() {
            "critical" => parts.push("DANGER".into()),
            "high" => parts.push("ALERT".into()),
            "medium" => parts.push("CAUTION".into()),
            _ => {}
        }

        let status = if parts.is_empty() {
            String::new()
        } else {
            format!("[{}] ", parts.join(" | "))
        };

        format!("{}{}", status, suggestion)
    }

    // -----------------------------------------------------------------------
    // Voice Coaching
    // -----------------------------------------------------------------------

    /// Synthesize a suggestion via Piper TTS and play it through PipeWire.
    pub async fn voice_coach(suggestion: &str) -> Result<(), String> {
        // Try piper piped to pw-play first, fall back to aplay
        let piper_result = Command::new("sh")
            .arg("-c")
            .arg(format!(
                "echo '{}' | piper --output_raw | pw-play --rate 22050 --channels 1 --format s16 -",
                suggestion.replace('\'', "'\\''")
            ))
            .output()
            .await;

        match piper_result {
            Ok(o) if o.status.success() => {
                info!("[gaming] Voice coach played suggestion via piper+pw-play");
                Ok(())
            }
            _ => {
                // Fallback: write to temp file and play with aplay
                warn!("[gaming] pw-play failed, trying piper+aplay fallback");
                let tmp_path = "/tmp/lifeos-voice-coach.wav";
                let fallback = Command::new("sh")
                    .arg("-c")
                    .arg(format!(
                        "echo '{}' | piper --output_file {}",
                        suggestion.replace('\'', "'\\''"),
                        tmp_path
                    ))
                    .output()
                    .await;

                match fallback {
                    Ok(o) if o.status.success() => {
                        let play = Command::new("aplay").arg(tmp_path).output().await;
                        match play {
                            Ok(p) if p.status.success() => {
                                info!("[gaming] Voice coach played suggestion via piper+aplay");
                                Ok(())
                            }
                            _ => Err("Failed to play TTS audio via aplay".into()),
                        }
                    }
                    _ => Err("Piper TTS synthesis failed".into()),
                }
            }
        }
    }

    pub fn stop_observing(&mut self) {
        self.state.observing = false;
        self.state.playing = false;
        info!(
            "[gaming] Stopped observing. Frames captured: {}",
            self.state.frames_captured
        );
    }
}

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------

/// Encode bytes to base64 using the `base64` crate (already a workspace dep).
fn base64_encode(data: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(data)
}

/// Parse the LLM's JSON response into a GameStateAnalysis, with graceful fallback.
fn parse_game_state_json(raw: &str) -> GameStateAnalysis {
    // Strip markdown code fences if present
    let cleaned = raw
        .trim()
        .strip_prefix("```json")
        .or_else(|| raw.trim().strip_prefix("```"))
        .unwrap_or(raw)
        .trim()
        .strip_suffix("```")
        .unwrap_or(raw)
        .trim();

    // Try direct deserialization first
    if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(cleaned) {
        return GameStateAnalysis {
            health_percent: parsed
                .get("health_percent")
                .or_else(|| parsed.get("health"))
                .or_else(|| parsed.get("hp"))
                .and_then(|v| v.as_f64())
                .map(|v| v as f32),
            ammo: parsed
                .get("ammo")
                .or_else(|| parsed.get("ammo_count"))
                .and_then(|v| {
                    if v.is_string() {
                        v.as_str().map(String::from)
                    } else {
                        Some(v.to_string())
                    }
                }),
            objective: parsed
                .get("objective")
                .or_else(|| parsed.get("current_objective"))
                .and_then(|v| v.as_str())
                .map(String::from),
            enemies_visible: parsed
                .get("enemies_visible")
                .or_else(|| parsed.get("enemies"))
                .or_else(|| parsed.get("visible_enemies"))
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as u32,
            location: parsed
                .get("location")
                .or_else(|| parsed.get("area"))
                .or_else(|| parsed.get("location_name"))
                .and_then(|v| v.as_str())
                .map(String::from),
            danger_level: parsed
                .get("danger_level")
                .or_else(|| parsed.get("danger"))
                .and_then(|v| v.as_str())
                .unwrap_or("low")
                .to_string(),
            raw_analysis: raw.to_string(),
        };
    }

    // Fallback: return raw text with defaults
    GameStateAnalysis {
        raw_analysis: raw.to_string(),
        ..Default::default()
    }
}
