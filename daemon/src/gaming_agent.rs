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
}

impl GamingAgent {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            data_dir,
            state: GamingAgentState::default(),
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

    pub fn stop_observing(&mut self) {
        self.state.observing = false;
        self.state.playing = false;
        info!(
            "[gaming] Stopped observing. Frames captured: {}",
            self.state.frames_captured
        );
    }
}
