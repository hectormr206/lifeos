use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum VisualComfortCommands {
    /// Show current visual comfort status
    Status,
    /// Set comfort profile (default|coding|reading|design|meeting|balanced|focus|vivid)
    Profile {
        /// Profile name
        name: String,
    },
    /// List available comfort profiles
    Profiles,
    /// Set color temperature (2500-6500K)
    Temperature {
        /// Temperature in Kelvin (2500-6500)
        kelvin: u32,
    },
    /// Set font scale (0.8-1.5)
    FontScale {
        /// Font scale factor (0.8-1.5)
        scale: f32,
    },
    /// Enable or disable animations
    Animations {
        /// Enable or disable (on/off)
        state: String,
    },
    /// Reset session timer
    Reset,
}

pub async fn execute(args: VisualComfortCommands) -> anyhow::Result<()> {
    match args {
        VisualComfortCommands::Status => show_status().await,
        VisualComfortCommands::Profile { name } => set_profile(&name).await,
        VisualComfortCommands::Profiles => list_profiles().await,
        VisualComfortCommands::Temperature { kelvin } => set_temperature(kelvin).await,
        VisualComfortCommands::FontScale { scale } => set_font_scale(scale).await,
        VisualComfortCommands::Animations { state } => set_animations(&state).await,
        VisualComfortCommands::Reset => reset_session().await,
    }
}

async fn show_status() -> anyhow::Result<()> {
    println!("{}", "Visual Comfort Status".bold().blue());
    println!();

    let client = daemon_client::authenticated_client();
    let url = format!(
        "{}/api/v1/visual-comfort/status",
        daemon_client::daemon_url()
    );

    let response = client.get(url).send().await?;

    if !response.status().is_success() {
        let status = response.status();
        anyhow::bail!("Failed to get visual comfort status (status: {})", status);
    }

    let body: serde_json::Value = response.json().await?;

    let temperature = body
        .get("current_temperature")
        .and_then(|t| t.as_u64())
        .unwrap_or(6500);

    let target_temp = body
        .get("target_temperature")
        .and_then(|t| t.as_u64())
        .unwrap_or(6500);

    let font_scale = body
        .get("current_font_scale")
        .and_then(|s| s.as_f64())
        .unwrap_or(1.0) as f32;

    let animations = body
        .get("animations_enabled")
        .and_then(|a| a.as_bool())
        .unwrap_or(true);

    let profile = body
        .get("active_profile")
        .and_then(|p| p.as_str())
        .unwrap_or("default");

    let session_minutes = body
        .get("session_duration_minutes")
        .and_then(|m| m.as_u64())
        .unwrap_or(0);

    let is_night = body
        .get("is_night_time")
        .and_then(|n| n.as_bool())
        .unwrap_or(false);

    let transitioning = body
        .get("transitioning")
        .and_then(|t| t.as_bool())
        .unwrap_or(false);

    let temp_suffix = if temperature != target_temp as u64 {
        format!(" → {}K", target_temp)
    } else {
        String::new()
    };

    println!(
        "  {}: {}{}",
        "Color Temperature".bold().cyan(),
        format!("{}K", temperature).yellow(),
        temp_suffix.dimmed()
    );

    println!(
        "  {}: {:.0}%",
        "Font Scale".bold().cyan(),
        font_scale * 100.0
    );

    println!(
        "  {}: {}",
        "Animations".bold().cyan(),
        if animations {
            "enabled".green()
        } else {
            "disabled".red()
        }
    );

    println!("  {}: {}", "Active Profile".bold().cyan(), profile.cyan());

    println!(
        "  {}: {}",
        "Time of Day".bold().cyan(),
        if is_night {
            "night".purple()
        } else {
            "day".yellow()
        }
    );

    println!(
        "  {}: {} minutes",
        "Session Duration".bold().cyan(),
        session_minutes
    );

    if transitioning {
        println!();
        println!("{}", "⏳ Transitioning...".dimmed());
    }

    println!();
    println!("{}", "Commands:".bold());
    println!(
        "  {} - Change comfort profile",
        "life visual-comfort profile <name>".cyan()
    );
    println!(
        "  {} - Adjust color temperature",
        "life visual-comfort temperature <2500-6500>".cyan()
    );
    println!(
        "  {} - Adjust font size",
        "life visual-comfort font-scale <0.8-1.5>".cyan()
    );
    println!(
        "  {} - Toggle animations",
        "life visual-comfort animations <on|off>".cyan()
    );

    Ok(())
}

