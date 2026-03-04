use clap::Args;
use colored::Colorize;
use dialoguer::Select;
use std::path::PathBuf;

use crate::config;

#[derive(Args, Default)]
pub struct InitArgs {
    /// Force reinitialization even if already initialized
    #[arg(long)]
    pub force: bool,
    /// Skip AI setup
    #[arg(long)]
    pub skip_ai: bool,
    /// Bootstrap profile (user|developer|server)
    #[arg(long, value_parser = ["user", "developer", "server"])]
    pub profile: Option<String>,
    /// Open interactive TUI profile selector
    #[arg(long)]
    pub tui: bool,
}

pub async fn execute(args: InitArgs) -> anyhow::Result<()> {
    println!("{}", "🚀 Initializing LifeOS...".bold().blue());
    println!();

    // Check if already initialized
    let config_path = config::find_config_file();
    if config_path.is_some() && !args.force {
        println!("{}", "⚠️  LifeOS is already initialized".yellow());
        println!("{}", "   Use --force to reinitialize".dimmed());
        return Ok(());
    }

    // Step 1: Create config directory
    print!("Creating configuration directory... ");
    let config_dir = match config::ensure_config_dir() {
        Ok(dir) => {
            println!("{}", "✓".green());
            dir
        }
        Err(e) => {
            println!("{}", "✗".red());
            anyhow::bail!("Failed to create config directory: {}", e);
        }
    };

    // Step 2: Create default configuration
    print!("Creating default configuration... ");
    let lifeos_config_path = match config::create_default_config() {
        Ok(path) => {
            println!("{}", "✓".green());
            path
        }
        Err(e) => {
            println!("{}", "✗".red());
            anyhow::bail!("Failed to create config: {}", e);
        }
    };

    let selected_profile = resolve_bootstrap_profile(args.profile.as_deref(), args.tui)?;
    apply_bootstrap_profile(&lifeos_config_path, selected_profile, args.skip_ai).await?;

    // Step 3: Create data directories
    print!("Creating data directories... ");
    match create_data_directories().await {
        Ok(_) => println!("{}", "✓".green()),
        Err(e) => {
            println!("{}", "✗".red());
            eprintln!("Warning: Failed to create data directories: {}", e);
        }
    }

    // Step 4: Check system requirements
    println!();
    println!("{}", "System Requirements:".bold());
    check_system_requirements().await;

    // Step 5: AI setup (unless skipped)
    if !args.skip_ai {
        println!();
        println!("{}", "AI Setup:".bold());
        setup_ai().await?;
    }

    // Summary
    println!();
    println!("{}", "✅ LifeOS initialized successfully!".green().bold());
    println!();
    println!("Configuration: {}", lifeos_config_path.display());
    println!("Config directory: {}", config_dir.display());
    println!("Bootstrap profile: {}", selected_profile.as_str().cyan());
    println!();
    println!("Next steps:");
    println!(
        "  • Run {} to view your configuration",
        "life config show".cyan()
    );
    println!("  • Run {} to check system status", "life status".cyan());
    println!("  • Run {} to start AI services", "life ai start".cyan());

    Ok(())
}

async fn create_data_directories() -> anyhow::Result<()> {
    let data_dirs = vec![
        get_data_dir()?.join("capsules"),
        get_data_dir()?.join("logs"),
        get_data_dir()?.join("cache"),
        get_data_dir()?.join("bootstrap"),
    ];

    for dir in data_dirs {
        std::fs::create_dir_all(&dir)?;
    }

    Ok(())
}

fn get_data_dir() -> anyhow::Result<PathBuf> {
    dirs::data_dir()
        .map(|d| d.join("lifeos"))
        .ok_or_else(|| anyhow::anyhow!("Could not determine data directory"))
}

async fn check_system_requirements() {
    // Check bootc
    let bootc_check = std::process::Command::new("bootc")
        .arg("--version")
        .output();

    match bootc_check {
        Ok(output) if output.status.success() => {
            let version = String::from_utf8_lossy(&output.stdout);
            println!("  {} bootc: {}", "✓".green(), version.trim());
        }
        _ => {
            println!(
                "  {} bootc: {}",
                "✗".red(),
                "not found (optional for container installs)"
            );
        }
    }

    // Check systemd
    let systemd_check = std::process::Command::new("systemctl")
        .arg("--version")
        .output();

    match systemd_check {
        Ok(output) if output.status.success() => {
            println!("  {} systemd: {}", "✓".green(), "available");
        }
        _ => {
            println!(
                "  {} systemd: {}",
                "⚠".yellow(),
                "not available (some features disabled)"
            );
        }
    }

    // Check podman
    let podman_check = std::process::Command::new("podman")
        .arg("--version")
        .output();

    match podman_check {
        Ok(output) if output.status.success() => {
            let version = String::from_utf8_lossy(&output.stdout);
            println!("  {} podman: {}", "✓".green(), version.trim());
        }
        _ => {
            println!(
                "  {} podman: {}",
                "⚠".yellow(),
                "not found (container features disabled)"
            );
        }
    }
}

