//! Computer Use runtime.
//!
//! Baseline API to simulate mouse/keyboard actions through local tooling.
//! Preferred backend is `ydotool`, with `xdotool` fallback when available.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use tokio::process::Command;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Backend {
    Ydotool,
    Xdotool,
}

impl Backend {
    fn name(self) -> &'static str {
        match self {
            Self::Ydotool => "ydotool",
            Self::Xdotool => "xdotool",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ComputerUseAction {
    Move { x: i32, y: i32 },
    Click { button: u8 },
    TypeText { text: String },
    Key { combo: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ComputerUseStatus {
    pub available: bool,
    pub backend: String,
    pub capabilities: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ComputerUseResult {
    pub success: bool,
    pub backend: String,
    pub command: Vec<String>,
    pub dry_run: bool,
    pub stdout: String,
    pub stderr: String,
    pub exit_code: i32,
}

pub struct ComputerUseManager;

impl ComputerUseManager {
    pub fn new() -> Self {
        Self
    }

    pub async fn status(&self) -> ComputerUseStatus {
        match detect_backend().await {
            Some(backend) => ComputerUseStatus {
                available: true,
                backend: backend.name().to_string(),
                capabilities: vec![
                    "move".to_string(),
                    "click".to_string(),
                    "type".to_string(),
                    "key".to_string(),
                ],
            },
            None => ComputerUseStatus {
                available: false,
                backend: "none".to_string(),
                capabilities: vec![],
            },
        }
    }

    pub async fn execute(
        &self,
        action: ComputerUseAction,
        dry_run: bool,
    ) -> Result<ComputerUseResult> {
        let backend = detect_backend().await.ok_or_else(|| {
            anyhow::anyhow!("No supported backend found (install ydotool or xdotool)")
        })?;

        let command = build_command(backend, &action)?;
        if command.is_empty() {
            anyhow::bail!("internal error: empty command");
        }

        if dry_run {
            return Ok(ComputerUseResult {
                success: true,
                backend: backend.name().to_string(),
                command,
                dry_run: true,
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
            });
        }

        let output = Command::new(&command[0])
            .args(&command[1..])
            .output()
            .await
            .with_context(|| format!("Failed to execute {}", command[0]))?;

        let exit_code = output.status.code().unwrap_or(1);
        Ok(ComputerUseResult {
            success: output.status.success(),
            backend: backend.name().to_string(),
            command,
            dry_run: false,
            stdout: String::from_utf8_lossy(&output.stdout).to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
            exit_code,
        })
    }
}

async fn detect_backend() -> Option<Backend> {
    if command_exists("ydotool").await {
        Some(Backend::Ydotool)
    } else if command_exists("xdotool").await {
        Some(Backend::Xdotool)
    } else {
        None
    }
}

async fn command_exists(name: &str) -> bool {
    Command::new("which")
        .arg(name)
        .output()
        .await
        .map(|out| out.status.success())
        .unwrap_or(false)
}

fn build_command(backend: Backend, action: &ComputerUseAction) -> Result<Vec<String>> {
    match backend {
        Backend::Xdotool => build_xdotool_command(action),
        Backend::Ydotool => build_ydotool_command(action),
    }
}

fn build_xdotool_command(action: &ComputerUseAction) -> Result<Vec<String>> {
    let command = match action {
        ComputerUseAction::Move { x, y } => vec![
            "xdotool".to_string(),
            "mousemove".to_string(),
            "--sync".to_string(),
            x.to_string(),
            y.to_string(),
        ],
        ComputerUseAction::Click { button } => vec![
            "xdotool".to_string(),
            "click".to_string(),
            button.max(&1).to_string(),
        ],
        ComputerUseAction::TypeText { text } => {
            validate_text_input(text)?;
            vec![
                "xdotool".to_string(),
                "type".to_string(),
                "--delay".to_string(),
                "12".to_string(),
                text.to_string(),
            ]
        }
        ComputerUseAction::Key { combo } => {
            if combo.trim().is_empty() {
                anyhow::bail!("key combo is required");
            }
            vec!["xdotool".to_string(), "key".to_string(), combo.to_string()]
        }
    };
    Ok(command)
}

fn build_ydotool_command(action: &ComputerUseAction) -> Result<Vec<String>> {
    let command = match action {
        ComputerUseAction::Move { x, y } => vec![
            "ydotool".to_string(),
            "mousemove".to_string(),
            "--absolute".to_string(),
            x.to_string(),
            y.to_string(),
        ],
        ComputerUseAction::Click { button } => vec![
            "ydotool".to_string(),
            "click".to_string(),
            button.max(&1).to_string(),
        ],
        ComputerUseAction::TypeText { text } => {
            validate_text_input(text)?;
            vec!["ydotool".to_string(), "type".to_string(), text.to_string()]
        }
        ComputerUseAction::Key { combo } => {
            let events = combo_to_ydotool_events(combo)?;
            let mut cmd = vec!["ydotool".to_string(), "key".to_string()];
            cmd.extend(events);
            cmd
        }
    };
    Ok(command)
}

fn validate_text_input(text: &str) -> Result<()> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        anyhow::bail!("text is required");
    }
    if trimmed.len() > 2048 {
        anyhow::bail!("text exceeds 2048 characters");
    }
    Ok(())
}

fn combo_to_ydotool_events(combo: &str) -> Result<Vec<String>> {
    let mut parts = combo
        .split('+')
        .map(|part| part.trim().to_lowercase())
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>();
    if parts.is_empty() {
        anyhow::bail!("key combo is required");
    }

    let primary = parts.pop().unwrap_or_default();
    let mut modifier_codes = Vec::new();
    for part in parts {
        modifier_codes.push(keycode_for_token(&part)?);
    }
    let primary_code = keycode_for_token(&primary)?;

    let mut events = Vec::new();
    for code in &modifier_codes {
        events.push(format!("{}:1", code));
    }
    events.push(format!("{}:1", primary_code));
    events.push(format!("{}:0", primary_code));
    for code in modifier_codes.iter().rev() {
        events.push(format!("{}:0", code));
    }
    Ok(events)
}

fn keycode_for_token(token: &str) -> Result<u16> {
    match token {
        "ctrl" | "control" => Ok(29),
        "shift" => Ok(42),
        "alt" => Ok(56),
        "super" | "win" | "meta" => Ok(125),
        "enter" | "return" => Ok(28),
        "tab" => Ok(15),
        "space" => Ok(57),
        "esc" | "escape" => Ok(1),
        "up" => Ok(103),
        "down" => Ok(108),
        "left" => Ok(105),
        "right" => Ok(106),
        "delete" => Ok(111),
        "backspace" => Ok(14),
        "home" => Ok(102),
        "end" => Ok(107),
        "pageup" => Ok(104),
        "pagedown" => Ok(109),
        "f1" => Ok(59),
        "f2" => Ok(60),
        "f3" => Ok(61),
        "f4" => Ok(62),
        "f5" => Ok(63),
        "f6" => Ok(64),
        "f7" => Ok(65),
        "f8" => Ok(66),
        "f9" => Ok(67),
        "f10" => Ok(68),
        "f11" => Ok(87),
        "f12" => Ok(88),
        "a" => Ok(30),
        "b" => Ok(48),
        "c" => Ok(46),
        "d" => Ok(32),
        "e" => Ok(18),
        "f" => Ok(33),
        "g" => Ok(34),
        "h" => Ok(35),
        "i" => Ok(23),
        "j" => Ok(36),
        "k" => Ok(37),
        "l" => Ok(38),
        "m" => Ok(50),
        "n" => Ok(49),
        "o" => Ok(24),
        "p" => Ok(25),
        "q" => Ok(16),
        "r" => Ok(19),
        "s" => Ok(31),
        "t" => Ok(20),
        "u" => Ok(22),
        "v" => Ok(47),
        "w" => Ok(17),
        "x" => Ok(45),
        "y" => Ok(21),
        "z" => Ok(44),
        "0" => Ok(11),
        "1" => Ok(2),
        "2" => Ok(3),
        "3" => Ok(4),
        "4" => Ok(5),
        "5" => Ok(6),
        "6" => Ok(7),
        "7" => Ok(8),
        "8" => Ok(9),
        "9" => Ok(10),
        _ => anyhow::bail!(
            "Unsupported key token '{}' for ydotool backend. Use known tokens like ctrl, shift, a-z, 0-9, enter, f1-f12.",
            token
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ydotool_combo_generates_press_and_release_events() {
        let events = combo_to_ydotool_events("ctrl+shift+k").unwrap();
        assert_eq!(
            events,
            vec![
                "29:1".to_string(),
                "42:1".to_string(),
                "37:1".to_string(),
                "37:0".to_string(),
                "42:0".to_string(),
                "29:0".to_string()
            ]
        );
    }

    #[test]
    fn xdotool_type_command_has_delay() {
        let cmd = build_xdotool_command(&ComputerUseAction::TypeText {
            text: "hello".to_string(),
        })
        .unwrap();
        assert_eq!(cmd[0], "xdotool");
        assert_eq!(cmd[1], "type");
        assert_eq!(cmd[2], "--delay");
    }
}