async fn set_profile(name: &str) -> anyhow::Result<()> {
    let profile = name.to_lowercase();

    let valid_profiles = [
        "default", "coding", "reading", "design", "meeting", "balanced", "focus", "vivid",
    ];
    if !valid_profiles.contains(&profile.as_str()) {
        anyhow::bail!(
            "Invalid profile '{}'. Must be: {}",
            profile,
            valid_profiles.join(", ")
        );
    }

    println!(
        "{} {}",
        "Setting comfort profile:".bold().blue(),
        profile.cyan()
    );
    println!();

    let client = daemon_client::authenticated_client();
    let url = format!(
        "{}/api/v1/visual-comfort/profile",
        daemon_client::daemon_url()
    );

    let payload = serde_json::json!({
        "profile": profile
    });

    let response = client.post(url).json(&payload).send().await?;

    if !response.status().is_success() {
        let status = response.status();
        anyhow::bail!("Failed to set profile (status: {})", status);
    }

    println!("{}", "Profile applied successfully".green().bold());
    println!();

    let profile_details = match profile.as_str() {
        "coding" => ("6000K", "95%", "High contrast, reduced animations"),
        "reading" => ("4000K", "115%", "Warm sepia tones, larger fonts"),
        "design" => ("6500K", "100%", "Neutral colors for accurate work"),
        "meeting" => ("4500K", "105%", "Lower brightness, warm tones"),
        "balanced" => ("5500K", "100%", "Balanced visual comfort for mixed tasks"),
        "focus" => ("6000K", "95%", "Deep focus, high contrast, no distractions"),
        "vivid" => (
            "6500K",
            "100%",
            "Vibrant colors, enhanced visual experience",
        ),
        _ => ("6500K", "100%", "Standard settings"),
    };

    println!("  {}: {}", "Temperature".cyan(), profile_details.0);
    println!("  {}: {}", "Font Scale".cyan(), profile_details.1);
    println!("  {}", profile_details.2.dimmed());

    Ok(())
}

async fn list_profiles() -> anyhow::Result<()> {
    println!("{}", "Available Comfort Profiles".bold().blue());
    println!();

    let client = daemon_client::authenticated_client();
    let url = format!(
        "{}/api/v1/visual-comfort/profiles",
        daemon_client::daemon_url()
    );

    let response = client.get(url).send().await?;

    if !response.status().is_success() {
        let status = response.status();
        anyhow::bail!("Failed to list profiles (status: {})", status);
    }

    let body: serde_json::Value = response.json().await?;

    if let Some(profiles) = body.as_array() {
        for profile in profiles {
            let name = profile.get("name").and_then(|n| n.as_str()).unwrap_or("");
            let display = profile
                .get("display_name")
                .and_then(|d| d.as_str())
                .unwrap_or("");
            let temp = profile
                .get("temperature")
                .and_then(|t| t.as_u64())
                .unwrap_or(6500);
            let scale = profile
                .get("font_scale")
                .and_then(|s| s.as_f64())
                .unwrap_or(1.0);
            let anim = profile
                .get("animations_enabled")
                .and_then(|a| a.as_bool())
                .unwrap_or(true);

            println!("  {} ({})", display.cyan(), name.dimmed());
            println!(
                "    Temperature: {}  Scale: {:.0}%  Animations: {}",
                format!("{}K", temp).yellow(),
                scale * 100.0,
                if anim { "on".green() } else { "off".red() }
            );
            println!();
        }
    }

    println!(
        "Set profile: {}",
        "life visual-comfort profile <name>".cyan()
    );

    Ok(())
}

