//! Autonomous Agent — Axi works independently when the user is away.
//!
//! Detection: monitors systemd-logind D-Bus signals for Lock/Unlock events.
//! When the user locks the screen or goes idle, Axi activates autonomous mode
//! and works in a dedicated COSMIC workspace to avoid interfering with the user's work.
//!
//! Safety:
//! - Never touches the user's active workspace or open applications
//! - All work happens in a dedicated "Axi Workspace"
//! - Pauses immediately when user returns (Unlock signal)
//! - Only executes pre-approved task types (code review, testing, cleanup)

use anyhow::Result;
use log::info;
use serde::{Deserialize, Serialize};
use tokio::process::Command;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UserPresence {
    /// User is actively using the computer
    Active,
    /// User is idle but screen is not locked
    Idle,
    /// Screen is locked — user is away
    Locked,
    /// Unknown state
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutonomousState {
    pub user_presence: UserPresence,
    pub autonomous_mode_active: bool,
    pub current_task: Option<String>,
    pub tasks_completed_while_away: u32,
    pub workspace_name: String,
}

#[allow(clippy::derivable_impls)]
impl Default for AutonomousState {
    fn default() -> Self {
        Self {
            user_presence: UserPresence::Unknown,
            autonomous_mode_active: false,
            current_task: None,
            tasks_completed_while_away: 0,
            workspace_name: "Axi Workspace".into(),
        }
    }
}

pub struct AutonomousAgent {
    state: AutonomousState,
    enabled: bool,
    /// Maximum autonomous work time in seconds (default 2 hours).
    max_autonomous_secs: u64,
    /// Timestamp when autonomous mode was activated.
    autonomous_started_at: Option<std::time::Instant>,
    /// Kill switch: if true, immediately stop all autonomous work.
    kill_switch: bool,
}

impl AutonomousAgent {
    pub fn new() -> Self {
        let max_secs = std::env::var("LIFEOS_AUTONOMOUS_MAX_HOURS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(2)
            * 3600;

        Self {
            state: AutonomousState::default(),
            enabled: std::env::var("LIFEOS_AUTONOMOUS_AGENT")
                .map(|v| v != "0" && !v.eq_ignore_ascii_case("false"))
                .unwrap_or(true),
            max_autonomous_secs: max_secs,
            autonomous_started_at: None,
            kill_switch: false,
        }
    }

    /// Activate the kill switch — immediately stops autonomous work.
    pub fn activate_kill_switch(&mut self) {
        self.kill_switch = true;
        self.state.autonomous_mode_active = false;
        self.state.current_task = None;
        info!("[autonomous] Kill switch activated — all autonomous work stopped");
    }

    /// Deactivate kill switch.
    pub fn deactivate_kill_switch(&mut self) {
        self.kill_switch = false;
    }

    /// Check if the autonomous time limit has been reached.
    pub fn time_limit_reached(&self) -> bool {
        if let Some(started) = self.autonomous_started_at {
            started.elapsed().as_secs() >= self.max_autonomous_secs
        } else {
            false
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    pub fn state(&self) -> &AutonomousState {
        &self.state
    }

    /// Check user presence via systemd-logind D-Bus.
    pub async fn check_presence(&mut self) -> Result<UserPresence> {
        if self.kill_switch {
            self.state.autonomous_mode_active = false;
            return Ok(self.state.user_presence);
        }

        let presence = detect_user_presence().await;
        let prev = self.state.user_presence;
        self.state.user_presence = presence;

        // Transition: Active/Idle → Locked = start autonomous mode
        if presence == UserPresence::Locked && prev != UserPresence::Locked && self.enabled {
            info!("[autonomous] User locked screen — activating autonomous mode");
            self.state.autonomous_mode_active = true;
            self.autonomous_started_at = Some(std::time::Instant::now());
        }

        // Transition: Locked → Active/Idle = stop autonomous mode
        if presence != UserPresence::Locked && prev == UserPresence::Locked {
            info!(
                "[autonomous] User returned — deactivating autonomous mode ({} tasks completed)",
                self.state.tasks_completed_while_away
            );
            self.state.autonomous_mode_active = false;
            self.state.current_task = None;
            self.autonomous_started_at = None;
        }

        // Time limit check
        if self.state.autonomous_mode_active && self.time_limit_reached() {
            info!(
                "[autonomous] Time limit reached ({}h) — stopping autonomous work",
                self.max_autonomous_secs / 3600
            );
            self.state.autonomous_mode_active = false;
        }

        Ok(presence)
    }

    /// Check if Axi should be working autonomously right now.
    pub fn should_work(&self) -> bool {
        self.enabled && self.state.autonomous_mode_active && !self.kill_switch
    }

    /// Record that a task was completed during autonomous mode.
    pub fn task_completed(&mut self, task_description: &str) {
        self.state.tasks_completed_while_away += 1;
        self.state.current_task = None;
        info!(
            "[autonomous] Completed task #{}: {}",
            self.state.tasks_completed_while_away, task_description
        );
    }

    /// Reset the counter when user acknowledges.
    pub fn reset_counter(&mut self) {
        self.state.tasks_completed_while_away = 0;
    }
}

/// Detect user presence using systemd-logind D-Bus properties.
async fn detect_user_presence() -> UserPresence {
    // Check LockedHint via busctl
    let locked = Command::new("busctl")
        .args([
            "get-property",
            "org.freedesktop.login1",
            "/org/freedesktop/login1/session/auto",
            "org.freedesktop.login1.Session",
            "LockedHint",
        ])
        .output()
        .await;

    if let Ok(output) = locked {
        let text = String::from_utf8_lossy(&output.stdout);
        if text.contains("true") {
            return UserPresence::Locked;
        }
    }

    // Check IdleHint
    let idle = Command::new("busctl")
        .args([
            "get-property",
            "org.freedesktop.login1",
            "/org/freedesktop/login1/session/auto",
            "org.freedesktop.login1.Session",
            "IdleHint",
        ])
        .output()
        .await;

    if let Ok(output) = idle {
        let text = String::from_utf8_lossy(&output.stdout);
        if text.contains("true") {
            return UserPresence::Idle;
        }
    }

    UserPresence::Active
}
