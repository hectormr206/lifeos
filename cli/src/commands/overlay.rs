use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum OverlayCommands {
    /// Show AI overlay window
    Show,
    /// Hide AI overlay window
    Hide,
    /// Toggle AI overlay visibility
    Toggle,
    /// Send message to AI overlay chat
    Chat { prompt: String },
    /// Capture screen and include in chat
    Screenshot,
    /// Clear overlay chat history
    Clear,
    /// Export chat history
    Export { path: String },
    /// Import chat history
    Import { path: String },
    /// Get overlay status
    Status,
    /// List model selector state used by overlay settings
    Models,
    /// Select default heavy model from overlay selector
    ModelSelect {
        model: String,
        #[arg(long)]
        restart: bool,
    },
    /// Pull model artifacts through overlay selector
    ModelPull {
        model: String,
        #[arg(long)]
        force: bool,
        #[arg(long)]
        restart: bool,
    },
    /// Remove model through overlay selector lifecycle controls
    ModelRemove {
        model: String,
        #[arg(long, default_value_t = true)]
        remove_companion: bool,
        #[arg(long, default_value_t = true)]
        select_fallback: bool,
        #[arg(long)]
        restart: bool,
    },
    /// Pin model to protect it from cleanup workflows
    ModelPin { model: String },
    /// Unpin model to allow cleanup workflows
    ModelUnpin { model: String },
    /// Export model inventory lifecycle state
    ModelsExport { path: String },
    /// Import model inventory lifecycle state
    ModelsImport {
        path: String,
        #[arg(long, default_value_t = false)]
        adopt_pinning: bool,
    },
    /// Configure overlay settings
    Config {
        /// Overlay theme (dark/light/auto)
        #[arg(short, long)]
        theme: Option<String>,
        /// Keyboard shortcut (e.g., "Super+space")
        #[arg(short, long)]
        shortcut: Option<String>,
        /// Window opacity (0.0-1.0)
        #[arg(short, long)]
        opacity: Option<f32>,
        /// Show/hide overlay
        #[arg(short, long)]
        enabled: Option<bool>,
    },
}

pub async fn execute(args: OverlayCommands) -> anyhow::Result<()> {
    match args {
        OverlayCommands::Show => show_overlay().await,
        OverlayCommands::Hide => hide_overlay().await,
        OverlayCommands::Toggle => toggle_overlay().await,
        OverlayCommands::Chat { prompt } => chat(&prompt).await,
        OverlayCommands::Screenshot => screenshot().await,
        OverlayCommands::Clear => clear_chat().await,
        OverlayCommands::Export { path } => export_chat(&path).await,
        OverlayCommands::Import { path } => import_chat(&path).await,
        OverlayCommands::Status => show_status().await,
        OverlayCommands::Models => show_models().await,
        OverlayCommands::ModelSelect { model, restart } => model_select(&model, restart).await,
        OverlayCommands::ModelPull {
            model,
            force,
            restart,
        } => model_pull(&model, force, restart).await,
        OverlayCommands::ModelRemove {
            model,
            remove_companion,
            select_fallback,
            restart,
        } => model_remove(&model, remove_companion, select_fallback, restart).await,
        OverlayCommands::ModelPin { model } => model_pin(&model).await,
        OverlayCommands::ModelUnpin { model } => model_unpin(&model).await,
        OverlayCommands::ModelsExport { path } => models_export(&path).await,
        OverlayCommands::ModelsImport {
            path,
            adopt_pinning,
        } => models_import(&path, adopt_pinning).await,
        OverlayCommands::Config {
            theme,
            shortcut,
            opacity,
            enabled,
        } => configure(theme, shortcut, opacity, enabled).await,
    }
}

async fn show_overlay() -> anyhow::Result<()> {
    println!("{}", "Opening AI overlay...".bold().blue());

    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/overlay/show", daemon_client::daemon_url());

    let response = client.post(url).send().await?;

    if response.status().is_success() {
        println!("{}", "Overlay opened".green());
    } else {
        let status = response.status();
        anyhow::bail!("Failed to open overlay (status: {})", status);
    }

    Ok(())
}

async fn hide_overlay() -> anyhow::Result<()> {
    println!("{}", "Hiding AI overlay...".bold().blue());

    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/overlay/hide", daemon_client::daemon_url());

    let response = client.post(url).send().await?;

    if response.status().is_success() {
        println!("{}", "Overlay hidden".green());
    } else {
        let status = response.status();
        anyhow::bail!("Failed to hide overlay (status: {})", status);
    }

    Ok(())
}

