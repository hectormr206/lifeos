use crate::daemon_client;
use clap::Subcommand;
use colored::Colorize;

#[derive(Subcommand)]
pub enum SafeModeCommands {
    /// Show current safe-mode status
    Status {
        /// Output in JSON format
        #[arg(long)]
        json: bool,
    },
    /// Exit safe mode and return to normal operation
    Exit,
}

pub async fn execute(cmd: SafeModeCommands) -> anyhow::Result<()> {
    match cmd {
        SafeModeCommands::Status { json } => {
            let result: anyhow::Result<serde_json::Value> =
                daemon_client::get_json("/api/v1/safe-mode").await;
            let body = match result {
                Ok(b) => b,
                Err(e) => {
                    println!(
                        "  {} Cannot reach lifeosd: {}",
                        "X".red().bold(),
                        e.to_string().dimmed()
                    );
                    println!();
                    println!(
                        "  {} If the daemon is not running, safe mode cannot be queried.",
                        "Hint:".dimmed()
                    );
                    anyhow::bail!("Daemon unreachable");
                }
            };

            if json {
                println!("{}", serde_json::to_string_pretty(&body)?);
            } else {
                let active = body
                    .get("safe_mode")
                    .and_then(|v| v.as_bool())
                    .or_else(|| body.get("active").and_then(|v| v.as_bool()))
                    .unwrap_or(false);

                println!("{}", "LifeOS Safe Mode".bold().blue());
                println!();
                if active {
                    println!(
                        "  Status: {}",
                        "ACTIVE - System running in safe mode".yellow().bold()
                    );
                    if let Some(reason) = body.get("reason").and_then(|v| v.as_str()) {
                        println!("  Reason: {}", reason);
                    }
                    println!();
                    println!("  To exit safe mode: {}", "life safe-mode exit".cyan());
                } else {
                    println!("  Status: {}", "INACTIVE - Normal operation".green().bold());
                }
            }
        }
        SafeModeCommands::Exit => {
            println!("{}", "Exiting safe mode...".bold().blue());
            println!();

            let result: anyhow::Result<serde_json::Value> =
                daemon_client::post_empty("/api/v1/safe-mode/exit").await;
            match result {
                Ok(_) => {
                    println!(
                        "  {} Safe mode deactivated. Returning to normal operation.",
                        "OK".green().bold()
                    );
                }
                Err(e) => {
                    let msg = e.to_string();
                    if msg.contains("is lifeosd running") {
                        println!("  {} Cannot reach lifeosd", "X".red().bold());
                        anyhow::bail!("Daemon unreachable");
                    }
                    // Non-2xx: surface status and body
                    println!("  {} {}", "!".yellow().bold(), msg);
                }
            }
        }
    }

    Ok(())
}
