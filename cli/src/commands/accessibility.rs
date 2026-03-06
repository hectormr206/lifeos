use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum AccessibilityCommands {
    /// Run WCAG 2.2 AA accessibility audit on themes
    Audit,
    /// Show current accessibility settings
    Status,
}

pub async fn execute(args: AccessibilityCommands) -> anyhow::Result<()> {
    match args {
        AccessibilityCommands::Audit => run_audit().await,
        AccessibilityCommands::Status => show_status().await,
    }
}

async fn run_audit() -> anyhow::Result<()> {
    println!("{}", "WCAG 2.2 AA Accessibility Audit".bold().blue());
    println!();

    let client = daemon_client::authenticated_client();
    let url = format!("{}/api/v1/accessibility/audit", daemon_client::daemon_url());

    let response = client.get(url).send().await?;

    if !response.status().is_success() {
        let status = response.status();
        anyhow::bail!("Failed to run accessibility audit (status: {})", status);
    }

    let body: serde_json::Value = response.json().await?;

    if let Some(results) = body.get("results").and_then(|r| r.as_array()) {
        for theme_result in results {
            let theme_name = theme_result
                .get("theme_name")
                .and_then(|n| n.as_str())
                .unwrap_or("Unknown");
            let overall_pass = theme_result
                .get("overall_pass")
                .and_then(|p| p.as_bool())
                .unwrap_or(false);
            let passing = theme_result
                .get("passing_pairs")
                .and_then(|p| p.as_u64())
                .unwrap_or(0);
            let total = theme_result
                .get("total_pairs")
                .and_then(|t| t.as_u64())
                .unwrap_or(0);
            let failing = theme_result
                .get("failing_pairs")
                .and_then(|f| f.as_u64())
                .unwrap_or(0);

            let status_icon = if overall_pass {
                "✓".green()
            } else {
                "✗".red()
            };

            println!(
                "  {} {} ({}/{} pairs pass)",
                status_icon,
                theme_name.cyan().bold(),
                passing.to_string().green(),
                total.to_string().yellow()
            );

            if failing > 0 {
                if let Some(issues) = theme_result.get("issues").and_then(|i| i.as_array()) {
                    for issue in issues {
                        if let Some(issue_text) = issue.as_str() {
                            println!("    {} {}", "•".dimmed(), issue_text.dimmed());
                        }
                    }
                }
            }
            println!();
        }
    }

    println!("{}", "Audit complete.".bold());
    println!();
    println!("All themes must meet WCAG 2.2 AA minimum contrast ratios:");
    println!("  {} Normal text: 4.5:1", "•".cyan());
    println!("  {} Large text: 3.0:1", "•".cyan());
    println!("  {} UI components: 3.0:1", "•".cyan());

    Ok(())
}

async fn show_status() -> anyhow::Result<()> {
    println!("{}", "Accessibility Settings".bold().blue());
    println!();

    let client = daemon_client::authenticated_client();
    let url = format!(
        "{}/api/v1/accessibility/settings",
        daemon_client::daemon_url()
    );

    let response = client.get(url).send().await?;

    if !response.status().is_success() {
        let status = response.status();
        anyhow::bail!("Failed to get accessibility settings (status: {})", status);
    }

    let settings: serde_json::Value = response.json().await?;

    let high_contrast = settings
        .get("high_contrast")
        .and_then(|h| h.as_bool())
        .unwrap_or(false);

    let reduce_motion = settings
        .get("reduce_motion")
        .and_then(|r| r.as_bool())
        .unwrap_or(false);

    let font_scale = settings
        .get("font_scale")
        .and_then(|f| f.as_f64())
        .unwrap_or(1.0) as f32;

    let min_font_size = settings
        .get("min_font_size")
        .and_then(|m| m.as_u64())
        .unwrap_or(12) as u32;

    let keyboard_nav = settings
        .get("keyboard_navigation")
        .and_then(|k| k.as_bool())
        .unwrap_or(true);

    let screen_reader = settings
        .get("screen_reader_support")
        .and_then(|s| s.as_bool())
        .unwrap_or(false);

    println!(
        "  {}: {}",
        "High Contrast".cyan(),
        if high_contrast {
            "enabled".green()
        } else {
            "disabled".dimmed()
        }
    );

    println!(
        "  {}: {}",
        "Reduce Motion".cyan(),
        if reduce_motion {
            "enabled".green()
        } else {
            "disabled".dimmed()
        }
    );

    println!("  {}: {:.0}%", "Font Scale".cyan(), font_scale * 100.0);

    println!("  {}: {}pt", "Min Font Size".cyan(), min_font_size);

    println!(
        "  {}: {}",
        "Keyboard Navigation".cyan(),
        if keyboard_nav {
            "enabled".green()
        } else {
            "disabled".red()
        }
    );

    println!(
        "  {}: {}",
        "Screen Reader Support".cyan(),
        if screen_reader {
            "enabled".green()
        } else {
            "disabled".dimmed()
        }
    );

    println!();
    println!("{}", "Commands:".bold());
    println!(
        "  {} - Run WCAG accessibility audit",
        "life accessibility audit".cyan()
    );

    Ok(())
}
