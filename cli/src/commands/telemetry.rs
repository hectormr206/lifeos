//! Telemetry CLI commands
//!
//! Local-only, privacy-first telemetry management.
//! No data is sent to external services.

use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

fn daemon_url() -> String {
    daemon_client::daemon_url()
}

#[derive(Subcommand)]
pub enum TelemetryCommands {
    /// Show telemetry statistics
    Stats,
    /// Show or set consent level
    Consent {
        /// New consent level: disabled, minimal, full (omit to show current)
        level: Option<String>,
    },
    /// Show recent telemetry events
    Events {
        /// Number of events to show
        #[arg(short, long, default_value = "20")]
        limit: usize,
    },
    /// Take a hardware snapshot
    Snapshot,
    /// Export all telemetry data as JSON
    Export,
    /// Clear all telemetry data
    Clear,
}

pub async fn execute(cmd: TelemetryCommands) -> anyhow::Result<()> {
    match cmd {
        TelemetryCommands::Stats => cmd_stats().await,
        TelemetryCommands::Consent { level } => cmd_consent(level).await,
        TelemetryCommands::Events { limit } => cmd_events(limit).await,
        TelemetryCommands::Snapshot => cmd_snapshot().await,
        TelemetryCommands::Export => cmd_export().await,
        TelemetryCommands::Clear => cmd_clear().await,
    }
}

async fn cmd_stats() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!("{}/api/v1/telemetry/stats", daemon_url()))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Telemetry Statistics".bold().blue());
            println!();
            println!(
                "  Consent level:     {}",
                body["consent_level"].as_str().unwrap_or("unknown").cyan()
            );
            println!(
                "  Total events:      {}",
                body["total_events"].as_u64().unwrap_or(0)
            );
            println!(
                "  Boot success rate: {:.1}%",
                body["boot_success_rate"].as_f64().unwrap_or(1.0) * 100.0
            );
            println!(
                "  Avg boot time:     {:.0}ms",
                body["avg_boot_time_ms"].as_f64().unwrap_or(0.0)
            );
            println!(
                "  Update success:    {:.1}%",
                body["update_success_rate"].as_f64().unwrap_or(1.0) * 100.0
            );
            println!(
                "  Uptime:            {:.1}h",
                body["uptime_hours"].as_f64().unwrap_or(0.0)
            );

            if let Some(snapshot) = body.get("last_snapshot") {
                if !snapshot.is_null() {
                    println!();
                    println!("  {}", "Last Hardware Snapshot:".bold());
                    if let Some(cpu) = snapshot["cpu_temp_celsius"].as_f64() {
                        println!("    CPU temp:   {:.1}°C", cpu);
                    }
                    println!(
                        "    CPU usage:  {:.1}%",
                        snapshot["cpu_usage_percent"].as_f64().unwrap_or(0.0)
                    );
                    println!(
                        "    Memory:     {}/{}MB",
                        snapshot["memory_used_mb"].as_u64().unwrap_or(0),
                        snapshot["memory_total_mb"].as_u64().unwrap_or(0)
                    );
                    println!(
                        "    Disk:       {:.1}%",
                        snapshot["disk_used_percent"].as_f64().unwrap_or(0.0)
                    );
                    if snapshot["thermal_throttled"].as_bool().unwrap_or(false) {
                        println!("    {}", "THERMAL THROTTLING DETECTED".red().bold());
                    }
                }
            }

            if let Some(cats) = body["events_by_category"].as_object() {
                if !cats.is_empty() {
                    println!();
                    println!("  {}", "Events by category:".bold());
                    for (cat, count) in cats {
                        println!("    {}: {}", cat.cyan(), count);
                    }
                }
            }
            Ok(())
        }
        Ok(r) => {
            anyhow::bail!("Daemon returned {}", r.status());
        }
        Err(_) => {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
            Ok(())
        }
    }
}

