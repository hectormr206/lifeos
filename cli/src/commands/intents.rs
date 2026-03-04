use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum IntentsCommands {
    /// Generate plan from intent
    Plan { description: String },
    /// Apply an intent
    Apply {
        intent_id: String,
        /// Mark as explicitly approved (required for high/critical risk)
        #[arg(long)]
        approve: bool,
    },
    /// Check intent status
    Status { intent_id: String },
    /// Validate intent file
    Validate { path: String },
    /// Show intent/identity ledger entries
    Log {
        /// Max entries to return
        #[arg(short, long, default_value = "20")]
        limit: usize,
        /// Export encrypted ledger to this file path (JSON)
        #[arg(long)]
        export: Option<String>,
        /// Passphrase for encrypted export (fallback: LIFEOS_LEDGER_PASSPHRASE env)
        #[arg(long)]
        passphrase: Option<String>,
    },
    /// Runtime execution mode for autonomous intent pipeline
    #[command(subcommand)]
    Mode(IntentModeCommands),
}

#[derive(Subcommand)]
pub enum IntentModeCommands {
    /// Show current execution mode
    Status,
    /// Set execution mode
    Set {
        /// interactive | run-until-done | silent-until-done
        #[arg(value_parser = ["interactive", "run-until-done", "silent-until-done"])]
        mode: String,
        /// Actor principal changing mode
        #[arg(long, default_value = "user://local/default")]
        actor: String,
    },
}

pub async fn execute(args: IntentsCommands) -> anyhow::Result<()> {
    match args {
        IntentsCommands::Plan { description } => cmd_plan(&description).await?,
        IntentsCommands::Apply { intent_id, approve } => cmd_apply(&intent_id, approve).await?,
        IntentsCommands::Status { intent_id } => cmd_status(&intent_id).await?,
        IntentsCommands::Validate { path } => cmd_validate(&path).await?,
        IntentsCommands::Log {
            limit,
            export,
            passphrase,
        } => cmd_log(limit, export.as_deref(), passphrase.as_deref()).await?,
        IntentsCommands::Mode(mode_cmd) => cmd_mode(mode_cmd).await?,
    }
    Ok(())
}

fn daemon_url() -> String {
    daemon_client::daemon_url()
}

async fn cmd_plan(description: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/intents/plan", daemon_url()))
        .json(&serde_json::json!({ "description": description }))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            let intent = &body["intent"];
            println!("{}", "Intent planned".green().bold());
            println!(
                "  Intent ID: {}",
                intent["intent_id"].as_str().unwrap_or("?").cyan()
            );
            println!("  Action:    {}", intent["action"].as_str().unwrap_or("?"));
            println!("  Risk:      {}", intent["risk"].as_str().unwrap_or("?"));
            if let Some(plan) = intent["plan"].as_array() {
                println!("  Steps:     {}", plan.len());
            }
            println!();
            println!(
                "Apply intent: {}",
                format!(
                    "life intents apply {}",
                    intent["intent_id"].as_str().unwrap_or("<intent-id>")
                )
                .cyan()
            );
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to plan intent: {}", body);
        }
        Err(_) => {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
            Ok(())
        }
    }
}

async fn cmd_apply(intent_id: &str, approve: bool) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/intents/apply", daemon_url()))
        .json(&serde_json::json!({
            "intent_id": intent_id,
            "approved": approve
        }))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            let intent = &body["intent"];
            let status = intent["status"].as_str().unwrap_or("unknown");
            if status == "awaiting_approval" {
                println!("{}", "Intent requires approval".yellow().bold());
                println!("  Risk: {}", intent["risk"].as_str().unwrap_or("?"));
                println!(
                    "  Retry with: {}",
                    format!("life intents apply {} --approve", intent_id).cyan()
                );
            } else {
                println!("{}", "Intent applied".green().bold());
                println!("  Status: {}", status.cyan());
            }
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to apply intent: {}", body);
        }
        Err(_) => {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
            Ok(())
        }
    }
}

async fn cmd_status(intent_id: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!(
            "{}/api/v1/intents/status/{}",
            daemon_url(),
            intent_id
        ))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            let intent = &body["intent"];
            println!("{}", "Intent status".bold().blue());
            println!(
                "  Intent ID: {}",
                intent["intent_id"].as_str().unwrap_or("?")
            );
            println!(
                "  Status:    {}",
                intent["status"].as_str().unwrap_or("?").cyan()
            );
            println!("  Risk:      {}", intent["risk"].as_str().unwrap_or("?"));
            println!("  Action:    {}", intent["action"].as_str().unwrap_or("?"));
            println!(
                "  Updated:   {}",
                intent["updated_at"].as_str().unwrap_or("?").dimmed()
            );
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to get intent status: {}", body);
        }
        Err(_) => {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
            Ok(())
        }
    }
}

