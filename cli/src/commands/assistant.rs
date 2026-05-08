use clap::Subcommand;
use colored::Colorize;
use std::path::PathBuf;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum AssistantCommands {
    /// Show assistant access channels status (launcher/terminal/shortcut)
    Status,
    /// Install local launcher entry (~/.local/share/applications)
    InstallLauncher,
    /// Ask assistant from terminal channel
    Ask { prompt: String },
    /// Open assistant overlay window
    Open,
}

pub async fn execute(cmd: AssistantCommands) -> anyhow::Result<()> {
    match cmd {
        AssistantCommands::Status => cmd_status().await,
        AssistantCommands::InstallLauncher => cmd_install_launcher(),
        AssistantCommands::Ask { prompt } => cmd_ask(&prompt).await,
        AssistantCommands::Open => cmd_open().await,
    }
}

async fn cmd_status() -> anyhow::Result<()> {
    let launcher_path = launcher_desktop_path();
    let launcher_ok = launcher_path.exists();

    let shortcut_ok =
        match daemon_client::get_json::<serde_json::Value>("/api/v1/shortcuts/list").await {
            Ok(body) => body["shortcuts"]
                .as_array()
                .map(|items| {
                    items.iter().any(|item| {
                        item["name"]
                            .as_str()
                            .map(|name| name == "toggle-overlay")
                            .unwrap_or(false)
                    })
                })
                .unwrap_or(false),
            _ => false,
        };

    println!("{}", "Assistant access channels".bold().blue());
    println!("  terminal: {}", "life assistant ask \"...\"".cyan());
    println!(
        "  launcher: {} ({})",
        if launcher_ok {
            "installed".green().to_string()
        } else {
            "missing".yellow().to_string()
        },
        launcher_path.display()
    );
    println!(
        "  shortcut: {} (Super+Space)",
        if shortcut_ok {
            "available".green().to_string()
        } else {
            "unavailable".yellow().to_string()
        }
    );

    Ok(())
}

fn cmd_install_launcher() -> anyhow::Result<()> {
    let path = launcher_desktop_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let desktop_entry = r#"[Desktop Entry]
Type=Application
Name=LifeOS Assistant
Comment=Open the LifeOS AI assistant
Exec=life assistant open
Terminal=false
Categories=Utility;Development;
StartupNotify=true
"#;
    std::fs::write(&path, desktop_entry)?;
    println!("{}", "Assistant launcher installed".green().bold());
    println!("  path: {}", path.display().to_string().cyan());
    Ok(())
}

async fn cmd_ask(prompt: &str) -> anyhow::Result<()> {
    let payload = serde_json::json!({
        "message": prompt,
        "stream": false
    });
    let body: serde_json::Value = daemon_client::post_json("/api/v1/ai/chat", &payload)
        .await
        .inspect_err(|e| {
            if e.to_string().contains("is lifeosd running") {
                println!(
                    "{}",
                    "Cannot connect to lifeosd. Is the daemon running?".red()
                );
                println!("  Try: {}", "sudo systemctl start lifeosd".cyan());
            }
        })?;
    println!("{}", "Assistant response".bold().blue());
    println!("{}", body["response"].as_str().unwrap_or(""));
    Ok(())
}

async fn cmd_open() -> anyhow::Result<()> {
    daemon_client::post_empty::<serde_json::Value>("/api/v1/overlay/show")
        .await
        .inspect_err(|e| {
            if e.to_string().contains("is lifeosd running") {
                println!(
                    "{}",
                    "Cannot connect to lifeosd. Is the daemon running?".red()
                );
            }
        })?;
    println!("{}", "Assistant overlay opened".green().bold());
    Ok(())
}

fn launcher_desktop_path() -> PathBuf {
    let base = std::env::var("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            dirs::home_dir()
                .unwrap_or_else(|| PathBuf::from("."))
                .join(".local")
                .join("share")
        });
    base.join("applications").join("lifeos-assistant.desktop")
}
