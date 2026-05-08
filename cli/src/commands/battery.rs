use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum BatteryCommands {
    /// Show battery health, capacity, cycles, threshold, and power profile
    Status,
    /// Set charge threshold (40-100)
    Threshold {
        /// Charge threshold percentage (40-100)
        #[arg(value_parser = clap::value_parser!(u8).range(40..=100))]
        value: u8,
    },
    /// Temporarily set threshold to 100 for one full charge
    Fullcharge,
}

pub async fn execute(args: BatteryCommands) -> anyhow::Result<()> {
    match args {
        BatteryCommands::Status => show_status().await,
        BatteryCommands::Threshold { value } => set_threshold(value).await,
        BatteryCommands::Fullcharge => fullcharge().await,
    }
}

async fn show_status() -> anyhow::Result<()> {
    println!("{}", "Battery Status".bold().blue());
    println!();

    let body: serde_json::Value = daemon_client::get_json("/api/v1/battery/status").await?;

    let health = body
        .get("health")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown");
    let capacity = body
        .get("capacity")
        .and_then(|v| v.as_u64())
        .map(|v| format!("{}%", v))
        .unwrap_or_else(|| "unknown".into());
    let cycles = body
        .get("cycles")
        .and_then(|v| v.as_u64())
        .map(|v| v.to_string())
        .unwrap_or_else(|| "unknown".into());
    let threshold = body
        .get("threshold")
        .and_then(|v| v.as_u64())
        .map(|v| format!("{}%", v))
        .unwrap_or_else(|| "unknown".into());
    let power_profile = body
        .get("power_profile")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown");
    let charging = body.get("charging").and_then(|v| v.as_bool());

    println!("  Health:        {}", health.green());
    println!("  Capacity:      {}", capacity.cyan());
    println!("  Cycles:        {}", cycles.cyan());
    println!("  Threshold:     {}", threshold.cyan());
    println!("  Power profile: {}", power_profile.cyan());
    if let Some(is_charging) = charging {
        let status_str = if is_charging {
            "Charging".yellow()
        } else {
            "Discharging".white()
        };
        println!("  State:         {}", status_str);
    }
    println!();

    Ok(())
}

async fn set_threshold(value: u8) -> anyhow::Result<()> {
    println!(
        "{}",
        format!("Setting charge threshold to {}%...", value)
            .bold()
            .blue()
    );
    println!();

    let payload = serde_json::json!({ "threshold": value });
    let _: serde_json::Value =
        daemon_client::post_json("/api/v1/battery/threshold", &payload).await?;

    println!(
        "  Charge threshold set to {}",
        format!("{}%", value).green().bold()
    );
    println!();

    Ok(())
}

async fn fullcharge() -> anyhow::Result<()> {
    println!(
        "{}",
        "Enabling full charge (threshold -> 100%)...".bold().blue()
    );
    println!();

    let payload = serde_json::json!({ "threshold": 100, "temporary": true });
    let _: serde_json::Value =
        daemon_client::post_json("/api/v1/battery/threshold", &payload).await?;

    println!(
        "  {}",
        "Threshold temporarily set to 100%.".green().bold()
    );
    println!(
        "  {}",
        "It will revert to the previous value after a full charge.".dimmed()
    );
    println!();

    Ok(())
}
