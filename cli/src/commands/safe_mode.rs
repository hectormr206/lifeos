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
    let client = daemon_client::authenticated_client();
    let base = daemon_client::daemon_url();

    match cmd {
        SafeModeCommands::Status { json } => {
            let url = format!("{}/api/v1/safe-mode", base);
            let resp = client.get(&url).send().await;

            match resp {
                Ok(r) if r.status().is_success() => {
                    let body: serde_json::Value = r
                        .json()
                        .await
                        .unwrap_or_else(|_| serde_json::json!({"safe_mode": "unknown"}));

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
                Ok(r) => {
                    let status = r.status();
                    anyhow::bail!(
                        "Daemon returned HTTP {} when checking safe-mode status",
                        status
                    );
                }
                Err(e) => {
                    println!(
                        "  {} Cannot reach lifeosd at {}",
                        "X".red().bold(),
                        base.dimmed()
                    );
                    println!("    Error: {}", format!("{e}").dimmed());
                    println!();
                    println!(
                        "  {} If the daemon is not running, safe mode cannot be queried.",
                        "Hint:".dimmed()
                    );
                    anyhow::bail!("Daemon unreachable");
                }
            }
        }
        SafeModeCommands::Exit => {
            println!("{}", "Exiting safe mode...".bold().blue());
            println!();

            let url = format!("{}/api/v1/safe-mode/exit", base);
            let resp = client.post(&url).send().await;

            match resp {
                Ok(r) if r.status().is_success() => {
                    println!(
                        "  {} Safe mode deactivated. Returning to normal operation.",
                        "OK".green().bold()
                    );
                }
                Ok(r) => {
                    let status = r.status();
                    let body = r.text().await.unwrap_or_default();
                    println!("  {} Daemon returned HTTP {}", "!".yellow().bold(), status);
                    if !body.is_empty() {
                        println!("    {}", body.dimmed());
                    }
                }
                Err(e) => {
                    println!(
                        "  {} Cannot reach lifeosd at {}",
                        "X".red().bold(),
                        base.dimmed()
                    );
                    println!("    Error: {}", format!("{e}").dimmed());
                    anyhow::bail!("Daemon unreachable");
                }
            }
        }
    }

    Ok(())
}
