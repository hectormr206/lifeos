use crate::system;
use colored::Colorize;

pub async fn execute() -> anyhow::Result<()> {
    println!("{}", "🔄 Rolling back system...".yellow().bold());

    // Check if bootc is available
    if !system::is_bootc_available() {
        anyhow::bail!("bootc is not available on this system");
    }

    // Get current status to show what's available
    match system::get_bootc_status() {
        Ok(status) => {
            println!("Current boot: {}", status.booted_slot);

            if let Some(rollback) = &status.rollback_slot {
                println!("Rollback target: {}", rollback);
            } else {
                println!("{}", "⚠️  No rollback target available".yellow());
                println!(
                    "{}",
                    "   The system may not have a previous state to roll back to."
                );
                return Ok(());
            }
        }
        Err(e) => {
            println!(
                "{}",
                format!("⚠️  Could not get bootc status: {}", e).yellow()
            );
        }
    }

    // In a real implementation, we might want to ask for confirmation
    // For now, proceed with the rollback

    match system::perform_rollback().await {
        Ok(_) => {
            println!("{}", "✅ Rollback staged successfully".green().bold());
            println!("{}", "   System will roll back on next reboot".blue());
            println!("{}", "   Run 'reboot' to complete the rollback".dimmed());
        }
        Err(e) => {
            anyhow::bail!("Rollback failed: {}", e);
        }
    }

    Ok(())
}
