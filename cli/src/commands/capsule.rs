use clap::Subcommand;
use std::process::Command;
use anyhow::{Context, Result, bail};
use colored::*;
use std::path::Path;
use std::fs;

#[derive(Subcommand)]
pub enum CapsuleCommands {
    /// Export system state (config, apps, dotfiles) to an encrypted capsule
    Export {
        /// Recipient public key (age format)
        #[arg(short, long)]
        recipient: String,
        /// Output file path (.capsule)
        #[arg(short, long, default_value = "lifeos_backup.capsule")]
        output: String,
    },
    /// Restore system state from an encrypted capsule
    Restore {
        /// Identity file (private key in age format)
        #[arg(short, long)]
        identity: String,
        /// Input capsule file
        path: String,
    },
}

pub async fn execute(args: CapsuleCommands) -> Result<()> {
    match args {
        CapsuleCommands::Export { recipient, output } => {
            println!("{} Assembling life capsule...", "=>".cyan());
            let home_dir = dirs::home_dir().context("Could not find home directory")?;
            
            // 1. Generate flatpak list
            let flatpak_list_path = home_dir.join(".local/share/lifeos/flatpak_list.txt");
            if let Some(parent) = flatpak_list_path.parent() {
                fs::create_dir_all(parent)?;
            }
            
            println!("   {} Capturing Flatpak state...", "*".yellow());
            let flatpak_out = Command::new("flatpak")
                .args(["list", "--app", "--columns=application"])
                .output();
                
            if let Ok(out) = flatpak_out {
                fs::write(&flatpak_list_path, out.stdout)?;
            }
            
            // 2. Tar the contents
            let tar_path = "/tmp/lifeos_stage.tar.gz";
            println!("   {} Packaging configuration...", "*".yellow());
            
            let mut tar_opts = vec![
                "czf".to_string(), 
                tar_path.to_string(), 
                "-C".to_string(), home_dir.to_string_lossy().to_string(),
            ];
            
            let targets = [
                ".config/lifeos",          
                ".config",                 
                ".local/share/lifeos/flatpak_list.txt", 
            ];
            
            for target in targets {
                if home_dir.join(target).exists() {
                    tar_opts.push(target.to_string());
                }
            }
            
            let tar_status = Command::new("tar")
                .args(&tar_opts)
                .status()?;
                
            if !tar_status.success() {
                bail!("Failed to create tar archive");
            }
            
            // 3. Encrypt with age
            println!("   {} Encrypting capsule with age...", "*".yellow());
            let age_status = Command::new("age")
                .args(["-r", &recipient, "-o", &output, tar_path])
                .status()
                .context("Failed to run age encryption. Make sure `age` is installed")?;
                
            // Cleanup
            let _ = fs::remove_file(tar_path);
            let _ = fs::remove_file(&flatpak_list_path);
            
            if age_status.success() {
                println!("{} Life Capsule exported securely to: {}", "✓".green(), output);
            } else {
                bail!("Encryption failed");
            }
        }
        CapsuleCommands::Restore { identity, path } => {
            println!("{} Restoring from life capsule: {}", "=>".cyan(), path);
            let home_dir = dirs::home_dir().context("Could not find home directory")?;
            
            if !Path::new(&path).exists() {
                bail!("Capsule file not found: {}", path);
            }
            
            let tar_path = "/tmp/lifeos_restore.tar.gz";
            
            // 1. Decrypt with age
            println!("   {} Decrypting capsule...", "*".yellow());
            let age_status = Command::new("age")
                .args(["-d", "-i", &identity, "-o", tar_path, &path])
                .status()
                .context("Failed to run age decryption")?;
                
            if !age_status.success() {
                let _ = fs::remove_file(tar_path);
                bail!("Decryption failed. Check your identity key.");
            }
            
            // 2. Extract tar
            println!("   {} Restoring configuration...", "*".yellow());
            let tar_status = Command::new("tar")
                .args(["xzf", tar_path, "-C", &home_dir.to_string_lossy()])
                .status()?;
                
            let _ = fs::remove_file(tar_path);
            
            if !tar_status.success() {
                bail!("Failed to extract archive");
            }
            
            // 3. Reinstall flatpaks if list exists
            let flatpak_list_path = home_dir.join(".local/share/lifeos/flatpak_list.txt");
            if flatpak_list_path.exists() {
                println!("   {} Restoring applications (Flatpaks)...", "*".yellow());
                let content = fs::read_to_string(&flatpak_list_path)?;
                for line in content.lines() {
                    let app = line.trim();
                    if !app.is_empty() {
                        let _ = Command::new("flatpak")
                            .args(["install", "-y", "flathub", app])
                            .status();
                    }
                }
                let _ = fs::remove_file(flatpak_list_path);
            }
            
            println!("{} Life Capsule restored successfully. Reboot recommended.", "✓".green());
        }
    }
    Ok(())
}
