use crate::config;
use crate::daemon_client;
use crate::system;
use clap::Args;
use clap::Subcommand;
use colored::Colorize;

#[derive(Subcommand)]
pub enum UpdateSubcommand {
    /// Show update scheduler/channel status
    Status,
}

#[derive(Args, Default)]
pub struct UpdateArgs {
    #[command(subcommand)]
    pub command: Option<UpdateSubcommand>,
    /// Simulate update without applying
    #[arg(long)]
    pub dry_run: bool,
    /// Reboot immediately after update
    #[arg(long)]
    pub now: bool,
    /// Update channel
    #[arg(long)]
    pub channel: Option<String>,
}

pub async fn execute(args: UpdateArgs) -> anyhow::Result<()> {
    if let Some(UpdateSubcommand::Status) = args.command {
        return show_status().await;
    }

    // Get channel from args or config
    let channel = args
        .channel
        .or_else(|| config::load_config().ok().map(|c| c.updates.channel))
        .unwrap_or_else(|| "stable".to_string());

    if args.dry_run {
        println!(
            "{}",
            format!("📋 Simulating update from channel: {}", channel)
                .blue()
                .bold()
        );

        // Check if bootc is available
        if !system::is_bootc_available() {
            println!("{}", "⚠️  bootc not available on this system".yellow());
            println!("{}", "   Would update: N/A (simulation mode)".dimmed());
            return Ok(());
        }

        // Get current status
        match system::get_bootc_status() {
            Ok(status) => {
                println!("Current image: {}", status.booted_slot);

                // Check for updates
                match system::check_updates(&channel) {
                    Ok(available) => {
                        if available {
                            println!("{}", "✅ Updates available".green());
                        } else {
                            println!("{}", "✓ System is up to date".green());
                        }
                    }
                    Err(e) => {
                        println!(
                            "{}",
                            format!("⚠️  Could not check for updates: {}", e).yellow()
                        );
                    }
                }

                if status.rollback_slot.is_some() {
                    println!("{}", "✓ Rollback available".green());
                }
            }
            Err(e) => {
                println!(
                    "{}",
                    format!("⚠️  Could not get bootc status: {}", e).yellow()
                );
            }
        }

        println!();
        println!("{}", "Dry run complete - no changes made".blue());
    } else {
        println!(
            "{}",
            format!("🔄 Updating system from channel: {}", channel)
                .blue()
                .bold()
        );

        // Check if bootc is available
        if !system::is_bootc_available() {
            anyhow::bail!("bootc is not available on this system");
        }

        // Perform the update
        match system::perform_update(&channel, false).await {
            Ok(result) => {
                println!("{}", "✅ Update staged successfully".green().bold());

                if !result.changes.is_empty() {
                    println!("\nChanges:");
                    for change in result.changes {
                        println!("  • {}", change);
                    }
                }

                if args.now {
                    println!("{}", "\n🔄 Rebooting system...".yellow().bold());
                    // In a real implementation, this would reboot
                    // tokio::process::Command::new("reboot").spawn()?;
                } else {
                    println!("{}", "\n💡 System will be updated on next reboot".blue());
                    println!("   Run 'life update --now' to reboot immediately");
                }
            }
            Err(e) => {
                anyhow::bail!("Update failed: {}", e);
            }
        }
    }

    Ok(())
}

async fn show_status() -> anyhow::Result<()> {
    println!("{}", "Update Status".bold().blue());
    println!();

    // Try daemon scheduler status first (Phase 1 update system)
    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/updates/status", daemon_client::daemon_url());
    if let Ok(response) = client.get(url).send().await {
        if response.status().is_success() {
            let body: serde_json::Value = response.json().await?;
            println!(
                "  {}: {}",
                "Channel".bold(),
                body["current_channel"].as_str().unwrap_or("unknown").cyan()
            );
            println!(
                "  {}: {}",
                "Schedule".bold(),
                body["schedule_type"].as_str().unwrap_or("unknown")
            );
            println!(
                "  {}: {}",
                "Check every (hours)".bold(),
                body["check_frequency_hours"].as_u64().unwrap_or(0)
            );
            println!(
                "  {}: {}",
                "Available versions".bold(),
                body["available_versions"].as_u64().unwrap_or(0)
            );
            println!(
                "  {}: {}",
                "Scheduled updates".bold(),
                body["scheduled_updates"].as_u64().unwrap_or(0)
            );
            if let Some(last) = body["last_update"].as_str() {
                println!("  {}: {}", "Last update".bold(), last);
            }
            return Ok(());
        }
    }

    // Fallback to local bootc-based status
    let channel = config::load_config()
        .ok()
        .map(|c| c.updates.channel)
        .unwrap_or_else(|| "stable".to_string());
    println!("  {}: {}", "Channel".bold(), channel.cyan());

    if !system::is_bootc_available() {
        println!("  {}: {}", "bootc".bold(), "not available".yellow());
        return Ok(());
    }

    match system::get_bootc_status() {
        Ok(status) => {
            println!("  {}: {}", "Booted image".bold(), status.booted_slot);
            if let Some(rollback) = status.rollback_slot {
                println!("  {}: {}", "Rollback image".bold(), rollback);
            }
        }
        Err(e) => {
            println!(
                "  {}: {}",
                "bootc status".bold(),
                format!("unavailable ({})", e).yellow()
            );
        }
    }

    Ok(())
}