async fn toggle_overlay() -> anyhow::Result<()> {
    println!("{}", "Toggling AI overlay...".bold().blue());

    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/overlay/toggle", daemon_client::daemon_url());

    let response = client.post(url).send().await?;

    if response.status().is_success() {
        println!("{}", "Overlay toggled".green());
    } else {
        let status = response.status();
        anyhow::bail!("Failed to toggle overlay (status: {})", status);
    }

    Ok(())
}

async fn chat(prompt: &str) -> anyhow::Result<()> {
    println!("{} {}", "Message:".bold().green(), prompt.cyan());

    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/overlay/chat", daemon_client::daemon_url());

    let payload = serde_json::json!({
        "message": prompt,
        "include_screen": true
    });

    let response = client.post(url).json(&payload).send().await?;

    if !response.status().is_success() {
        let status = response.status();
        anyhow::bail!("Failed to send message (status: {})", status);
    }

    // Parse response
    if let Ok(body) = response.json::<serde_json::Value>().await {
        if let Some(response) = body.get("response") {
            println!("\n{}", response.as_str().unwrap_or("No response"));
        }
    }

    Ok(())
}

async fn screenshot() -> anyhow::Result<()> {
    println!("{}", "Capturing screen for AI context...".bold().blue());

    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/overlay/screenshot", daemon_client::daemon_url());

    let response = client.post(url).send().await?;

    if response.status().is_success() {
        println!("{}", "Screen captured".green());

        if let Ok(body) = response.json::<serde_json::Value>().await {
            if let Some(path) = body.get("path") {
                println!(
                    "  {}: {}",
                    "Saved to:".dimmed(),
                    path.as_str().unwrap_or("unknown")
                );
            }
        }
    } else {
        let status = response.status();
        anyhow::bail!("Failed to capture screen (status: {})", status);
    }

    Ok(())
}

async fn clear_chat() -> anyhow::Result<()> {
    println!("{}", "Clearing overlay chat history...".bold().yellow());

    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/overlay/clear", daemon_client::daemon_url());

    let response = client.post(url).send().await?;

    if response.status().is_success() {
        println!("{}", "Chat history cleared".green());
    } else {
        let status = response.status();
        anyhow::bail!("Failed to clear chat (status: {})", status);
    }

    Ok(())
}

async fn export_chat(path: &str) -> anyhow::Result<()> {
    println!("{} {}", "Exporting chat to:".bold().blue(), path.cyan());

    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/overlay/export", daemon_client::daemon_url());

    let payload = serde_json::json!({
        "path": path
    });

    let response = client.post(url).json(&payload).send().await?;

    if response.status().is_success() {
        println!("{}", "Chat exported".green());
    } else {
        let status = response.status();
        anyhow::bail!("Failed to export chat (status: {})", status);
    }

    Ok(())
}

async fn import_chat(path: &str) -> anyhow::Result<()> {
    println!("{} {}", "Importing chat from:".bold().blue(), path.cyan());

    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/overlay/import", daemon_client::daemon_url());

    let payload = serde_json::json!({
        "path": path
    });

    let response = client.post(url).json(&payload).send().await?;

    if response.status().is_success() {
        println!("{}", "Chat imported".green());
    } else {
        let status = response.status();
        anyhow::bail!("Failed to import chat (status: {})", status);
    }

    Ok(())
}

async fn show_status() -> anyhow::Result<()> {
    println!("{}", "Overlay Status".bold().blue());
    println!();

    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/overlay/status", daemon_client::daemon_url());

    let response = client.get(url).send().await?;

    if !response.status().is_success() {
        let status = response.status();
        anyhow::bail!("Failed to get status (status: {})", status);
    }

    if let Ok(body) = response.json::<serde_json::Value>().await {
        if let Some(visible) = body.get("visible") {
            let status_str = if visible.as_bool().unwrap_or(false) {
                format!("{}", "Visible".green())
            } else {
                format!("{}", "Hidden".dimmed())
            };
            println!("  Status: {}", status_str);
        }

        if let Some(stats) = body.get("stats") {
            if let Some(total) = stats.get("total_messages") {
                println!("  Messages: {}", total);
            }
            if let Some(shortcut) = stats.get("shortcut") {
                println!("  Shortcut: {}", shortcut.as_str().unwrap_or("Super+space"));
            }
            if let Some(theme) = stats.get("theme") {
                println!("  Theme: {}", theme);
            }
        }

        if let Some(history) = body.get("chat_history") {
            if let Some(msgs) = history.as_array() {
                println!();
                println!("{}", "Recent Messages:".bold());
                for msg in msgs.iter().take(5) {
                    if let Some(role) = msg.get("role") {
                        if let Some(content) = msg.get("content") {
                            let role_display = match role.as_str() {
                                Some("user") => "You".green(),
                                Some("assistant") => "AI".cyan(),
                                _ => "System".dimmed(),
                            };
                            println!("  {}: {}", role_display, content.as_str().unwrap_or(""));
                        }
                    }
                }
            }
        }
    }

    println!();
    println!("Keyboard Shortcut: {}", "Super+Space".cyan());
    println!("Toggle with: {}", "life overlay toggle".cyan());

    Ok(())
}

