use crate::daemon_client;
use clap::Args;
use colored::Colorize;

#[derive(Args)]
pub struct DoctorArgs {
    /// Attempt to automatically repair detected issues
    #[arg(long)]
    pub repair: bool,

    /// Output in JSON format
    #[arg(long)]
    pub json: bool,
}

pub async fn execute(args: DoctorArgs) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let base = daemon_client::daemon_url();

    if !args.json {
        println!("{}", "LifeOS Doctor - System Health Check".bold().blue());
        println!();
    }

    // Deep health check via daemon API
    let url = format!("{}/api/v1/health", base);
    let resp = client.get(&url).send().await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let health: serde_json::Value = r
                .json()
                .await
                .unwrap_or_else(|_| serde_json::json!({"status": "unknown"}));

            if args.json {
                println!("{}", serde_json::to_string_pretty(&health)?);
            } else {
                print_health_report(&health);
            }
        }
        Ok(r) => {
            let status = r.status();
            if args.json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "status": "error",
                        "daemon_reachable": true,
                        "http_status": status.as_u16(),
                        "message": format!("Daemon returned {}", status)
                    }))?
                );
            } else {
                println!(
                    "  {} Daemon reachable but returned HTTP {}",
                    "!".yellow().bold(),
                    status
                );
                if status.as_u16() == 401 {
                    println!(
                        "    {} Bootstrap token may be missing or invalid",
                        "Hint:".dimmed()
                    );
                }
            }
        }
        Err(e) => {
            if args.json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "status": "unreachable",
                        "daemon_reachable": false,
                        "message": format!("Cannot reach lifeosd: {}", e)
                    }))?
                );
            } else {
                println!(
                    "  {} Cannot reach lifeosd at {}",
                    "X".red().bold(),
                    base.dimmed()
                );
                println!("    Error: {}", format!("{e}").dimmed());
                println!();
                println!("  {} Is the daemon running?", "Hint:".dimmed());
                println!("    {}", "systemctl --user status lifeosd".cyan());
            }
        }
    }

    if args.repair {
        println!();
        if args.json {
            println!(
                "{}",
                serde_json::to_string_pretty(&serde_json::json!({
                    "repair": "not_yet_implemented",
                    "message": "Automatic repair will be available in a future release"
                }))?
            );
        } else {
            println!(
                "  {} Automatic repair is not yet implemented.",
                "i".blue().bold()
            );
            println!("    Use the dashboard or Telegram bot for manual remediation.");
        }
    }

    Ok(())
}

fn print_health_report(health: &serde_json::Value) {
    // Overall status
    if let Some(status) = health.get("status").and_then(|v| v.as_str()) {
        let colored_status = match status {
            "ok" | "healthy" => status.green().bold(),
            "degraded" => status.yellow().bold(),
            _ => status.red().bold(),
        };
        println!("  Overall: {}", colored_status);
    }

    // Print each component if present
    if let Some(components) = health.get("components").and_then(|v| v.as_object()) {
        println!();
        println!("  {}", "Components:".bold());
        for (name, value) in components {
            let indicator = if value
                .get("healthy")
                .and_then(|v| v.as_bool())
                .unwrap_or(false)
            {
                "OK".green()
            } else {
                "FAIL".red()
            };
            println!("    {} {}", indicator, name);
            if let Some(msg) = value.get("message").and_then(|v| v.as_str()) {
                println!("      {}", msg.dimmed());
            }
        }
    }

    // If the response is flat (no components key), just pretty-print
    if health.get("components").is_none() && health.get("status").is_some() {
        if let Some(obj) = health.as_object() {
            for (key, value) in obj {
                if key == "status" {
                    continue;
                }
                println!("  {}: {}", key.bold(), value);
            }
        }
    }

    println!();
}