async fn cmd_consent(level: Option<String>) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();

    if let Some(level) = level {
        // Set consent
        let resp = client
            .post(format!("{}/api/v1/telemetry/consent", daemon_url()))
            .json(&serde_json::json!({ "level": level }))
            .send()
            .await;

        match resp {
            Ok(r) if r.status().is_success() => {
                println!(
                    "{} Telemetry consent set to: {}",
                    "OK".green().bold(),
                    level.cyan()
                );
                println!();
                match level.to_lowercase().as_str() {
                    "disabled" | "off" => {
                        println!("  No telemetry will be collected.");
                    }
                    "minimal" => {
                        println!("  Only boot, update, and error events will be collected.");
                    }
                    "full" => {
                        println!("  Full local telemetry including hardware monitoring.");
                        println!("  {}", "No data is sent externally.".dimmed());
                    }
                    _ => {}
                }
                Ok(())
            }
            Ok(r) => {
                let body = r.text().await.unwrap_or_default();
                anyhow::bail!("Failed to set consent: {}", body);
            }
            Err(_) => {
                println!(
                    "{}",
                    "Cannot connect to lifeosd. Is the daemon running?".red()
                );
                Ok(())
            }
        }
    } else {
        // Show current consent
        let resp = client
            .get(format!("{}/api/v1/telemetry/consent", daemon_url()))
            .send()
            .await;

        match resp {
            Ok(r) if r.status().is_success() => {
                let body: serde_json::Value = r.json().await?;
                println!("{}", "Telemetry Consent".bold().blue());
                println!();
                println!(
                    "  Current level: {}",
                    body["consent_level"].as_str().unwrap_or("unknown").cyan()
                );
                println!();
                println!("  Available levels:");
                println!("    {} — no data collected", "disabled".cyan());
                println!(
                    "    {}  — boot, update, error events only",
                    "minimal".cyan()
                );
                println!(
                    "    {}     — full local monitoring (no external data)",
                    "full".cyan()
                );
                println!();
                println!("  Change: {}", "life telemetry consent <level>".cyan());
                Ok(())
            }
            Ok(r) => {
                anyhow::bail!("Daemon returned {}", r.status());
            }
            Err(_) => {
                println!(
                    "{}",
                    "Cannot connect to lifeosd. Is the daemon running?".red()
                );
                Ok(())
            }
        }
    }
}

async fn cmd_events(limit: usize) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!("{}/api/v1/telemetry/events", daemon_url()))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Recent Telemetry Events".bold().blue());
            println!();

            if let Some(events) = body["events"].as_array() {
                let show_count = events.len().min(limit);
                for event in events.iter().take(show_count) {
                    let ts = event["timestamp"].as_str().unwrap_or("?");
                    let cat = event["category"].as_str().unwrap_or("?");
                    let name = event["event_name"].as_str().unwrap_or("?");
                    let dur = event["duration_ms"].as_u64();

                    print!("  {} [{}] {}", ts.dimmed(), cat.cyan(), name);
                    if let Some(d) = dur {
                        print!(" ({}ms)", d);
                    }
                    println!();
                }

                if events.is_empty() {
                    println!("  {}", "No events recorded yet.".dimmed());
                }
            }
            Ok(())
        }
        Ok(r) => {
            anyhow::bail!("Daemon returned {}", r.status());
        }
        Err(_) => {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
            Ok(())
        }
    }
}

async fn cmd_snapshot() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/telemetry/snapshot", daemon_url()))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;

            if body.get("message").is_some() {
                println!("{}", body["message"].as_str().unwrap_or("").yellow());
                println!("  Set consent: {}", "life telemetry consent full".cyan());
                return Ok(());
            }

            println!("{}", "Hardware Snapshot".bold().blue());
            println!();
            if let Some(cpu) = body["cpu_temp_celsius"].as_f64() {
                println!("  CPU temperature:  {:.1}°C", cpu);
            }
            println!(
                "  CPU usage:        {:.1}%",
                body["cpu_usage_percent"].as_f64().unwrap_or(0.0)
            );
            println!(
                "  Memory:           {}/{}MB ({:.1}%)",
                body["memory_used_mb"].as_u64().unwrap_or(0),
                body["memory_total_mb"].as_u64().unwrap_or(0),
                if body["memory_total_mb"].as_u64().unwrap_or(1) > 0 {
                    body["memory_used_mb"].as_f64().unwrap_or(0.0)
                        / body["memory_total_mb"].as_f64().unwrap_or(1.0)
                        * 100.0
                } else {
                    0.0
                }
            );
            println!(
                "  Disk usage:       {:.1}%",
                body["disk_used_percent"].as_f64().unwrap_or(0.0)
            );
            if let Some(gpu) = body["gpu_temp_celsius"].as_f64() {
                println!("  GPU temperature:  {:.1}°C", gpu);
            }
            if body["thermal_throttled"].as_bool().unwrap_or(false) {
                println!();
                println!("  {}", "WARNING: Thermal throttling detected!".red().bold());
            }
            Ok(())
        }
        Ok(r) => {
            anyhow::bail!("Daemon returned {}", r.status());
        }
        Err(_) => {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
            Ok(())
        }
    }
}

async fn cmd_export() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!("{}/api/v1/telemetry/export", daemon_url()))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            // Pretty-print the JSON for user inspection
            println!("{}", serde_json::to_string_pretty(&body)?);
            Ok(())
        }
        Ok(r) => {
            anyhow::bail!("Daemon returned {}", r.status());
        }
        Err(_) => {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
            Ok(())
        }
    }
}

async fn cmd_clear() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/telemetry/clear", daemon_url()))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            println!("{} All telemetry data cleared.", "OK".green().bold());
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to clear data: {}", body);
        }
        Err(_) => {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
            Ok(())
        }
    }
}
