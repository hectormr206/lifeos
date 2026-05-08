use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum ComputerUseCommands {
    /// Show backend/capabilities status
    Status,
    /// Move pointer to absolute coordinates
    Move {
        x: i32,
        y: i32,
        #[arg(long)]
        dry_run: bool,
    },
    /// Click mouse button (default: 1)
    Click {
        #[arg(long, default_value_t = 1)]
        button: u8,
        #[arg(long)]
        dry_run: bool,
    },
    /// Type text in focused window
    Type {
        text: String,
        #[arg(long)]
        dry_run: bool,
    },
    /// Send key combo (example: ctrl+shift+k)
    Key {
        combo: String,
        #[arg(long)]
        dry_run: bool,
    },
}

pub async fn execute(cmd: ComputerUseCommands) -> anyhow::Result<()> {
    match cmd {
        ComputerUseCommands::Status => cmd_status().await,
        ComputerUseCommands::Move { x, y, dry_run } => {
            cmd_action(
                "move",
                serde_json::json!({
                    "action": "move",
                    "x": x,
                    "y": y,
                    "dry_run": dry_run,
                }),
            )
            .await
        }
        ComputerUseCommands::Click { button, dry_run } => {
            cmd_action(
                "click",
                serde_json::json!({
                    "action": "click",
                    "button": button,
                    "dry_run": dry_run,
                }),
            )
            .await
        }
        ComputerUseCommands::Type { text, dry_run } => {
            cmd_action(
                "type",
                serde_json::json!({
                    "action": "type",
                    "text": text,
                    "dry_run": dry_run,
                }),
            )
            .await
        }
        ComputerUseCommands::Key { combo, dry_run } => {
            cmd_action(
                "key",
                serde_json::json!({
                    "action": "key",
                    "combo": combo,
                    "dry_run": dry_run,
                }),
            )
            .await
        }
    }
}

async fn cmd_status() -> anyhow::Result<()> {
    let body: serde_json::Value = daemon_client::get_json("/api/v1/computer-use/status")
        .await
        .inspect_err(|e| {
            if e.to_string().contains("is lifeosd running") {
                println!(
                    "{}",
                    "Cannot connect to lifeosd. Is the daemon running?".red()
                );
                println!("  Try: {}", "sudo systemctl start lifeosd".cyan());
            }
        })?;
    println!("{}", "Computer Use status".bold().blue());
    println!(
        "  available: {}",
        body["available"].as_bool().unwrap_or(false)
    );
    println!(
        "  backend: {}",
        body["backend"].as_str().unwrap_or("unknown")
    );
    let caps = body["capabilities"]
        .as_array()
        .map(|values| {
            values
                .iter()
                .filter_map(|value| value.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_default();
    if !caps.is_empty() {
        println!("  capabilities: {}", caps);
    }
    Ok(())
}

async fn cmd_action(action_name: &str, payload: serde_json::Value) -> anyhow::Result<()> {
    let body: serde_json::Value = daemon_client::post_json("/api/v1/computer-use/action", &payload)
        .await
        .inspect_err(|e| {
            if e.to_string().contains("is lifeosd running") {
                println!(
                    "{}",
                    "Cannot connect to lifeosd. Is the daemon running?".red()
                );
                println!("  Try: {}", "sudo systemctl start lifeosd".cyan());
            }
        })?;
    let result = &body["result"];
    let success = result["success"].as_bool().unwrap_or(false);
    let dry_run = result["dry_run"].as_bool().unwrap_or(false);

    if success {
        println!("{}", "Computer-use action executed".green().bold());
    } else {
        println!("{}", "Computer-use action failed".yellow().bold());
    }

    println!("  action: {}", action_name.cyan());
    println!(
        "  backend: {}",
        result["backend"].as_str().unwrap_or("unknown").cyan()
    );
    println!("  dry_run: {}", dry_run);
    println!("  exit_code: {}", result["exit_code"].as_i64().unwrap_or(1));
    if let Some(stderr) = result["stderr"].as_str() {
        let stderr = stderr.trim();
        if !stderr.is_empty() {
            println!("  stderr: {}", stderr.dimmed());
        }
    }

    Ok(())
}
