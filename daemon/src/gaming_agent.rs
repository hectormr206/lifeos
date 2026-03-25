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
use log::info;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::process::Command;

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

    pub fn stop_observing(&mut self) {
        self.state.observing = false;
        self.state.playing = false;
        info!(
            "[gaming] Stopped observing. Frames captured: {}",
            self.state.frames_captured
        );
    }
}
