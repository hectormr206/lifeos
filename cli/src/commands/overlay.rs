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
    /// Cleanup non-selected and non-pinned models
    ModelCleanup {
        #[arg(long, default_value_t = true)]
        dry_run: bool,
        #[arg(long, default_value_t = true)]
        remove_companion: bool,
        #[arg(long)]
        restart: bool,
    },
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
        OverlayCommands::ModelCleanup {
            dry_run,
            remove_companion,
            restart,
        } => model_cleanup(dry_run, remove_companion, restart).await,
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
    daemon_client::post_empty::<serde_json::Value>("/api/v1/overlay/show").await?;
    println!("{}", "Overlay opened".green());
    Ok(())
}

async fn hide_overlay() -> anyhow::Result<()> {
    println!("{}", "Hiding AI overlay...".bold().blue());
    daemon_client::post_empty::<serde_json::Value>("/api/v1/overlay/hide").await?;
    println!("{}", "Overlay hidden".green());
    Ok(())
}

async fn toggle_overlay() -> anyhow::Result<()> {
    println!("{}", "Toggling AI overlay...".bold().blue());
    daemon_client::post_empty::<serde_json::Value>("/api/v1/overlay/toggle").await?;
    println!("{}", "Overlay toggled".green());
    Ok(())
}

async fn chat(prompt: &str) -> anyhow::Result<()> {
    println!("{} {}", "Message:".bold().green(), prompt.cyan());

    let payload = serde_json::json!({
        "message": prompt,
        "include_screen": true
    });

    let body: serde_json::Value =
        daemon_client::post_json("/api/v1/overlay/chat", &payload).await?;

    if let Some(response) = body.get("response") {
        println!("\n{}", response.as_str().unwrap_or("No response"));
    }

    Ok(())
}

async fn screenshot() -> anyhow::Result<()> {
    println!("{}", "Capturing screen for AI context...".bold().blue());

    let body: serde_json::Value = daemon_client::post_empty("/api/v1/overlay/screenshot").await?;

    println!("{}", "Screen captured".green());
    if let Some(path) = body.get("path") {
        println!(
            "  {}: {}",
            "Saved to:".dimmed(),
            path.as_str().unwrap_or("unknown")
        );
    }

    Ok(())
}

async fn clear_chat() -> anyhow::Result<()> {
    println!("{}", "Clearing overlay chat history...".bold().yellow());
    daemon_client::post_empty::<serde_json::Value>("/api/v1/overlay/clear").await?;
    println!("{}", "Chat history cleared".green());
    Ok(())
}

async fn export_chat(path: &str) -> anyhow::Result<()> {
    println!("{} {}", "Exporting chat to:".bold().blue(), path.cyan());
    let payload = serde_json::json!({ "path": path });
    daemon_client::post_json::<_, serde_json::Value>("/api/v1/overlay/export", &payload).await?;
    println!("{}", "Chat exported".green());
    Ok(())
}

async fn import_chat(path: &str) -> anyhow::Result<()> {
    println!("{} {}", "Importing chat from:".bold().blue(), path.cyan());
    let payload = serde_json::json!({ "path": path });
    daemon_client::post_json::<_, serde_json::Value>("/api/v1/overlay/import", &payload).await?;
    println!("{}", "Chat imported".green());
    Ok(())
}

async fn show_status() -> anyhow::Result<()> {
    println!("{}", "Overlay Status".bold().blue());
    println!();

    let body: serde_json::Value = daemon_client::get_json("/api/v1/overlay/status").await?;

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

    println!();
    println!("Keyboard Shortcut: {}", "Super+Space".cyan());
    println!("Toggle with: {}", "life overlay toggle".cyan());

    Ok(())
}

