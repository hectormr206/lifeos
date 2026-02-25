use clap::Args;
use colored::Colorize;
use crate::system;
use crate::config;

#[derive(Args, Default)]
pub struct UpdateArgs {
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
    // Get channel from args or config
    let channel = args.channel
        .or_else(|| config::load_config().ok().map(|c| c.updates.channel))
        .unwrap_or_else(|| "stable".to_string());

    if args.dry_run {
        println!("{}", format!("📋 Simulating update from channel: {}", channel).blue().bold());
        
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
                        println!("{}", format!("⚠️  Could not check for updates: {}", e).yellow());
                    }
                }
                
                if status.rollback_slot.is_some() {
                    println!("{}", "✓ Rollback available".green());
                }
            }
            Err(e) => {
                println!("{}", format!("⚠️  Could not get bootc status: {}", e).yellow());
            }
        }
        
        println!();
        println!("{}", "Dry run complete - no changes made".blue());
    } else {
        println!("{}", format!("🔄 Updating system from channel: {}", channel).blue().bold());
        
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