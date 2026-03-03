use crate::config;
use crate::system;
use clap::Args;
use colored::Colorize;

#[derive(Args, Default)]
pub struct StatusArgs {
    /// Output in JSON format
    #[arg(long)]
    pub json: bool,
    /// Show detailed status
    #[arg(long)]
    pub detailed: bool,
}

pub async fn execute(args: StatusArgs) -> anyhow::Result<()> {
    // Get actual system status
    let health = system::check_health();
    let bootc_available = system::is_bootc_available();

    // Get config for channel
    let config = config::load_config().ok();
    let channel = config
        .as_ref()
        .map(|c| c.updates.channel.clone())
        .unwrap_or_else(|| "stable".to_string());

    // Check for updates
    let updates_available = system::check_updates(&channel).unwrap_or(false);

    // Get bootc status if available
    let bootc_status = if bootc_available {
        system::get_bootc_status().ok()
    } else {
        None
    };

    // Determine slot
    let slot = bootc_status
        .as_ref()
        .map(|s| s.booted_slot.clone())
        .unwrap_or_else(|| "A".to_string());

    // Get mode from environment or config
    let mode = std::env::var("LIFEOS_MODE").unwrap_or_else(|_| "personal".to_string());

    // Build detailed status if requested
    let detailed = if args.detailed {
        Some(DetailedStatus {
            bootc_status: bootc_status.as_ref().map(|s| s.booted_slot.clone()),
            rollback_available: bootc_status
                .as_ref()
                .map(|s| s.rollback_slot.is_some())
                .unwrap_or(false),
        })
    } else {
        None
    };

    let status = SystemStatus {
        version: env!("CARGO_PKG_VERSION").to_string(),
        slot,
        channel,
        mode,
        health: health.to_string(),
        updates_available,
        bootc_available,
        detailed,
    };

    if args.json {
        println!("{}", serde_json::to_string_pretty(&status)?);
    } else {
        print_status(&status);
    }

    Ok(())
}

fn print_status(status: &SystemStatus) {
    println!("{}", "LifeOS System Status".bold().blue());
    println!();

    println!("  {}: {}", "Version".bold(), status.version);
    println!("  {}: {}", "Slot".bold(), status.slot);
    println!("  {}: {}", "Channel".bold(), status.channel);
    println!("  {}: {}", "Mode".bold(), status.mode);

    // Health with color
    let health_color = if status.health == "healthy" {
        status.health.green()
    } else if status.health.starts_with("degraded") {
        status.health.yellow()
    } else {
        status.health.red()
    };
    println!("  {}: {}", "Health".bold(), health_color);

    // Updates
    if status.updates_available {
        println!("  {}: {}", "Updates".bold(), "Available".yellow());
    } else {
        println!("  {}: {}", "Updates".bold(), "Up to date".green());
    }

    // Bootc availability
    if status.bootc_available {
        println!("  {}: {}", "bootc".bold(), "Available".green());
    } else {
        println!("  {}: {}", "bootc".bold(), "Not available".yellow());
    }

    // Detailed info
    if let Some(detailed) = &status.detailed {
        println!();
        println!("{}", "Detailed Information".bold());
        if let Some(ref bootc) = detailed.bootc_status {
            println!("  Booted image: {}", bootc);
        }
        println!(
            "  Rollback available: {}",
            if detailed.rollback_available {
                "Yes".green()
            } else {
                "No".yellow()
            }
        );
    }
}

#[derive(serde::Serialize)]
struct SystemStatus {
    version: String,
    slot: String,
    channel: String,
    mode: String,
    health: String,
    updates_available: bool,
    bootc_available: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    detailed: Option<DetailedStatus>,
}

#[derive(serde::Serialize)]
struct DetailedStatus {
    bootc_status: Option<String>,
    rollback_available: bool,
}
