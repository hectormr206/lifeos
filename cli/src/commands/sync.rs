use clap::Subcommand;
use colored::Colorize;
use std::process::Command;

const SYNC_SERVICES: [&str; 2] = ["lifeos-sync.service", "syncthing.service"];
const LAST_SYNC_FILE: &str = "/var/lib/lifeos/sync/last-sync.json";

#[derive(Subcommand)]
pub enum SyncCommands {
    /// Show synchronization status
    Status,
    /// Trigger synchronization immediately
    Now {
        /// Do not trigger, only show what would run
        #[arg(long)]
        dry_run: bool,
    },
}

pub async fn execute(cmd: SyncCommands) -> anyhow::Result<()> {
    match cmd {
        SyncCommands::Status => cmd_status(),
        SyncCommands::Now { dry_run } => cmd_now(dry_run),
    }
}

fn cmd_status() -> anyhow::Result<()> {
    println!("{}", "Sync status".bold().blue());
    let mut found_any = false;

    for service in SYNC_SERVICES {
        if service_exists(service) {
            found_any = true;
            let active = service_is_active(service);
            println!(
                "  {} {} ({})",
                if active {
                    "OK".green().to_string()
                } else {
                    "!!".yellow().to_string()
                },
                service.cyan(),
                if active { "active" } else { "inactive" }
            );
        }
    }

    if !found_any {
        println!(
            "  {}",
            "No known sync service found (lifeos-sync or syncthing).".yellow()
        );
    }

    if let Ok(content) = std::fs::read_to_string(LAST_SYNC_FILE) {
        println!();
        println!("  last_sync_file: {}", LAST_SYNC_FILE.cyan());
        println!("  {}", content.trim());
    }

    Ok(())
}

fn cmd_now(dry_run: bool) -> anyhow::Result<()> {
    let selected = SYNC_SERVICES
        .into_iter()
        .find(|service| service_exists(service));
    let Some(service) = selected else {
        anyhow::bail!(
            "No sync service detected (expected lifeos-sync.service or syncthing.service)"
        );
    };

    if dry_run {
        println!("{}", "Sync dry-run".bold().blue());
        println!(
            "  would run: {}",
            format!("systemctl start {}", service).cyan()
        );
        return Ok(());
    }

    let started = run_systemctl_start(service)?;
    if started {
        println!("{}", "Sync trigger sent".green().bold());
        println!("  service: {}", service.cyan());
    } else {
        anyhow::bail!("Failed to start sync service {}", service);
    }

    Ok(())
}

fn service_exists(service: &str) -> bool {
    Command::new("systemctl")
        .args(["status", service])
        .output()
        .map(|o| o.status.success() || !o.stdout.is_empty() || !o.stderr.is_empty())
        .unwrap_or(false)
}

fn service_is_active(service: &str) -> bool {
    Command::new("systemctl")
        .args(["is-active", "--quiet", service])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn run_systemctl_start(service: &str) -> anyhow::Result<bool> {
    if Command::new("systemctl")
        .args(["start", service])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
    {
        return Ok(true);
    }

    if Command::new("sudo")
        .args(["-n", "systemctl", "start", service])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
    {
        return Ok(true);
    }

    let interactive = Command::new("sudo")
        .args(["systemctl", "start", service])
        .status()?;
    Ok(interactive.success())
}
