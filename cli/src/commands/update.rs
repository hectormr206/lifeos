use crate::config;
use crate::daemon_client;
use crate::system;
use clap::Args;
use clap::Subcommand;
use colored::Colorize;

const CANONICAL_CHANNELS: [&str; 3] = ["stable", "candidate", "edge"];

#[derive(Subcommand)]
pub enum UpdateSubcommand {
    /// Show canonical bootc update status and local policy
    Status,
}

#[derive(Args, Default)]
pub struct UpdateArgs {
    #[command(subcommand)]
    pub command: Option<UpdateSubcommand>,
    /// Simulate update without applying
    #[arg(long = "dry-run", alias = "dry")]
    pub dry_run: bool,
    /// Reboot immediately after update
    #[arg(long)]
    pub now: bool,
    /// Preferred release channel (stable, candidate, edge)
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

    validate_channel(&channel)?;

    if args.dry_run {
        println!(
            "{}",
            format!(
                "📋 Simulating bootc update check for channel preference: {}",
                channel
            )
            .blue()
            .bold()
        );
        println!(
            "{}",
            "   Canonical channels: stable, candidate, edge".dimmed()
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
            format!(
                "🔄 Staging bootc update for channel preference: {}",
                channel
            )
            .blue()
            .bold()
        );
        println!(
            "{}",
            "   `life update` follows the currently selected bootc image; switch tracks with `bootc switch` first when needed.".dimmed()
        );

        // Check if bootc is available
        if !system::is_bootc_available() {
            anyhow::bail!("bootc is not available on this system");
        }

        // Perform the update
        match system::perform_update(&channel, false).await {
            Ok(result) => {
                println!(
                    "{}",
                    "✅ Next deployment staged successfully".green().bold()
                );

                if !result.changes.is_empty() {
                    println!("\nChanges:");
                    for change in result.changes {
                        println!("  • {}", change);
                    }
                }

                if args.now {
                    println!(
                        "{}",
                        "\n🔄 Rebooting into the staged deployment..."
                            .yellow()
                            .bold()
                    );
                    system::request_reboot()?;
                } else {
                    println!(
                        "{}",
                        "\n💡 The update is staged and will activate on the next reboot".blue()
                    );
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

    let channel = config::load_config()
        .ok()
        .map(|c| c.updates.channel)
        .unwrap_or_else(|| "stable".to_string());
    validate_channel(&channel)?;
    println!(
        "  {}: {}",
        "Configured channel preference".bold(),
        channel.cyan()
    );
    println!(
        "  {}",
        "bootc status remains the runtime authority for what is actually booted/staged.".dimmed()
    );

    if !system::is_bootc_available() {
        println!("  {}: {}", "bootc".bold(), "not available".yellow());
        return Ok(());
    }

    match system::get_bootc_status() {
        Ok(status) => {
            println!("  {}: {}", "Booted image".bold(), status.booted_slot);
            if let Some(staged) = status.staged {
                println!("  {}: {}", "Staged image".bold(), staged.version);
            }
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

    match system::check_updates(&channel) {
        Ok(true) => println!("  {}: {}", "Updates available".bold(), "yes".green()),
        Ok(false) => println!("  {}: {}", "Updates available".bold(), "no".green()),
        Err(e) => println!("  {}: {}", "Update check".bold(), e.to_string().yellow()),
    }

    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/updates/status", daemon_client::daemon_url());
    if let Ok(response) = client.get(url).send().await {
        if response.status().is_success() {
            let body: serde_json::Value = response.json().await?;
            println!();
            println!("{}", "Daemon policy metadata".bold());
            println!(
                "  {}: {}",
                "Schedule type".bold(),
                body["schedule_type"].as_str().unwrap_or("unknown")
            );
            println!(
                "  {}: {}",
                "Check every (hours)".bold(),
                body["check_frequency_hours"].as_u64().unwrap_or(0)
            );
        }
    }

    Ok(())
}

fn validate_channel(channel: &str) -> anyhow::Result<()> {
    if CANONICAL_CHANNELS.contains(&channel) {
        return Ok(());
    }

    anyhow::bail!(
        "unsupported channel '{}'; use one of: {}",
        channel,
        CANONICAL_CHANNELS.join(", ")
    )
}
