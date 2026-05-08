use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum ModeCommands {
    /// Show current experience mode
    Show,
    /// Set experience mode (simple/pro/builder)
    Set {
        /// Mode to set (simple, pro, or builder)
        mode: String,
    },
    /// List all available experience modes
    List,
    /// Compare two experience modes
    Compare {
        /// First mode to compare
        mode1: String,
        /// Second mode to compare
        mode2: String,
    },
    /// Show features available in current mode
    Features,
    /// Test if a feature is available in current mode
    Test {
        /// Feature name to test
        feature: String,
    },
    /// Get mode details
    Info {
        /// Mode to get info for (default: current mode)
        #[arg(short, long)]
        mode: Option<String>,
    },
}

pub async fn execute(args: ModeCommands) -> anyhow::Result<()> {
    match args {
        ModeCommands::Show => show_mode().await,
        ModeCommands::Set { mode } => set_mode(&mode).await,
        ModeCommands::List => list_modes().await,
        ModeCommands::Compare { mode1, mode2 } => compare_modes(&mode1, &mode2).await,
        ModeCommands::Features => show_features().await,
        ModeCommands::Test { feature } => test_feature(&feature).await,
        ModeCommands::Info { mode } => show_mode_info(mode.as_deref()).await,
    }
}

async fn show_mode() -> anyhow::Result<()> {
    println!("{}", "Current Experience Mode".bold().blue());
    println!();

    let body: serde_json::Value = daemon_client::get_json("/api/v1/mode/current").await?;

    let mode = body
        .get("mode")
        .and_then(|m| m.as_str())
        .unwrap_or("unknown");

    let display_name = body
        .get("display_name")
        .and_then(|n| n.as_str())
        .unwrap_or("Unknown");

    let description = body
        .get("description")
        .and_then(|d| d.as_str())
        .unwrap_or("");

    println!("  {}: {}", "Mode".bold().cyan(), mode.cyan());
    println!("  {}: {}", "Display".bold().cyan(), display_name);
    println!();
    println!("  {}", description.dimmed());

    println!();
    println!(
        "Set new mode: {}",
        "life mode set <simple|pro|builder>".cyan()
    );
    println!("List modes: {}", "life mode list".cyan());

    Ok(())
}

async fn set_mode(mode: &str) -> anyhow::Result<()> {
    let mode = mode.to_lowercase();

    if !matches!(mode.as_str(), "simple" | "pro" | "builder") {
        anyhow::bail!("Invalid mode: '{}'. Must be simple, pro, or builder", mode);
    }

    println!("{} {}", "Setting mode to:".bold().blue(), mode.cyan());
    println!();

    let payload = serde_json::json!({ "mode": mode });
    let body: serde_json::Value = daemon_client::post_json("/api/v1/mode/set", &payload).await?;

    println!("{}", "Mode applied successfully".green().bold());

    if let Some(changes) = body.get("changes") {
        if let Some(change_arr) = changes.as_array() {
            println!();
            println!("{}", "Changes applied:".bold().cyan());
            for change in change_arr {
                if let Some(change_str) = change.as_str() {
                    println!("  ✓ {}", change_str.dimmed());
                }
            }
        }
    }

    if let Some(warnings) = body.get("warnings") {
        let warning_arr = warnings.as_array();
        if let Some(warnings_arr) = warning_arr {
            if !warnings_arr.is_empty() {
                println!();
                println!("{}", "Warnings:".bold().yellow());
                for warning in warnings_arr {
                    if let Some(warning_str) = warning.as_str() {
                        println!("  ⚠ {}", warning_str);
                    }
                }
            }
        }
    }

    Ok(())
}

async fn list_modes() -> anyhow::Result<()> {
    println!("{}", "Available Experience Modes".bold().blue());
    println!();

    let body: serde_json::Value = daemon_client::get_json("/api/v1/mode/list").await?;

    if let Some(modes) = body.get("modes").and_then(|m| m.as_array()) {
        for mode in modes {
            if let (Some(name), Some(display_name), Some(description)) = (
                mode.get("name").and_then(|n| n.as_str()),
                mode.get("display_name").and_then(|d| d.as_str()),
                mode.get("description").and_then(|d| d.as_str()),
            ) {
                println!("  {} ({})", display_name.cyan(), name.dimmed());
                println!("    {}", description.dimmed());
                println!();
            }
        }
    }

    println!("Set mode: {}", "life mode set <simple|pro|builder>".cyan());
    println!(
        "Compare modes: {}",
        "life mode compare <mode1> <mode2>".cyan()
    );

    Ok(())
}

async fn compare_modes(mode1: &str, mode2: &str) -> anyhow::Result<()> {
    println!("{}", "Comparing Experience Modes".bold().blue());
    println!();

    let payload = serde_json::json!({ "mode1": mode1, "mode2": mode2 });
    let body: serde_json::Value =
        daemon_client::post_json("/api/v1/mode/compare", &payload).await?;

    let m1 = body
        .get("mode1_display")
        .and_then(|d| d.as_str())
        .unwrap_or("");
    let m2 = body
        .get("mode2_display")
        .and_then(|d| d.as_str())
        .unwrap_or("");

    println!("  {}: {}", m1.cyan(), mode1.dimmed());
    println!("  {}: {}", m2.cyan(), mode2.dimmed());
    println!();

    if let Some(differences) = body.get("differences").and_then(|d| d.as_array()) {
        println!("{}", "Differences:".bold().yellow());
        for diff in differences {
            if let Some(diff_str) = diff.as_str() {
                println!("  • {}", diff_str);
            }
        }
    } else {
        println!("{}", "No differences found".green());
    }

    println!();
    println!("Switch mode: {}", format!("life mode set {}", mode2).cyan());

    Ok(())
}

