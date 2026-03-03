use clap::Args;
use colored::Colorize;
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