async fn cmd_validate(path: &str) -> anyhow::Result<()> {
    let content = std::fs::read_to_string(path)?;
    let payload: serde_json::Value = serde_json::from_str(&content)?;

    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/intents/validate", daemon_url()))
        .json(&payload)
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            let valid = body["valid"].as_bool().unwrap_or(false);
            if valid {
                println!("{}", "Intent payload is valid".green().bold());
            } else {
                println!("{}", "Intent payload is invalid".red().bold());
                if let Some(missing) = body["missing_fields"].as_array() {
                    if !missing.is_empty() {
                        println!("  Missing fields:");
                        for field in missing {
                            if let Some(field_name) = field.as_str() {
                                println!("    - {}", field_name);
                            }
                        }
                    }
                }
                if let Some(errors) = body["errors"].as_array() {
                    if !errors.is_empty() {
                        println!("  Errors:");
                        for err in errors {
                            if let Some(err_msg) = err.as_str() {
                                println!("    - {}", err_msg);
                            }
                        }
                    }
                }
            }
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to validate intent payload: {}", body);
        }
        Err(_) => {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
            Ok(())
        }
    }
}

async fn cmd_log(
    limit: usize,
    export_path: Option<&str>,
    passphrase: Option<&str>,
) -> anyhow::Result<()> {
    let limit = limit.max(1).min(500);
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!(
            "{}/api/v1/intents/log?limit={}",
            daemon_url(),
            limit
        ))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Agent ledger".bold().blue());
            println!();
            if let Some(entries) = body["entries"].as_array() {
                if entries.is_empty() {
                    println!("  {}", "No entries yet.".dimmed());
                } else {
                    for entry in entries {
                        let ts = entry["timestamp"].as_str().unwrap_or("?");
                        let category = entry["category"].as_str().unwrap_or("?");
                        let action = entry["action"].as_str().unwrap_or("?");
                        let target = entry["target"].as_str().unwrap_or("?");
                        println!(
                            "  {} [{}] {} {}",
                            ts.dimmed(),
                            category.cyan(),
                            action,
                            target
                        );
                    }
                }
            }
            if let Some(path) = export_path {
                let key = passphrase
                    .map(|s| s.to_string())
                    .or_else(|| std::env::var("LIFEOS_LEDGER_PASSPHRASE").ok())
                    .unwrap_or_else(|| "lifeos-local-dev-key".to_string());

                let export_resp = client
                    .post(format!("{}/api/v1/intents/ledger/export", daemon_url()))
                    .json(&serde_json::json!({
                        "passphrase": key,
                        "limit": limit,
                    }))
                    .send()
                    .await?;

                if export_resp.status().is_success() {
                    let export_json: serde_json::Value = export_resp.json().await?;
                    let content = serde_json::to_string_pretty(&export_json)?;
                    std::fs::write(path, content)?;
                    println!();
                    println!(
                        "{} {}",
                        "Encrypted ledger exported to".green().bold(),
                        path.cyan()
                    );
                    if passphrase.is_none() && std::env::var("LIFEOS_LEDGER_PASSPHRASE").is_err() {
                        println!(
                            "{}",
                            "Warning: using default local passphrase fallback (set --passphrase or LIFEOS_LEDGER_PASSPHRASE).".yellow()
                        );
                    }
                } else {
                    let body = export_resp.text().await.unwrap_or_default();
                    anyhow::bail!("Failed to export encrypted ledger: {}", body);
                }
            }
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to fetch ledger: {}", body);
        }
        Err(_) => {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
            Ok(())
        }
    }
}

async fn cmd_mode(cmd: IntentModeCommands) -> anyhow::Result<()> {
    match cmd {
        IntentModeCommands::Status => cmd_mode_status().await,
        IntentModeCommands::Set { mode, actor } => cmd_mode_set(&mode, &actor).await,
    }
}

async fn cmd_mode_status() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!("{}/api/v1/runtime/mode", daemon_url()))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Runtime execution mode".bold().blue());
            println!(
                "  mode: {}",
                body["mode"].as_str().unwrap_or("interactive").cyan()
            );
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to get runtime mode: {}", body);
        }
        Err(_) => {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
            Ok(())
        }
    }
}

async fn cmd_mode_set(mode: &str, actor: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/runtime/mode", daemon_url()))
        .json(&serde_json::json!({
            "mode": mode,
            "actor": actor,
        }))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Runtime execution mode updated".green().bold());
            println!("  mode: {}", body["mode"].as_str().unwrap_or(mode).cyan());
            println!("  actor: {}", actor.cyan());
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to set runtime mode: {}", body);
        }
        Err(_) => {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
            Ok(())
        }
    }
}