async fn show_models() -> anyhow::Result<()> {
    println!("{}", "Overlay Model Selector".bold().blue());
    println!();

    let body: serde_json::Value = daemon_client::get_json("/api/v1/overlay/models").await?;

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
    if let Some(roster) = body["featured_roster"].as_array() {
        let roster_display = roster
            .iter()
            .filter_map(|item| item.as_str())
            .collect::<Vec<_>>()
            .join(" | ");
        if !roster_display.is_empty() {
            println!("  Roster inicial: {}", roster_display.magenta());
        }
    }
    if let Some(hardware) = body["hardware"].as_object() {
        println!();
        println!("{}", "Host fit:".bold());
        let ram = hardware["total_ram_gb"].as_u64().unwrap_or(0);
        let vram = hardware["total_vram_gb"]
            .as_u64()
            .map(|v| format!("{}GB", v))
            .unwrap_or_else(|| "N/A".to_string());
        let gpu = hardware["gpu_name"].as_str().unwrap_or("none");
        let temp = hardware["gpu_temp_celsius"]
            .as_f64()
            .map(|v| format!("{:.1}C", v))
            .unwrap_or_else(|| "-".to_string());
        let util = hardware["gpu_utilization_percent"]
            .as_u64()
            .map(|v| format!("{}%", v))
            .unwrap_or_else(|| "-".to_string());
        let thermal = if hardware["thermal_pressure"].as_bool().unwrap_or(false) {
            "yes".red().to_string()
        } else {
            "no".green().to_string()
        };
        let battery = match hardware["on_battery"].as_bool() {
            Some(true) => "battery".yellow().to_string(),
            Some(false) => "ac".green().to_string(),
            None => "unknown".dimmed().to_string(),
        };
        println!(
            "  ram/vram: {}GB/{}  gpu:{}  temp:{} util:{}  thermal_pressure:{}  power:{}",
            ram,
            vram,
            gpu.cyan(),
            temp,
            util,
            thermal,
            battery
        );
    }
    if let Some(storage) = body["storage"].as_object() {
        println!();
        println!("{}", "Storage:".bold());
        let model_dir = storage["model_dir"].as_str().unwrap_or("-");
        let total = storage["filesystem_total_bytes"]
            .as_u64()
            .map(format_bytes_human)
            .unwrap_or_else(|| "-".to_string());
        let free = storage["filesystem_free_bytes"]
            .as_u64()
            .map(format_bytes_human)
            .unwrap_or_else(|| "-".to_string());
        let used = storage["filesystem_used_percent"]
            .as_f64()
            .map(|v| format!("{:.1}%", v))
            .unwrap_or_else(|| "-".to_string());
        let installed = storage["installed_model_bytes"]
            .as_u64()
            .map(format_bytes_human)
            .unwrap_or_else(|| "-".to_string());
        let reclaimable = storage["reclaimable_model_bytes"]
            .as_u64()
            .map(format_bytes_human)
            .unwrap_or_else(|| "-".to_string());
        println!(
            "  {}  total:{} free:{} used:{}  installed:{} reclaimable:{}",
            model_dir.dimmed(),
            total,
            free,
            used,
            installed,
            reclaimable.yellow()
        );
    }

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
            let fit = model["fit_tier"].as_str().unwrap_or("cpu_only");
            let gpu_layers = model["expected_gpu_layers"]
                .as_i64()
                .map(|v| v.to_string())
                .unwrap_or_else(|| "0".to_string());
            let expected_ram = model["expected_ram_gb"]
                .as_u64()
                .map(|v| format!("{}GB", v))
                .unwrap_or_else(|| "-".to_string());
            let expected_vram = model["expected_vram_gb"]
                .as_u64()
                .map(|v| format!("{}GB", v))
                .unwrap_or_else(|| "N/A".to_string());
            let battery = model["expected_battery_impact"]
                .as_str()
                .unwrap_or("unknown");
            let required_disk = model["required_disk_bytes"]
                .as_u64()
                .map(format_bytes_human)
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
                "      fit:{} gpu_layers:{}  ram/vram:{}/{}  disk:{}  battery:{}",
                fit, gpu_layers, expected_ram, expected_vram, required_disk, battery
            );
            println!(
                "      integrity:{}  resumable:{}  eta:{}",
                if integrity { "yes".green() } else { "no".red() },
                if resumable { "yes".green() } else { "no".red() },
                eta
            );
            println!("      recommended ram/vram: {}/{}", ram, vram,);
        }
    }

    Ok(())
}

