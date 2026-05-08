//! Context Policies CLI commands
//!
//! Manage workplace/context profiles that automatically apply rules
//! based on current activity, time, network, or manual selection.

use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum ContextCommands {
    /// Show current context and active profile
    Status,
    /// Switch to a specific context
    Set {
        /// Context name (home, work, gaming, development, creative, learning, travel)
        context: String,
    },
    /// List all context profiles
    List,
    /// Show details of a specific profile
    Show {
        /// Context name
        context: String,
    },
    /// Auto-detect and switch to best matching context
    Detect,
    /// Show rules that would be applied for a context
    Rules {
        /// Context name (or "current" for active context)
        #[arg(default_value = "current")]
        context: String,
    },
    /// Show context statistics
    Stats,
    /// Create a new custom context profile
    Create {
        /// Context name
        name: String,
        /// Description
        #[arg(short, long, default_value = "Custom context")]
        description: String,
    },
    /// Delete a context profile
    Delete {
        /// Context name
        context: String,
    },
    /// Add a rule to a context profile
    AddRule {
        /// Context name
        context: String,
        /// Rule type: mode, model, notifications, capture, channel, block-app, privacy
        rule_type: String,
        /// Rule value
        value: String,
    },
}

pub async fn execute(cmd: ContextCommands) -> anyhow::Result<()> {
    match cmd {
        ContextCommands::Status => cmd_status().await,
        ContextCommands::Set { context } => cmd_set(&context).await,
        ContextCommands::List => cmd_list().await,
        ContextCommands::Show { context } => cmd_show(&context).await,
        ContextCommands::Detect => cmd_detect().await,
        ContextCommands::Rules { context } => cmd_rules(&context).await,
        ContextCommands::Stats => cmd_stats().await,
        ContextCommands::Create { name, description } => cmd_create(&name, &description).await,
        ContextCommands::Delete { context } => cmd_delete(&context).await,
        ContextCommands::AddRule {
            context,
            rule_type,
            value,
        } => cmd_add_rule(&context, &rule_type, &value).await,
    }
}

fn print_daemon_down() {
    println!(
        "{}",
        "Cannot connect to lifeosd. Is the daemon running?".red()
    );
    println!("  Try: {}", "sudo systemctl start lifeosd".cyan());
}

async fn cmd_status() -> anyhow::Result<()> {
    let body: serde_json::Value = daemon_client::get_json("/api/v1/context/status")
        .await
        .inspect_err(|e| {
            if e.to_string().contains("is lifeosd running") {
                print_daemon_down();
            }
        })?;
    println!("{}", "Context Status".bold().blue());
    println!();
    println!(
        "  Current:    {}",
        body["current_context"].as_str().unwrap_or("unknown").cyan()
    );
    println!(
        "  Profile:    {}",
        body["active_profile"].as_str().unwrap_or("none")
    );
    println!(
        "  Detection:  {:?}",
        body["detection_method"].as_str().unwrap_or("manual")
    );
    if let Some(last) = body["last_switch"].as_str() {
        println!("  Last switch: {}", last.dimmed());
    }
    Ok(())
}

async fn cmd_set(context: &str) -> anyhow::Result<()> {
    let payload = serde_json::json!({ "context": context });
    let _: serde_json::Value = daemon_client::post_json("/api/v1/context/set", &payload)
        .await
        .inspect_err(|e| {
            if e.to_string().contains("is lifeosd running") {
                print_daemon_down();
            }
        })?;
    println!(
        "{} Context switched to: {}",
        "OK".green().bold(),
        context.cyan()
    );
    Ok(())
}

async fn cmd_list() -> anyhow::Result<()> {
    let body: serde_json::Value = daemon_client::get_json("/api/v1/context/profiles")
        .await
        .inspect_err(|e| {
            if e.to_string().contains("is lifeosd running") {
                print_daemon_down();
            }
        })?;
    println!("{}", "Context Profiles".bold().blue());
    println!();
    if let Some(profiles) = body["profiles"].as_array() {
        for p in profiles {
            let name = p["name"].as_str().unwrap_or("?");
            let ctx = p["context"].as_str().unwrap_or("?");
            let desc = p["description"].as_str().unwrap_or("");
            let rules_count = p["rules"].as_array().map(|r| r.len()).unwrap_or(0);
            println!("  {} ({}) — {} rules", name.cyan().bold(), ctx, rules_count);
            if !desc.is_empty() {
                println!("    {}", desc.dimmed());
            }
        }
    }
    Ok(())
}

