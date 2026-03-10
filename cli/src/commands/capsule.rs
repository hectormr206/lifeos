use anyhow::{bail, Context, Result};
use clap::Subcommand;
use colored::*;
use std::fs;
use std::path::Path;
use std::process::Command;

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
                "-C".to_string(),
                home_dir.to_string_lossy().to_string(),
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

            let tar_status = Command::new("tar").args(&tar_opts).status()?;

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
                println!(
                    "{} Life Capsule exported securely to: {}",
                    "✓".green(),
                    output
                );
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

            println!(
                "{} Life Capsule restored successfully. Reboot recommended.",
                "✓".green()
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::OnceLock;
    use std::time::{SystemTime, UNIX_EPOCH};
    use tokio::sync::Mutex;

    static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

    fn unique_suffix() -> String {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos().to_string())
            .unwrap_or_else(|_| "0".to_string())
    }

    fn write_executable(path: &Path, content: &str) {
        std::fs::write(path, content).unwrap();
        let mut perms = std::fs::metadata(path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(path, perms).unwrap();
    }

    #[tokio::test]
    async fn capsule_export_restore_pipeline_works_with_tools() {
        let _guard = ENV_LOCK.get_or_init(|| Mutex::new(())).lock().await;

        let base = std::env::temp_dir().join(format!("life-capsule-test-{}", unique_suffix()));
        let home = base.join("home");
        let bin = base.join("bin");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::create_dir_all(home.join(".config/lifeos")).unwrap();
        std::fs::write(
            home.join(".config/lifeos/settings.toml"),
            "profile = \"test\"\n",
        )
        .unwrap();

        let flatpak_log = base.join("flatpak.log");
        write_executable(
            &bin.join("flatpak"),
            &format!(
                "#!/usr/bin/env sh\nif [ \"$1\" = \"list\" ]; then\necho \"org.test.App\"\nexit 0\nfi\nif [ \"$1\" = \"install\" ]; then\necho \"$@\" >> \"{}\"\nexit 0\nfi\nexit 0\n",
                flatpak_log.display()
            ),
        );
        write_executable(
            &bin.join("tar"),
            "#!/usr/bin/env sh\nif [ \"$1\" = \"czf\" ]; then\necho \"archive\" > \"$2\"\nexit 0\nfi\nif [ \"$1\" = \"xzf\" ]; then\nmkdir -p \"$4/.config/lifeos\"\necho \"restored\" > \"$4/.config/lifeos/restored_from_capsule\"\nmkdir -p \"$4/.local/share/lifeos\"\necho \"org.test.App\" > \"$4/.local/share/lifeos/flatpak_list.txt\"\nexit 0\nfi\nexit 1\n",
        );
        write_executable(
            &bin.join("age"),
            "#!/usr/bin/env sh\nout=\"\"\nlast=\"\"\nwhile [ $# -gt 0 ]; do\n  case \"$1\" in\n    -o)\n      out=\"$2\"\n      shift 2\n      ;;\n    -r|-i)\n      shift 2\n      ;;\n    -d)\n      shift\n      ;;\n    *)\n      last=\"$1\"\n      shift\n      ;;\n  esac\ndone\ncp \"$last\" \"$out\"\n",
        );

        let old_home = std::env::var("HOME").ok();
        let old_path = std::env::var("PATH").ok();
        std::env::set_var("HOME", &home);
        std::env::set_var(
            "PATH",
            format!("{}:{}", bin.display(), old_path.clone().unwrap_or_default()),
        );

        let capsule_path = base.join("backup.capsule");
        execute(CapsuleCommands::Export {
            recipient: "age1testrecipient".to_string(),
            output: capsule_path.to_string_lossy().to_string(),
        })
        .await
        .unwrap();
        assert!(capsule_path.exists());

        std::fs::remove_file(home.join(".config/lifeos/settings.toml")).unwrap();

        execute(CapsuleCommands::Restore {
            identity: base.join("identity.txt").to_string_lossy().to_string(),
            path: capsule_path.to_string_lossy().to_string(),
        })
        .await
        .unwrap();

        assert!(
            home.join(".config/lifeos/restored_from_capsule").exists(),
            "restore marker file should be created by fake tar extract"
        );

        match old_home {
            Some(val) => std::env::set_var("HOME", val),
            None => std::env::remove_var("HOME"),
        }
        match old_path {
            Some(val) => std::env::set_var("PATH", val),
            None => std::env::remove_var("PATH"),
        }
        std::fs::remove_dir_all(base).ok();
    }
}