async fn set_temperature(kelvin: u32) -> anyhow::Result<()> {
    if !(2500..=6500).contains(&kelvin) {
        anyhow::bail!("Temperature must be between 2500K and 6500K");
    }

    println!(
        "{} {}K",
        "Setting color temperature:".bold().blue(),
        kelvin.to_string().yellow()
    );
    println!();

    let client = daemon_client::authenticated_client();
    let url = format!(
        "{}/api/v1/visual-comfort/temperature",
        daemon_client::daemon_url()
    );

    let payload = serde_json::json!({
        "temperature": kelvin
    });

    let response = client.post(url).json(&payload).send().await?;

    if !response.status().is_success() {
        let status = response.status();
        anyhow::bail!("Failed to set temperature (status: {})", status);
    }

    println!("{}", "Temperature applied successfully".green().bold());

    let description = if kelvin <= 3000 {
        "Very warm (candlelight)"
    } else if kelvin <= 4000 {
        "Warm (incandescent)"
    } else if kelvin <= 5000 {
        "Neutral warm"
    } else if kelvin <= 5500 {
        "Neutral daylight"
    } else {
        "Cool daylight"
    };

    println!("  {}", description.dimmed());

    Ok(())
}

async fn set_font_scale(scale: f32) -> anyhow::Result<()> {
    if !(0.8..=1.5).contains(&scale) {
        anyhow::bail!("Font scale must be between 0.8 and 1.5");
    }

    println!(
        "{} {:.0}%",
        "Setting font scale:".bold().blue(),
        (scale * 100.0) as u32
    );
    println!();

    let client = daemon_client::authenticated_client();
    let url = format!(
        "{}/api/v1/visual-comfort/font-scale",
        daemon_client::daemon_url()
    );

    let payload = serde_json::json!({
        "scale": scale
    });

    let response = client.post(url).json(&payload).send().await?;

    if !response.status().is_success() {
        let status = response.status();
        anyhow::bail!("Failed to set font scale (status: {})", status);
    }

    println!("{}", "Font scale applied successfully".green().bold());

    Ok(())
}

async fn set_animations(state: &str) -> anyhow::Result<()> {
    let enabled = match state.to_lowercase().as_str() {
        "on" | "true" | "yes" | "1" => true,
        "off" | "false" | "no" | "0" => false,
        _ => anyhow::bail!("Invalid state '{}'. Use 'on' or 'off'", state),
    };

    println!(
        "{} {}",
        "Setting animations:".bold().blue(),
        if enabled {
            "enabled".green()
        } else {
            "disabled".red()
        }
    );
    println!();

    let client = daemon_client::authenticated_client();
    let url = format!(
        "{}/api/v1/visual-comfort/animations",
        daemon_client::daemon_url()
    );

    let payload = serde_json::json!({
        "enabled": enabled
    });

    let response = client.post(url).json(&payload).send().await?;

    if !response.status().is_success() {
        let status = response.status();
        anyhow::bail!("Failed to set animations (status: {})", status);
    }

    println!(
        "{}",
        "Animation setting applied successfully".green().bold()
    );

    Ok(())
}

async fn reset_session() -> anyhow::Result<()> {
    println!("{}", "Resetting visual comfort session...".bold().blue());
    println!();

    let client = daemon_client::authenticated_client();
    let url = format!(
        "{}/api/v1/visual-comfort/reset",
        daemon_client::daemon_url()
    );

    let response = client.post(url).send().await?;

    if !response.status().is_success() {
        let status = response.status();
        anyhow::bail!("Failed to reset session (status: {})", status);
    }

    println!("{}", "Session reset successfully".green().bold());
    println!();
    println!("  Session timer cleared");
    println!("  Animations re-enabled (if profile allows)");
    println!("  Time-based settings refreshed");

    Ok(())
}