async fn show_models() -> anyhow::Result<()> {
    println!("{}", "Overlay Model Selector".bold().blue());
    println!();

    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/overlay/models", daemon_client::daemon_url());
    let response = client.get(url).send().await?;
    if !response.status().is_success() {
        anyhow::bail!(
            "Failed to load overlay models (status: {})",
            response.status()
        );
    }

    let body = response.json::<serde_json::Value>().await?;
    println!(
        "  Catalog: {} ({})",
        body["catalog_version"].as_str().unwrap_or("-").cyan(),
        if body["catalog_signature_valid"].as_bool().unwrap_or(false) {
            "signature valid".green()
        } else {
            "signature invalid".red()
        }
    );
    println!(
        "  Configured/Active: {}/{}",
        body["configured_model"].as_str().unwrap_or("none").yellow(),
        body["active_model"].as_str().unwrap_or("none").yellow()
    );
    println!(
        "  Configured mmproj: {}",
        body["configured_mmproj"]
            .as_str()
            .unwrap_or("none")
            .yellow()
    );

    if let Some(models) = body["models"].as_array() {
        println!();
        println!("{}", "Models:".bold());
        for model in models {
            let id = model["id"].as_str().unwrap_or("-");
            let size = model["size"].as_str().unwrap_or("-");
            let installed = model["installed"].as_bool().unwrap_or(false);
            let selected = model["selected"].as_bool().unwrap_or(false);
            let pinned = model["pinned"].as_bool().unwrap_or(false);
            let removed = model["removed_by_user"].as_bool().unwrap_or(false);
            let featured = model["featured"].as_bool().unwrap_or(false);
            let integrity = model["integrity_available"].as_bool().unwrap_or(false);
            let resumable = model["download_resumable"].as_bool().unwrap_or(false);
            let ram = model["recommended_ram_gb"]
                .as_u64()
                .map(|v| format!("{}GB", v))
                .unwrap_or_else(|| "-".to_string());
            let vram = model["recommended_vram_gb"]
                .as_u64()
                .map(|v| format!("{}GB", v))
                .unwrap_or_else(|| "-".to_string());
            let eta = model["estimated_download_seconds"]
                .as_u64()
                .map(|v| format!("{}s", v))
                .unwrap_or_else(|| "-".to_string());
            let badge = if selected && pinned {
                "default+pinned".green().bold().to_string()
            } else if selected {
                "default".green().bold().to_string()
            } else if pinned {
                "pinned".yellow().bold().to_string()
            } else if installed {
                "installed".cyan().to_string()
            } else if removed {
                "removed_by_user".yellow().to_string()
            } else {
                "available".dimmed().to_string()
            };
            let featured_tag = if featured {
                " featured".magenta().to_string()
            } else {
                String::new()
            };
            println!("  - {} ({}) [{}]{}", id.cyan(), size, badge, featured_tag);
            println!(
                "      ram/vram: {}/{}  integrity:{}  resumable:{}  eta:{}",
                ram,
                vram,
                if integrity { "yes".green() } else { "no".red() },
                if resumable { "yes".green() } else { "no".red() },
                eta
            );
        }
    }

    Ok(())
}

async fn model_select(model: &str, restart: bool) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let url = format!(
        "{}/api/v1/overlay/models/select",
        daemon_client::daemon_url()
    );
    let payload = serde_json::json!({
        "model": model,
        "restart": restart
    });
    let response = client.post(url).json(&payload).send().await?;
    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!("Failed to select model (status: {}): {}", status, body);
    }
    let body = response.json::<serde_json::Value>().await?;
    println!(
        "{}",
        body["message"].as_str().unwrap_or("Model selected").green()
    );
    Ok(())
}

async fn model_pull(model: &str, force: bool, restart: bool) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/overlay/models/pull", daemon_client::daemon_url());
    let payload = serde_json::json!({
        "model": model,
        "force": force,
        "restart": restart
    });
    let response = client.post(url).json(&payload).send().await?;
    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!("Failed to pull model (status: {}): {}", status, body);
    }
    let body = response.json::<serde_json::Value>().await?;
    println!(
        "{}",
        body["message"].as_str().unwrap_or("Model pulled").green()
    );
    Ok(())
}