async fn show_features() -> anyhow::Result<()> {
    println!("{}", "Features in Current Mode".bold().blue());
    println!();

    let body: serde_json::Value = daemon_client::get_json("/api/v1/mode/features").await?;

    let mut categories: std::collections::HashMap<String, Vec<(&str, &str, &str, bool)>> =
        std::collections::HashMap::new();

    if let Some(features) = body.get("features").and_then(|f| f.as_array()) {
        for feature in features {
            if let (Some(name), Some(display_name), Some(description), Some(category)) = (
                feature.get("name").and_then(|n| n.as_str()),
                feature.get("display_name").and_then(|d| d.as_str()),
                feature.get("description").and_then(|d| d.as_str()),
                feature.get("category").and_then(|c| c.as_str()),
            ) {
                let enabled = feature
                    .get("enabled")
                    .and_then(|e| e.as_bool())
                    .unwrap_or(false);
                categories.entry(category.to_string()).or_default().push((
                    name,
                    display_name,
                    description,
                    enabled,
                ));
            }
        }
    }

    // Group by category
    for category in [
        "System",
        "AI",
        "Overlay",
        "Updates",
        "Privacy",
        "Development",
        "Customization",
    ] {
        if let Some(mode_features) = categories.get(category) {
            if !mode_features.is_empty() {
                println!("  {}", category.bold().cyan());
                for (_name, display_name, description, enabled) in mode_features.iter() {
                    let status = if *enabled { "✓" } else { "✗" };
                    let colored_desc: colored::ColoredString = if *enabled {
                        description.green()
                    } else {
                        description.dimmed()
                    };
                    println!("    {} {}: {}", status, display_name, colored_desc);
                }
            }
        }
    }

    println!();
    println!("Test feature: {}", "life mode test <feature-name>".cyan());

    Ok(())
}

async fn test_feature(feature: &str) -> anyhow::Result<()> {
    println!("{} {}", "Testing feature:".bold().blue(), feature.cyan());
    println!();

    let payload = serde_json::json!({ "feature": feature });
    let body: serde_json::Value = daemon_client::post_json("/api/v1/mode/test", &payload).await?;

    let enabled = body
        .get("available")
        .and_then(|a| a.as_bool())
        .unwrap_or(false);

    if enabled {
        println!(
            "{}",
            "✓ Feature is available in current mode".green().bold()
        );
        println!("  Feature can be used without restrictions");
    } else {
        println!(
            "{}",
            "✗ Feature is NOT available in current mode".red().bold()
        );
        println!("  Consider switching to a mode that includes this feature");
        println!();
        println!("{}", "Available modes:".bold().yellow());
        println!("  - {} (minimalist)", "simple".cyan());
        println!("  - {} (complete)", "pro".cyan());
        println!("  - {} (developer tools)", "builder".cyan());
    }

    Ok(())
}

async fn show_mode_info(mode: Option<&str>) -> anyhow::Result<()> {
    let mode_target = mode.unwrap_or("current");

    println!("{}", "Experience Mode Information".bold().blue());
    println!();

    let path = if mode_target == "current" {
        "/api/v1/mode/current".to_string()
    } else {
        format!("/api/v1/mode/info?mode={}", mode_target)
    };
    let body: serde_json::Value = daemon_client::get_json(&path).await?;

    let name = body.get("name").and_then(|n| n.as_str()).unwrap_or("");
    let display_name = body
        .get("display_name")
        .and_then(|n| n.as_str())
        .unwrap_or("");
    let description = body
        .get("description")
        .and_then(|d| d.as_str())
        .unwrap_or("");

    println!("  {}: {}", "Name".bold().cyan(), name);
    println!("  {}: {}", "Display".bold().cyan(), display_name);
    println!();
    println!("  {}", "Description".bold().cyan());
    println!("    {}", description);
    println!();

    // Features
    if let Some(features) = body.get("features").and_then(|f| f.as_array()) {
        println!("  {}", "Features".bold().cyan());
        for feature in features {
            if let (Some(_f_name), Some(f_display), Some(f_enabled)) = (
                feature.get("name").and_then(|n| n.as_str()),
                feature.get("display_name").and_then(|d| d.as_str()),
                feature.get("enabled").and_then(|e| e.as_bool()),
            ) {
                let status = if f_enabled { "✓" } else { "✗" };
                let colored_display = if f_enabled {
                    f_display.green()
                } else {
                    f_display.dimmed()
                };
                println!("    {} {}", status, colored_display);
            }
        }
        println!();
    }

    // Settings
    if let Some(settings) = body.get("settings") {
        println!("  {}", "Settings".bold().cyan());
        println!(
            "    UI Complexity: {}",
            settings
                .get("ui_complexity")
                .unwrap_or(&serde_json::Value::Null)
        );
        println!(
            "    Update Channel: {}",
            settings
                .get("update_channel")
                .unwrap_or(&serde_json::Value::Null)
        );
        println!(
            "    AI Enabled: {}",
            settings
                .get("ai_enabled")
                .unwrap_or(&serde_json::Value::Null)
        );
        println!(
            "    AI Context Size: {}",
            settings
                .get("ai_context_size")
                .unwrap_or(&serde_json::Value::Null)
        );
        println!(
            "    Telemetry: {}",
            settings
                .get("telemetry_enabled")
                .unwrap_or(&serde_json::Value::Null)
        );
    }

    println!();
    println!(
        "Set this mode: {}",
        format!("life mode set {}", name).cyan()
    );

    Ok(())
}