async fn setup_ai() -> anyhow::Result<()> {
    // Check if llama-server is installed
    let server_check = std::process::Command::new("which")
        .arg("llama-server")
        .output();

    match server_check {
        Ok(output) if output.status.success() => {
            println!("  {} llama-server: {}", "✓".green(), "installed");

            // Check if llama-server service is running
            let service_check = std::process::Command::new("systemctl")
                .args(["is-active", "llama-server"])
                .output();

            match service_check {
                Ok(output) if output.status.success() => {
                    println!("  {} llama-server service: {}", "✓".green(), "running");
                }
                _ => {
                    println!("  {} llama-server service: {}", "⚠".yellow(), "not running");
                    println!("    Run {} to start it", "life ai start".cyan());
                }
            }
        }
        _ => {
            println!("  {} llama-server: {}", "⚠".yellow(), "not installed");
            println!("    Should be bundled with LifeOS image");
        }
    }

    // Check for GPU
    let nvidia_check = std::process::Command::new("nvidia-smi").output();

    match nvidia_check {
        Ok(output) if output.status.success() => {
            println!("  {} GPU (NVIDIA): {}", "✓".green(), "available");
        }
        _ => {
            let amd_check = std::process::Command::new("lspci").output();

            if let Ok(output) = amd_check {
                let output_str = String::from_utf8_lossy(&output.stdout);
                if output_str.contains("AMD") && output_str.contains("VGA") {
                    println!("  {} GPU (AMD): {}", "✓".green(), "available");
                } else {
                    println!("  {} GPU: {}", "⚠".yellow(), "not detected (CPU-only mode)");
                }
            } else {
                println!("  {} GPU: {}", "⚠".yellow(), "not detected (CPU-only mode)");
            }
        }
    }

    Ok(())
}

#[derive(Debug, Clone, Copy)]
enum BootstrapProfile {
    User,
    Developer,
    Server,
}

impl BootstrapProfile {
    fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Developer => "developer",
            Self::Server => "server",
        }
    }

    fn from_str(input: &str) -> anyhow::Result<Self> {
        match input.trim().to_lowercase().as_str() {
            "user" => Ok(Self::User),
            "developer" => Ok(Self::Developer),
            "server" => Ok(Self::Server),
            other => anyhow::bail!("Unsupported bootstrap profile '{}'", other),
        }
    }
}

fn resolve_bootstrap_profile(profile: Option<&str>, tui: bool) -> anyhow::Result<BootstrapProfile> {
    if let Some(explicit) = profile {
        return BootstrapProfile::from_str(explicit);
    }

    if tui {
        let items = vec![
            "user - daily desktop profile",
            "developer - tooling and candidate updates",
            "server - conservative headless profile",
        ];
        let selected = Select::new()
            .with_prompt("Select LifeOS bootstrap profile")
            .items(&items)
            .default(0)
            .interact()?;

        let profile = match selected {
            0 => BootstrapProfile::User,
            1 => BootstrapProfile::Developer,
            _ => BootstrapProfile::Server,
        };
        return Ok(profile);
    }

    Ok(BootstrapProfile::User)
}

async fn apply_bootstrap_profile(
    config_path: &std::path::Path,
    profile: BootstrapProfile,
    skip_ai: bool,
) -> anyhow::Result<()> {
    let mut cfg = config::load_config_from(config_path)?;

    match profile {
        BootstrapProfile::User => {
            cfg.updates.channel = "stable".to_string();
            cfg.updates.auto_check = true;
            cfg.updates.auto_apply = false;
            cfg.updates.schedule = "daily".to_string();
            cfg.security.auto_lock = true;
            cfg.security.auto_lock_timeout = 300;
            cfg.ai.enabled = !skip_ai;
        }
        BootstrapProfile::Developer => {
            cfg.updates.channel = "candidate".to_string();
            cfg.updates.auto_check = true;
            cfg.updates.auto_apply = false;
            cfg.updates.schedule = "daily".to_string();
            cfg.security.auto_lock = false;
            cfg.security.auto_lock_timeout = 0;
            cfg.ai.enabled = !skip_ai;
        }
        BootstrapProfile::Server => {
            cfg.updates.channel = "stable".to_string();
            cfg.updates.auto_check = true;
            cfg.updates.auto_apply = true;
            cfg.updates.schedule = "daily".to_string();
            cfg.security.auto_lock = false;
            cfg.security.auto_lock_timeout = 0;
            cfg.ai.enabled = false;
        }
    }

    if skip_ai {
        cfg.ai.enabled = false;
    }

    config::save_config(&cfg, config_path)?;
    save_bootstrap_receipt(profile, config_path).await?;
    Ok(())
}

async fn save_bootstrap_receipt(
    profile: BootstrapProfile,
    config_path: &std::path::Path,
) -> anyhow::Result<()> {
    let data_dir = get_data_dir()?.join("bootstrap");
    tokio::fs::create_dir_all(&data_dir).await?;
    let receipt = serde_json::json!({
        "profile": profile.as_str(),
        "config_path": config_path.display().to_string(),
        "created_at": chrono::Utc::now().to_rfc3339(),
    });
    tokio::fs::write(
        data_dir.join("last-bootstrap.json"),
        serde_json::to_string_pretty(&receipt)?,
    )
    .await?;
    Ok(())
}