async fn model_remove(
    model: &str,
    remove_companion: bool,
    select_fallback: bool,
    restart: bool,
) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let url = format!(
        "{}/api/v1/overlay/models/remove",
        daemon_client::daemon_url()
    );
    let payload = serde_json::json!({
        "model": model,
        "remove_companion": remove_companion,
        "select_fallback": select_fallback,
        "restart": restart
    });
    let response = client.post(url).json(&payload).send().await?;
    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!("Failed to remove model (status: {}): {}", status, body);
    }
    let body = response.json::<serde_json::Value>().await?;
    println!(
        "{}",
        body["message"].as_str().unwrap_or("Model removed").yellow()
    );
    Ok(())
}

async fn model_pin(model: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/overlay/models/pin", daemon_client::daemon_url());
    let payload = serde_json::json!({
        "model": model
    });
    let response = client.post(url).json(&payload).send().await?;
    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!("Failed to pin model (status: {}): {}", status, body);
    }
    let body = response.json::<serde_json::Value>().await?;
    println!(
        "{}",
        body["message"].as_str().unwrap_or("Model pinned").green()
    );
    Ok(())
}

async fn model_unpin(model: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let url = format!(
        "{}/api/v1/overlay/models/unpin",
        daemon_client::daemon_url()
    );
    let payload = serde_json::json!({
        "model": model
    });
    let response = client.post(url).json(&payload).send().await?;
    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!("Failed to unpin model (status: {}): {}", status, body);
    }
    let body = response.json::<serde_json::Value>().await?;
    println!(
        "{}",
        body["message"].as_str().unwrap_or("Model unpinned").green()
    );
    Ok(())
}

async fn models_export(path: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let url = format!(
        "{}/api/v1/overlay/models/export",
        daemon_client::daemon_url()
    );
    let payload = serde_json::json!({
        "path": path
    });
    let response = client.post(url).json(&payload).send().await?;
    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!(
            "Failed to export model inventory (status: {}): {}",
            status,
            body
        );
    }
    let body = response.json::<serde_json::Value>().await?;
    println!(
        "{}",
        body["message"]
            .as_str()
            .unwrap_or("Model inventory exported")
            .green()
    );
    Ok(())
}

async fn models_import(path: &str, adopt_pinning: bool) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let url = format!(
        "{}/api/v1/overlay/models/import",
        daemon_client::daemon_url()
    );
    let payload = serde_json::json!({
        "path": path,
        "adopt_pinning": adopt_pinning
    });
    let response = client.post(url).json(&payload).send().await?;
    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!(
            "Failed to import model inventory (status: {}): {}",
            status,
            body
        );
    }
    let body = response.json::<serde_json::Value>().await?;
    println!(
        "{}",
        body["message"]
            .as_str()
            .unwrap_or("Model inventory imported")
            .green()
    );
    Ok(())
}

async fn configure(
    theme: Option<String>,
    shortcut: Option<String>,
    opacity: Option<f32>,
    enabled: Option<bool>,
) -> anyhow::Result<()> {
    println!("{}", "Configuring AI overlay...".bold().blue());
    println!();

    let mut config_changes = Vec::new();

    if let Some(t) = theme {
        println!("  Theme: {}", t.cyan());
        config_changes.push(format!("\"theme\": \"{}\"", t));
    }

    if let Some(s) = shortcut {
        println!("  Shortcut: {}", s.cyan());
        config_changes.push(format!("\"shortcut\": \"{}\"", s));
    }

    if let Some(o) = opacity {
        println!("  Opacity: {:.2}", o);
        config_changes.push(format!("\"opacity\": {}", o));
    }

    if let Some(e) = enabled {
        println!("  Enabled: {}", if e { "yes".green() } else { "no".red() });
        config_changes.push(format!("\"enabled\": {}", e));
    }

    if config_changes.is_empty() {
        println!("{}", "No configuration changes specified".yellow());
        return Ok(());
    }

    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/overlay/config", daemon_client::daemon_url());

    let payload = format!("{{{}}}", config_changes.join(", "));

    let response = client
        .post(url)
        .header("Content-Type", "application/json")
        .body(payload)
        .send()
        .await?;

    if response.status().is_success() {
        println!();
        println!("{}", "Configuration updated".green());
    } else {
        let status = response.status();
        anyhow::bail!("Failed to update config (status: {})", status);
    }

    Ok(())
}