async fn model_select(model: &str, restart: bool) -> anyhow::Result<()> {
    let payload = serde_json::json!({
        "model": model,
        "restart": restart
    });
    let body: serde_json::Value =
        daemon_client::post_json("/api/v1/overlay/models/select", &payload).await?;
    println!(
        "{}",
        body["message"].as_str().unwrap_or("Model selected").green()
    );
    Ok(())
}

async fn model_pull(model: &str, force: bool, restart: bool) -> anyhow::Result<()> {
    let payload = serde_json::json!({
        "model": model,
        "force": force,
        "restart": restart
    });
    let body: serde_json::Value =
        daemon_client::post_json("/api/v1/overlay/models/pull", &payload).await?;
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
    let payload = serde_json::json!({
        "model": model,
        "remove_companion": remove_companion,
        "select_fallback": select_fallback,
        "restart": restart
    });
    let body: serde_json::Value =
        daemon_client::post_json("/api/v1/overlay/models/remove", &payload).await?;
    println!(
        "{}",
        body["message"].as_str().unwrap_or("Model removed").yellow()
    );
    Ok(())
}

async fn model_pin(model: &str) -> anyhow::Result<()> {
    let payload = serde_json::json!({ "model": model });
    let body: serde_json::Value =
        daemon_client::post_json("/api/v1/overlay/models/pin", &payload).await?;
    println!(
        "{}",
        body["message"].as_str().unwrap_or("Model pinned").green()
    );
    Ok(())
}

async fn model_unpin(model: &str) -> anyhow::Result<()> {
    let payload = serde_json::json!({ "model": model });
    let body: serde_json::Value =
        daemon_client::post_json("/api/v1/overlay/models/unpin", &payload).await?;
    println!(
        "{}",
        body["message"].as_str().unwrap_or("Model unpinned").green()
    );
    Ok(())
}

async fn model_cleanup(dry_run: bool, remove_companion: bool, restart: bool) -> anyhow::Result<()> {
    let payload = serde_json::json!({
        "dry_run": dry_run,
        "remove_companion": remove_companion,
        "restart": restart
    });
    let body: serde_json::Value =
        daemon_client::post_json("/api/v1/overlay/models/cleanup", &payload).await?;
    println!(
        "{}",
        body["message"]
            .as_str()
            .unwrap_or("Model cleanup completed")
            .green()
    );
    if let Some(models) = body["removed_models"].as_array() {
        if !models.is_empty() {
            println!("  {}:", "models".bold());
            for model in models.iter().filter_map(|entry| entry.as_str()) {
                println!("    - {}", model.cyan());
            }
        }
    }
    if let Some(companions) = body["removed_companions"].as_array() {
        if !companions.is_empty() {
            println!("  {}:", "companions".bold());
            for companion in companions.iter().filter_map(|entry| entry.as_str()) {
                println!("    - {}", companion.dimmed());
            }
        }
    }
    if let Some(bytes) = body["reclaimed_bytes"].as_u64() {
        println!("  reclaimed: {}", format_bytes_human(bytes).yellow());
    }
    Ok(())
}

fn format_bytes_human(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut size = bytes as f64;
    let mut unit_idx = 0usize;
    while size >= 1024.0 && unit_idx < UNITS.len() - 1 {
        size /= 1024.0;
        unit_idx += 1;
    }
    format!("{:.1} {}", size, UNITS[unit_idx])
}

async fn models_export(path: &str) -> anyhow::Result<()> {
    let payload = serde_json::json!({ "path": path });
    let body: serde_json::Value =
        daemon_client::post_json("/api/v1/overlay/models/export", &payload).await?;
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
    let payload = serde_json::json!({
        "path": path,
        "adopt_pinning": adopt_pinning
    });
    let body: serde_json::Value =
        daemon_client::post_json("/api/v1/overlay/models/import", &payload).await?;
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

    // Build raw JSON payload manually since config_changes are pre-formatted fragments
    let payload_str = format!("{{{}}}", config_changes.join(", "));
    let payload: serde_json::Value = serde_json::from_str(&payload_str)?;

    daemon_client::post_json::<_, serde_json::Value>("/api/v1/overlay/config", &payload).await?;

    println!();
    println!("{}", "Configuration updated".green());

    Ok(())
}