async fn cmd_show(context: &str) -> anyhow::Result<()> {
    let path = format!("/api/v1/context/profile/{}", context);
    let result: anyhow::Result<serde_json::Value> = daemon_client::get_json(&path).await;
    let body = match result {
        Ok(b) => b,
        Err(e) => {
            let msg = e.to_string();
            if msg.contains("is lifeosd running") {
                print_daemon_down();
                return Ok(());
            }
            if msg.contains("404") {
                println!("{}", format!("Profile '{}' not found.", context).yellow());
                return Ok(());
            }
            return Err(e);
        }
    };
    println!("{}", format!("Profile: {}", context).bold().blue());
    println!();
    println!("  Name:       {}", body["name"].as_str().unwrap_or("?"));
    println!(
        "  Description: {}",
        body["description"].as_str().unwrap_or("")
    );
    println!(
        "  Detection:  {}",
        format!("{:?}", body["detection_method"]).dimmed()
    );
    println!("  Priority:   {}", body["priority"].as_u64().unwrap_or(0));

    if let Some(rules) = body["rules"].as_array() {
        println!();
        println!("  {}:", "Rules".bold());
        for rule in rules {
            let enabled = rule["enabled"].as_bool().unwrap_or(false);
            let icon = if enabled { "ON ".green() } else { "OFF".red() };
            println!(
                "    [{}] {} — {}",
                icon,
                rule["name"].as_str().unwrap_or("?"),
                rule["description"].as_str().unwrap_or("")
            );
        }
    }
    Ok(())
}

async fn cmd_detect() -> anyhow::Result<()> {
    let body: serde_json::Value = daemon_client::post_empty("/api/v1/context/detect")
        .await
        .inspect_err(|e| {
            if e.to_string().contains("is lifeosd running") {
                print_daemon_down();
            }
        })?;
    if let Some(detected) = body["detected_context"].as_str() {
        println!(
            "{} Detected context: {}",
            "OK".green().bold(),
            detected.cyan()
        );
        if body["switched"].as_bool().unwrap_or(false) {
            println!("  Context switched automatically.");
        }
    } else {
        println!("{}", "No matching context detected.".yellow());
    }
    Ok(())
}

async fn cmd_rules(context: &str) -> anyhow::Result<()> {
    let path = format!("/api/v1/context/rules/{}", context);
    let body: serde_json::Value = daemon_client::get_json(&path).await.inspect_err(|e| {
        if e.to_string().contains("is lifeosd running") {
            print_daemon_down();
        }
    })?;
    println!(
        "{}",
        format!("Rules for context: {}", context).bold().blue()
    );
    println!();
    if let Some(rules) = body["applied_rules"].as_array() {
        for rule in rules {
            let status = rule["status"].as_str().unwrap_or("?");
            let icon = match status {
                "Applied" => "APPLIED".green(),
                "Failed" => "FAILED ".red(),
                _ => "SKIPPED".yellow(),
            };
            println!(
                "  [{}] {} — {}",
                icon,
                rule["rule_name"].as_str().unwrap_or("?"),
                rule["action"].as_str().unwrap_or("")
            );
        }
    }
    Ok(())
}

async fn cmd_stats() -> anyhow::Result<()> {
    let body: serde_json::Value = daemon_client::get_json("/api/v1/context/stats")
        .await
        .inspect_err(|e| {
            if e.to_string().contains("is lifeosd running") {
                print_daemon_down();
            }
        })?;
    println!("{}", "Context Statistics".bold().blue());
    println!();
    println!(
        "  Current context:  {}",
        body["current_context"].as_str().unwrap_or("unknown").cyan()
    );
    println!(
        "  Active profile:   {}",
        body["active_profile"].as_str().unwrap_or("none")
    );
    println!(
        "  Total profiles:   {}",
        body["total_profiles"].as_u64().unwrap_or(0)
    );
    println!(
        "  Detection method: {}",
        format!("{:?}", body["detection_method"]).dimmed()
    );
    if let Some(last) = body["last_switch"].as_str() {
        println!("  Last switch:      {}", last.dimmed());
    }
    Ok(())
}

async fn cmd_create(name: &str, description: &str) -> anyhow::Result<()> {
    let payload = serde_json::json!({
        "name": name,
        "description": description,
        "detection_method": "Manual",
        "rules": [],
        "priority": 5,
    });
    let _: serde_json::Value = daemon_client::post_json("/api/v1/context/profile", &payload)
        .await
        .inspect_err(|e| {
            if e.to_string().contains("is lifeosd running") {
                print_daemon_down();
            }
        })?;
    println!(
        "{} Created context profile: {}",
        "OK".green().bold(),
        name.cyan()
    );
    Ok(())
}

async fn cmd_delete(context: &str) -> anyhow::Result<()> {
    let path = format!("/api/v1/context/profile/{}", context);
    let _: serde_json::Value = daemon_client::delete_json(&path).await.inspect_err(|e| {
        if e.to_string().contains("is lifeosd running") {
            print_daemon_down();
        }
    })?;
    println!(
        "{} Deleted context profile: {}",
        "OK".green().bold(),
        context.cyan()
    );
    Ok(())
}

async fn cmd_add_rule(context: &str, rule_type: &str, value: &str) -> anyhow::Result<()> {
    let path = format!("/api/v1/context/profile/{}/rule", context);
    let payload = serde_json::json!({
        "rule_type": rule_type,
        "value": value,
    });
    let _: serde_json::Value = daemon_client::post_json(&path, &payload)
        .await
        .inspect_err(|e| {
            if e.to_string().contains("is lifeosd running") {
                print_daemon_down();
            }
        })?;
    println!(
        "{} Added rule to {}: {} = {}",
        "OK".green().bold(),
        context.cyan(),
        rule_type,
        value
    );
    Ok(())
}
