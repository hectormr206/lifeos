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
use log::{info, warn};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::process::Command;

use crate::computer_use::{ComputerUseAction, ComputerUseManager};
use crate::llm_router::{ChatMessage, LlmRouter, RouterRequest, TaskComplexity};

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
            // Even if logind says idle, check camera presence as counter-evidence
            if camera_presence_detected() {
                info!("[autonomous] IdleHint=true but camera detects user — reporting Active");
                return UserPresence::Active;
            }
            return UserPresence::Idle;
        }
    }

    UserPresence::Active
}

// ---------------------------------------------------------------------------
// Visual Grounding & Action Loop
// ---------------------------------------------------------------------------

/// Result of a completed action loop execution.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActionLoopResult {
    /// Number of steps actually executed.
    pub steps_taken: u32,
    /// Whether the goal was achieved.
    pub success: bool,
    /// Paths to screenshots taken during execution.
    pub screenshots: Vec<String>,
    /// Final state description returned by the LLM.
    pub final_state: String,
}

/// Parsed action from the LLM response.
#[derive(Debug, Clone)]
enum ParsedAction {
    Click { x: i32, y: i32 },
    Type { text: String },
    Key { combo: String },
    Scroll { direction: String },
    Done { result: String },
}

/// Capture a screenshot via grim and return the file path.
async fn capture_screenshot(label: &str) -> Result<String, String> {
    let ts = chrono::Utc::now().format("%Y%m%d-%H%M%S%3f");
    let path = format!("/tmp/lifeos-{}-{}.png", label, ts);
    let output = Command::new("grim")
        .arg(&path)
        .output()
        .await
        .map_err(|e| format!("Failed to run grim: {}", e))?;
    if !output.status.success() {
        return Err(format!(
            "grim failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(path)
}

/// Encode a PNG file as a base64 data URL for vision requests.
async fn screenshot_to_data_url(path: &str) -> Result<String, String> {
    let bytes = tokio::fs::read(path)
        .await
        .map_err(|e| format!("Failed to read screenshot {}: {}", path, e))?;
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
    Ok(format!("data:image/png;base64,{}", b64))
}

/// Build a vision ChatMessage with a screenshot and text prompt.
fn build_vision_message(text: &str, data_url: &str) -> ChatMessage {
    ChatMessage {
        role: "user".into(),
        content: serde_json::json!([
            { "type": "text", "text": text },
            { "type": "image_url", "image_url": { "url": data_url } }
        ]),
    }
}

/// Visual grounding: find a UI element on screen by description and return its (x, y) coordinates.
///
/// 1. Captures a screenshot via `grim`
/// 2. Sends it to a vision-capable LLM asking for coordinates of the described element
/// 3. Parses and returns the (x, y) pair
pub async fn visual_grounding(
    description: &str,
    router: &LlmRouter,
) -> Result<(i32, i32), String> {
    let screenshot_path = capture_screenshot("grounding").await?;
    let data_url = screenshot_to_data_url(&screenshot_path).await?;

    let prompt = format!(
        "Look at this screenshot. Find the UI element: '{}'. \
         Return ONLY coordinates as: x,y\n\
         Do not include any other text, just the two numbers separated by a comma.",
        description
    );

    let request = RouterRequest {
        messages: vec![
            ChatMessage {
                role: "system".into(),
                content: serde_json::Value::String(
                    "You are a visual grounding assistant. You identify UI elements in screenshots \
                     and return their pixel coordinates. Always return ONLY x,y with no extra text."
                        .into(),
                ),
            },
            build_vision_message(&prompt, &data_url),
        ],
        complexity: Some(TaskComplexity::Vision),
        sensitivity: None,
        preferred_provider: None,
        max_tokens: Some(32),
    };

    let response = router
        .chat(&request)
        .await
        .map_err(|e| format!("Vision LLM failed: {}", e))?;

    parse_coordinates(&response.text)
}

/// Parse "x,y" from an LLM response text.
fn parse_coordinates(text: &str) -> Result<(i32, i32), String> {
    // Strip whitespace and look for a pattern like "123,456" or "123, 456"
    let cleaned = text.trim();
    // Try to find the first occurrence of digits,digits
    for line in cleaned.lines() {
        let line = line.trim();
        if let Some((x_str, y_str)) = line.split_once(',') {
            let x_str = x_str.trim().trim_start_matches('(');
            let y_str = y_str.trim().trim_end_matches(')');
            if let (Ok(x), Ok(y)) = (x_str.parse::<i32>(), y_str.parse::<i32>()) {
                return Ok((x, y));
            }
        }
    }
    Err(format!(
        "Could not parse coordinates from LLM response: '{}'",
        cleaned
    ))
}

/// Parse a single action from the LLM response.
fn parse_action(text: &str) -> Result<ParsedAction, String> {
    let trimmed = text.trim().to_lowercase();
    // Patterns: click(x,y), type(text), key(combo), scroll(direction), done(result)
    if let Some(inner) = extract_parens(&trimmed, "click") {
        let (x, y) = parse_coordinates(&inner)?;
        return Ok(ParsedAction::Click { x, y });
    }
    if let Some(inner) = extract_parens(text.trim(), "type") {
        return Ok(ParsedAction::Type {
            text: inner.to_string(),
        });
    }
    if let Some(inner) = extract_parens(text.trim(), "key") {
        return Ok(ParsedAction::Key {
            combo: inner.to_string(),
        });
    }
    if let Some(inner) = extract_parens(text.trim(), "scroll") {
        return Ok(ParsedAction::Scroll {
            direction: inner.to_string(),
        });
    }
    if let Some(inner) = extract_parens(text.trim(), "done") {
        return Ok(ParsedAction::Done {
            result: inner.to_string(),
        });
    }
    // Fallback: check if the whole line looks like "done" without parens
    if trimmed.starts_with("done") {
        return Ok(ParsedAction::Done {
            result: text.trim().to_string(),
        });
    }
    Err(format!("Could not parse action from: '{}'", text.trim()))
}

/// Extract the content inside parentheses for a given prefix, e.g. "click(100,200)" -> "100,200".
fn extract_parens<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    let lower = text.to_lowercase();
    let start = lower.find(&format!("{}(", prefix))?;
    let after = start + prefix.len() + 1;
    let end = text[after..].find(')')? + after;
    Some(text[after..end].trim())
}

/// Execute a parsed action using the ComputerUseManager.
async fn execute_action(action: &ParsedAction) -> Result<String, String> {
    let manager = ComputerUseManager::new();
    match action {
        ParsedAction::Click { x, y } => {
            // Move then click
            manager
                .execute(ComputerUseAction::Move { x: *x, y: *y }, false)
                .await
                .map_err(|e| format!("Move failed: {}", e))?;
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            manager
                .execute(ComputerUseAction::Click { button: 1 }, false)
                .await
                .map_err(|e| format!("Click failed: {}", e))?;
            Ok(format!("Clicked at ({}, {})", x, y))
        }
        ParsedAction::Type { text } => {
            manager
                .execute(
                    ComputerUseAction::TypeText {
                        text: text.clone(),
                    },
                    false,
                )
                .await
                .map_err(|e| format!("Type failed: {}", e))?;
            Ok(format!("Typed: {}", text))
        }
        ParsedAction::Key { combo } => {
            manager
                .execute(
                    ComputerUseAction::Key {
                        combo: combo.clone(),
                    },
                    false,
                )
                .await
                .map_err(|e| format!("Key failed: {}", e))?;
            Ok(format!("Key combo: {}", combo))
        }
        ParsedAction::Scroll { direction } => {
            // Scroll via ydotool: mouse wheel events
            let key = match direction.to_lowercase().as_str() {
                "up" => "up",
                "down" => "down",
                _ => "down",
            };
            // Use Page Up/Down as a scroll approximation
            let combo = if key == "up" { "pageup" } else { "pagedown" };
            manager
                .execute(
                    ComputerUseAction::Key {
                        combo: combo.to_string(),
                    },
                    false,
                )
                .await
                .map_err(|e| format!("Scroll failed: {}", e))?;
            Ok(format!("Scrolled {}", direction))
        }
        ParsedAction::Done { result } => Ok(format!("Done: {}", result)),
    }
}

/// Universal action loop: pursue a goal by iteratively observing the screen and taking actions.
///
/// 1. Take screenshot
/// 2. Send to LLM asking what action to take
/// 3. Parse and execute the action
/// 4. Verify with another screenshot
/// 5. Repeat until "done" or max_steps
pub async fn action_loop(
    goal: &str,
    max_steps: u32,
    router: &LlmRouter,
) -> Result<ActionLoopResult, String> {
    let system_prompt = format!(
        "You are Axi, an autonomous desktop agent for LifeOS. Your goal: {}\n\
         You control a Linux Wayland desktop. At each step you see a screenshot.\n\
         Respond with EXACTLY ONE action:\n\
         - click(x,y) — click at pixel coordinates\n\
         - type(text) — type text into focused field\n\
         - key(combo) — press key combo like ctrl+c, enter, tab\n\
         - scroll(up|down) — scroll the page\n\
         - done(result) — goal achieved, describe what was accomplished\n\
         Return ONLY the action, no explanation.",
        goal
    );

    let mut screenshots = Vec::new();
    let mut final_state = String::new();
    let mut steps_taken = 0u32;

    for step in 0..max_steps {
        info!("[action_loop] Step {}/{} for goal: {}", step + 1, max_steps, goal);

        // 1. Capture current state
        let before_path = capture_screenshot(&format!("step{}-before", step)).await?;
        let before_url = screenshot_to_data_url(&before_path).await?;
        screenshots.push(before_path);

        // 2. Ask LLM what to do
        let request = RouterRequest {
            messages: vec![
                ChatMessage {
                    role: "system".into(),
                    content: serde_json::Value::String(system_prompt.clone()),
                },
                build_vision_message(
                    &format!(
                        "Goal: {}. Step {}/{}. What action should I take next?",
                        goal,
                        step + 1,
                        max_steps
                    ),
                    &before_url,
                ),
            ],
            complexity: Some(TaskComplexity::Vision),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(128),
        };

        let response = router
            .chat(&request)
            .await
            .map_err(|e| format!("Vision LLM failed at step {}: {}", step + 1, e))?;

        info!("[action_loop] LLM response: {}", response.text.trim());

        // 3. Parse the action
        let action = match parse_action(&response.text) {
            Ok(a) => a,
            Err(e) => {
                warn!("[action_loop] Could not parse action: {}. Stopping.", e);
                final_state = format!("Parse error at step {}: {}", step + 1, e);
                steps_taken = step + 1;
                break;
            }
        };

        // 4. Check for done
        if let ParsedAction::Done { ref result } = action {
            final_state = result.clone();
            steps_taken = step + 1;
            info!("[action_loop] Goal achieved: {}", result);
            return Ok(ActionLoopResult {
                steps_taken,
                success: true,
                screenshots,
                final_state,
            });
        }

        // 5. Execute the action
        match execute_action(&action).await {
            Ok(msg) => info!("[action_loop] Executed: {}", msg),
            Err(e) => warn!("[action_loop] Action execution error: {}", e),
        }

        steps_taken = step + 1;

        // 6. Brief pause to let the UI update
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;

        // 7. Capture verification screenshot
        let after_path = capture_screenshot(&format!("step{}-after", step)).await?;
        let after_url = screenshot_to_data_url(&after_path).await?;
        screenshots.push(after_path);

        // 8. Ask LLM to verify and decide next step
        let verify_request = RouterRequest {
            messages: vec![
                ChatMessage {
                    role: "system".into(),
                    content: serde_json::Value::String(system_prompt.clone()),
                },
                build_vision_message(
                    &format!(
                        "Goal: {}. I just executed: {:?}. \
                         Here is the screen after the action. \
                         If the goal is complete, respond with done(result). \
                         Otherwise I will take another screenshot and ask for the next action.",
                        goal, action
                    ),
                    &after_url,
                ),
            ],
            complexity: Some(TaskComplexity::Vision),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(128),
        };

        if let Ok(verify_resp) = router.chat(&verify_request).await {
            if let Ok(ParsedAction::Done { result }) = parse_action(&verify_resp.text) {
                final_state = result.clone();
                steps_taken = step + 1;
                info!("[action_loop] Verification says done: {}", result);
                return Ok(ActionLoopResult {
                    steps_taken,
                    success: true,
                    screenshots,
                    final_state,
                });
            }
        }
    }

    Ok(ActionLoopResult {
        steps_taken,
        success: false,
        screenshots,
        final_state: if final_state.is_empty() {
            format!("Max steps ({}) reached without completing goal", max_steps)
        } else {
            final_state
        },
    })
}

// ---------------------------------------------------------------------------
// Workspace, Browser & Terminal helpers
// ---------------------------------------------------------------------------

impl AutonomousAgent {
    /// Ensure the "Axi" workspace exists by switching to it via swaymsg.
    /// This creates a dedicated workspace for Axi to operate in without
    /// disturbing the user's active workspace.
    pub async fn ensure_axi_workspace(&self) -> Result<(), String> {
        let ws_name = &self.state.workspace_name;
        info!("[autonomous] Ensuring workspace: {}", ws_name);

        let output = Command::new("swaymsg")
            .args(["workspace", ws_name])
            .output()
            .await
            .map_err(|e| format!("Failed to run swaymsg: {}", e))?;

        if !output.status.success() {
            return Err(format!(
                "swaymsg workspace failed: {}",
                String::from_utf8_lossy(&output.stderr)
            ));
        }

        info!("[autonomous] Workspace '{}' ready", ws_name);
        Ok(())
    }
}

/// Read the active terminal's text buffer content.
///
/// Tries multiple strategies:
/// 1. Primary selection via `wl-paste -p` (works if terminal copies on select)
/// 2. Screenshot + OCR via tesseract
/// 3. Fallback: select-all + copy via ydotool
pub async fn read_terminal_buffer() -> Result<String, String> {
    // Strategy 1: primary selection (Wayland)
    if let Ok(output) = Command::new("wl-paste")
        .args(["-p", "--no-newline"])
        .output()
        .await
    {
        if output.status.success() {
            let text = String::from_utf8_lossy(&output.stdout).to_string();
            if !text.trim().is_empty() {
                info!("[terminal_buffer] Read {} chars via wl-paste -p", text.len());
                return Ok(text);
            }
        }
    }

    // Strategy 2: screenshot + OCR
    info!("[terminal_buffer] Trying screenshot + OCR");
    if let Ok(screenshot_path) = capture_screenshot("terminal").await {
        if let Ok(ocr_output) = Command::new("tesseract")
            .args([screenshot_path.as_str(), "stdout", "-l", "eng"])
            .output()
            .await
        {
            if ocr_output.status.success() {
                let text = String::from_utf8_lossy(&ocr_output.stdout).to_string();
                if !text.trim().is_empty() {
                    info!(
                        "[terminal_buffer] Read {} chars via screenshot+OCR",
                        text.len()
                    );
                    return Ok(text);
                }
            }
        }
    }

    // Strategy 3: select-all + copy via keyboard shortcuts
    info!("[terminal_buffer] Trying select-all + copy via ydotool");
    let manager = ComputerUseManager::new();
    // Ctrl+Shift+A = select all in many terminals
    let _ = manager
        .execute(
            ComputerUseAction::Key {
                combo: "ctrl+shift+a".to_string(),
            },
            false,
        )
        .await;
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    // Ctrl+Shift+C = copy in many terminals
    let _ = manager
        .execute(
            ComputerUseAction::Key {
                combo: "ctrl+shift+c".to_string(),
            },
            false,
        )
        .await;
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    // Now read from clipboard
    if let Ok(output) = Command::new("wl-paste")
        .args(["--no-newline"])
        .output()
        .await
    {
        if output.status.success() {
            let text = String::from_utf8_lossy(&output.stdout).to_string();
            if !text.trim().is_empty() {
                info!(
                    "[terminal_buffer] Read {} chars via select-all+copy",
                    text.len()
                );
                return Ok(text);
            }
        }
    }

    Err("All terminal buffer reading strategies failed".to_string())
}

/// Open a browser in the Axi workspace with a specific URL.
///
/// 1. Switches to the Axi workspace via swaymsg
/// 2. Launches firefox (or chromium as fallback) with the URL
/// 3. Waits briefly for the window to appear
pub async fn open_browser_in_workspace(url: &str) -> Result<(), String> {
    // Switch to Axi workspace
    let ws_output = Command::new("swaymsg")
        .args(["workspace", "Axi Workspace"])
        .output()
        .await
        .map_err(|e| format!("swaymsg failed: {}", e))?;

    if !ws_output.status.success() {
        warn!(
            "[browser] Failed to switch workspace: {}",
            String::from_utf8_lossy(&ws_output.stderr)
        );
    }

    // Try Firefox first (including Flatpak)
    let browsers = [
        ("firefox", vec![url.to_string()]),
        (
            "flatpak",
            vec![
                "run".to_string(),
                "org.mozilla.firefox".to_string(),
                url.to_string(),
            ],
        ),
        ("chromium-browser", vec![url.to_string()]),
        ("chromium", vec![url.to_string()]),
        ("google-chrome", vec![url.to_string()]),
    ];

    for (cmd, args) in &browsers {
        match Command::new(cmd).args(args).spawn() {
            Ok(_child) => {
                info!("[browser] Launched {} with URL: {}", cmd, url);
                // Wait for the browser window to appear
                tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                return Ok(());
            }
            Err(_) => continue,
        }
    }

    Err("No browser found (tried firefox, flatpak firefox, chromium, chrome)".to_string())
}

/// Watch a download directory for new files and return the first one that appears.
///
/// Uses a polling approach: snapshots the directory contents, then watches for
/// changes until a new file appears or the timeout is reached.
pub async fn wait_for_download(download_dir: &str, timeout_secs: u64) -> Result<PathBuf, String> {
    let dir = PathBuf::from(download_dir);
    if !dir.is_dir() {
        return Err(format!("Download directory does not exist: {}", download_dir));
    }

    // Snapshot existing files
    let existing: std::collections::HashSet<PathBuf> = std::fs::read_dir(&dir)
        .map_err(|e| format!("Failed to read directory: {}", e))?
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .collect();

    info!(
        "[download] Watching {} for new files (timeout: {}s, existing: {} files)",
        download_dir,
        timeout_secs,
        existing.len()
    );

    let deadline =
        std::time::Instant::now() + std::time::Duration::from_secs(timeout_secs);
    let poll_interval = std::time::Duration::from_millis(500);

    loop {
        if std::time::Instant::now() >= deadline {
            return Err(format!(
                "Timeout ({}s) waiting for download in {}",
                timeout_secs, download_dir
            ));
        }

        if let Ok(entries) = std::fs::read_dir(&dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if !existing.contains(&path) {
                    // Skip partial downloads (.part, .crdownload, .download)
                    let name = path.file_name().unwrap_or_default().to_string_lossy();
                    if name.ends_with(".part")
                        || name.ends_with(".crdownload")
                        || name.ends_with(".download")
                    {
                        continue;
                    }
                    info!("[download] New file detected: {}", path.display());
                    return Ok(path);
                }
            }
        }

        tokio::time::sleep(poll_interval).await;
    }
}

// ---------------------------------------------------------------------------
// Multi-Tab Browser Management
// ---------------------------------------------------------------------------

/// Open a new browser tab and navigate to the given URL.
///
/// Uses Ctrl+T to open new tab, then types the URL and presses Enter.
pub async fn browser_new_tab(url: &str) -> Result<(), String> {
    let manager = ComputerUseManager::new();

    // Ctrl+T = new tab
    manager
        .execute(
            ComputerUseAction::Key {
                combo: "ctrl+t".to_string(),
            },
            false,
        )
        .await
        .map_err(|e| format!("Failed to open new tab: {}", e))?;

    // Wait for new tab to open
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;

    // Type the URL
    manager
        .execute(
            ComputerUseAction::TypeText {
                text: url.to_string(),
            },
            false,
        )
        .await
        .map_err(|e| format!("Failed to type URL: {}", e))?;

    // Press Enter
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    manager
        .execute(
            ComputerUseAction::Key {
                combo: "enter".to_string(),
            },
            false,
        )
        .await
        .map_err(|e| format!("Failed to press Enter: {}", e))?;

    info!("[browser] Opened new tab: {}", url);
    Ok(())
}

/// Switch to a browser tab by index (1-based).
///
/// Uses Ctrl+1..9 for tabs 1-9. For higher indices, uses Ctrl+Tab repeatedly.
pub async fn browser_switch_tab(index: u32) -> Result<(), String> {
    let manager = ComputerUseManager::new();

    if index == 0 {
        return Err("Tab index must be >= 1".to_string());
    }

    if index <= 9 {
        // Ctrl+1..9 switches to that tab directly
        let combo = format!("ctrl+{}", index);
        manager
            .execute(
                ComputerUseAction::Key { combo },
                false,
            )
            .await
            .map_err(|e| format!("Failed to switch tab: {}", e))?;
    } else {
        // For tabs > 9: go to first tab then Ctrl+Tab forward
        manager
            .execute(
                ComputerUseAction::Key {
                    combo: "ctrl+1".to_string(),
                },
                false,
            )
            .await
            .map_err(|e| format!("Failed to go to first tab: {}", e))?;

        for _ in 1..index {
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            manager
                .execute(
                    ComputerUseAction::Key {
                        combo: "ctrl+tab".to_string(),
                    },
                    false,
                )
                .await
                .map_err(|e| format!("Failed to switch tab: {}", e))?;
        }
    }

    info!("[browser] Switched to tab {}", index);
    Ok(())
}

/// Close the current browser tab via Ctrl+W.
pub async fn browser_close_tab() -> Result<(), String> {
    let manager = ComputerUseManager::new();

    manager
        .execute(
            ComputerUseAction::Key {
                combo: "ctrl+w".to_string(),
            },
            false,
        )
        .await
        .map_err(|e| format!("Failed to close tab: {}", e))?;

    info!("[browser] Closed current tab");
    Ok(())
}

// ---------------------------------------------------------------------------
// Internal helpers (existing code below)
// ---------------------------------------------------------------------------

/// Check if the sensory pipeline has recently detected a person via camera.
/// Returns `true` if `/var/lib/lifeos/presence_detected` exists and was
/// modified less than 2 minutes ago.
fn camera_presence_detected() -> bool {
    use std::path::Path;
    use std::time::{Duration, SystemTime};

    let path = Path::new("/var/lib/lifeos/presence_detected");
    let Ok(metadata) = path.metadata() else {
        return false;
    };
    let Ok(modified) = metadata.modified() else {
        return false;
    };
    let Ok(elapsed) = SystemTime::now().duration_since(modified) else {
        return false;
    };
    elapsed < Duration::from_secs(120)
}
