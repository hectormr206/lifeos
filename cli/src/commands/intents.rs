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
    /// Run a specialist team handoff for one objective
    Orchestrate {
        objective: String,
        /// Specialists involved in order (repeatable)
        #[arg(long, required = true)]
        specialist: Vec<String>,
        /// Explicitly approve high/critical intents
        #[arg(long)]
        approve: bool,
    },
    /// List recent team orchestrations
    TeamRuns {
        /// Max runs to return
        #[arg(short, long, default_value = "20")]
        limit: usize,
    },
    /// Runtime execution mode for autonomous intent pipeline
    #[command(subcommand)]
    Mode(IntentModeCommands),
    /// Temporal Jarvis session controls (TTL + PIN + kill switch)
    #[command(subcommand)]
    Jarvis(IntentJarvisCommands),
    /// Scan text with Prompt Shield v1 policy
    Shield { input: String },
    /// Show COSMIC workspace awareness routing hints
    WorkspaceAwareness,
    /// Runtime AI resource profile and backend scheduler
    #[command(subcommand)]
    Resources(IntentResourcesCommands),
    /// Always-on micro-model controls (VAD/hotword/intent classifier)
    #[command(subcommand)]
    AlwaysOn(IntentAlwaysOnCommands),
    /// Consent-gated sensory capture runtime controls
    #[command(subcommand)]
    Sensory(IntentSensoryCommands),
    /// Route model tier by priority with automatic degradation under load
    ModelRoute {
        #[arg(value_parser = ["low", "medium", "high", "critical"])]
        priority: String,
        #[arg(long)]
        preferred_model: Option<String>,
    },
    /// Self-defense runtime controls (awareness + repair)
    #[command(subcommand)]
    Defense(IntentDefenseCommands),
    /// Heartbeats and proactive cron tick controls
    #[command(subcommand)]
    Heartbeat(IntentHeartbeatCommands),
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

#[derive(Subcommand)]
pub enum IntentJarvisCommands {
    /// Show current Jarvis session status
    Status,
    /// Start a temporary Jarvis session
    Start {
        /// PIN required for activation
        #[arg(long)]
        pin: String,
        /// Session TTL in minutes (15..60)
        #[arg(long, default_value_t = 30)]
        ttl: u32,
        /// Actor principal
        #[arg(long, default_value = "user://local/default")]
        actor: String,
    },
    /// Stop active Jarvis session
    Stop {
        /// Actor principal
        #[arg(long, default_value = "user://local/default")]
        actor: String,
    },
    /// Trigger global kill switch (Super+Escape equivalent)
    KillSwitch {
        /// Actor principal
        #[arg(long, default_value = "user://local/default")]
        actor: String,
    },
}

#[derive(Subcommand)]
pub enum IntentResourcesCommands {
    /// Show current resource profile and backend order
    Status,
    /// Set resource profile (performance|balanced|battery|silent)
    Set {
        #[arg(value_parser = ["performance", "balanced", "battery", "silent"])]
        profile: String,
        #[arg(long, default_value = "user://local/default")]
        actor: String,
    },
}

#[derive(Subcommand)]
pub enum IntentAlwaysOnCommands {
    /// Show always-on runtime status
    Status,
    /// Enable always-on runtime with wake word
    Enable {
        #[arg(long, default_value = "axi")]
        wake_word: String,
        #[arg(long, default_value = "user://local/default")]
        actor: String,
    },
    /// Disable always-on runtime
    Disable {
        #[arg(long, default_value = "user://local/default")]
        actor: String,
    },
    /// Classify an input signal via micro-intent classifier
    Classify { input: String },
}

#[derive(Subcommand)]
pub enum IntentSensoryCommands {
    /// Show sensory runtime status
    Status,
    /// Start consent-gated sensory capture
    Start {
        #[arg(long, default_value_t = true)]
        audio: bool,
        #[arg(long, default_value_t = true)]
        screen: bool,
        #[arg(long, default_value_t = false)]
        camera: bool,
        #[arg(long, default_value_t = 10)]
        interval: u64,
        #[arg(long, default_value = "user://local/default")]
        actor: String,
    },
    /// Stop sensory capture runtime
    Stop {
        #[arg(long, default_value = "user://local/default")]
        actor: String,
    },
    /// Take one sensory snapshot (optional audio transcription + screen frame)
    Snapshot {
        #[arg(long)]
        audio_file: Option<String>,
        #[arg(long)]
        model: Option<String>,
        #[arg(long)]
        no_screen: bool,
    },
}

#[derive(Subcommand)]
pub enum IntentDefenseCommands {
    /// Show self-defense awareness status
    Status,
    /// Run self-defense repair pass
    Repair {
        #[arg(long)]
        auto_rollback: bool,
        #[arg(long, default_value = "user://local/default")]
        actor: String,
    },
}

#[derive(Subcommand)]
pub enum IntentHeartbeatCommands {
    /// Show heartbeat runtime status
    Status,
    /// Enable heartbeat runtime with interval
    Enable {
        #[arg(long, default_value_t = 300)]
        interval: u64,
        #[arg(long, default_value = "user://local/default")]
        actor: String,
    },
    /// Disable heartbeat runtime
    Disable {
        #[arg(long, default_value = "user://local/default")]
        actor: String,
    },
    /// Run one proactive heartbeat tick now
    Tick {
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
        IntentsCommands::Orchestrate {
            objective,
            specialist,
            approve,
        } => cmd_orchestrate(&objective, &specialist, approve).await?,
        IntentsCommands::TeamRuns { limit } => cmd_team_runs(limit).await?,
        IntentsCommands::Mode(mode_cmd) => cmd_mode(mode_cmd).await?,
        IntentsCommands::Jarvis(jarvis_cmd) => cmd_jarvis(jarvis_cmd).await?,
        IntentsCommands::Shield { input } => cmd_shield_scan(&input).await?,
        IntentsCommands::WorkspaceAwareness => cmd_workspace_awareness().await?,
        IntentsCommands::Resources(resources_cmd) => cmd_resources(resources_cmd).await?,
        IntentsCommands::AlwaysOn(always_on_cmd) => cmd_always_on(always_on_cmd).await?,
        IntentsCommands::Sensory(sensory_cmd) => cmd_sensory(sensory_cmd).await?,
        IntentsCommands::ModelRoute {
            priority,
            preferred_model,
        } => cmd_model_route(&priority, preferred_model.as_deref()).await?,
        IntentsCommands::Defense(defense_cmd) => cmd_defense(defense_cmd).await?,
        IntentsCommands::Heartbeat(heartbeat_cmd) => cmd_heartbeat(heartbeat_cmd).await?,
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
    let limit = limit.clamp(1, 500);
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

async fn cmd_jarvis(cmd: IntentJarvisCommands) -> anyhow::Result<()> {
    match cmd {
        IntentJarvisCommands::Status => cmd_jarvis_status().await,
        IntentJarvisCommands::Start { pin, ttl, actor } => {
            cmd_jarvis_start(&pin, ttl, &actor).await
        }
        IntentJarvisCommands::Stop { actor } => cmd_jarvis_stop(&actor).await,
        IntentJarvisCommands::KillSwitch { actor } => cmd_jarvis_kill_switch(&actor).await,
    }
}

async fn cmd_jarvis_status() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!("{}/api/v1/runtime/jarvis", daemon_url()))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Jarvis session status".bold().blue());
            println!("  active: {}", body["active"].as_bool().unwrap_or(false));
            println!(
                "  activated_by: {}",
                body["activated_by"].as_str().unwrap_or("-").cyan()
            );
            println!(
                "  expires_at: {}",
                body["expires_at"].as_str().unwrap_or("-").dimmed()
            );
            println!(
                "  token_count: {}",
                body["token_ids"].as_array().map(|v| v.len()).unwrap_or(0)
            );
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to get Jarvis status: {}", body);
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

async fn cmd_jarvis_start(pin: &str, ttl: u32, actor: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/runtime/jarvis", daemon_url()))
        .json(&serde_json::json!({
            "pin": pin,
            "ttl_minutes": ttl,
            "actor": actor,
        }))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Jarvis session started".green().bold());
            println!(
                "  expires_at: {}",
                body["jarvis"]["expires_at"].as_str().unwrap_or("-").cyan()
            );
            println!("  ttl_minutes: {}", ttl);
            println!("  actor: {}", actor.cyan());
            println!(
                "  hint: {}",
                "Use `life intents jarvis kill-switch` for emergency stop.".dimmed()
            );
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to start Jarvis session: {}", body);
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

async fn cmd_jarvis_stop(actor: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/runtime/jarvis/stop", daemon_url()))
        .json(&serde_json::json!({
            "actor": actor
        }))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            println!("{}", "Jarvis session stopped".green().bold());
            println!("  actor: {}", actor.cyan());
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to stop Jarvis session: {}", body);
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

async fn cmd_jarvis_kill_switch(actor: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!(
            "{}/api/v1/runtime/jarvis/kill-switch",
            daemon_url()
        ))
        .json(&serde_json::json!({
            "actor": actor
        }))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            println!("{}", "Jarvis kill-switch triggered".yellow().bold());
            println!("  actor: {}", actor.cyan());
            println!(
                "  status: {}",
                "execution mode reset to interactive, trust mode disabled".dimmed()
            );
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to trigger Jarvis kill-switch: {}", body);
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

async fn cmd_shield_scan(input: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!(
            "{}/api/v1/runtime/prompt-shield/scan",
            daemon_url()
        ))
        .json(&serde_json::json!({
            "input": input,
        }))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Prompt Shield scan".bold().blue());
            println!("  blocked: {}", body["blocked"].as_bool().unwrap_or(false));
            println!("  score: {:.2}", body["score"].as_f64().unwrap_or(0.0_f64));
            println!("  reason: {}", body["reason"].as_str().unwrap_or("-"));
            if let Some(matches) = body["matched_rules"].as_array() {
                if !matches.is_empty() {
                    println!("  matched_rules:");
                    for rule in matches {
                        println!("    - {}", rule.as_str().unwrap_or("?").dimmed());
                    }
                }
            }
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to scan prompt shield: {}", body);
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

async fn cmd_workspace_awareness() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!(
            "{}/api/v1/runtime/workspace-awareness",
            daemon_url()
        ))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Workspace awareness".bold().blue());
            println!(
                "  desktop: {}",
                body["desktop"].as_str().unwrap_or("unknown").cyan()
            );
            println!(
                "  workspace: {}",
                body["workspace"].as_str().unwrap_or("default").cyan()
            );
            println!(
                "  habitat: {}",
                body["habitat"].as_str().unwrap_or("general").cyan()
            );
            if let Some(suggestions) = body["suggestions"].as_array() {
                println!("  suggestions:");
                for suggestion in suggestions {
                    println!("    - {}", suggestion.as_str().unwrap_or("?").dimmed());
                }
            }
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to get workspace awareness: {}", body);
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

async fn cmd_resources(cmd: IntentResourcesCommands) -> anyhow::Result<()> {
    match cmd {
        IntentResourcesCommands::Status => cmd_resources_status().await,
        IntentResourcesCommands::Set { profile, actor } => {
            cmd_resources_set(&profile, &actor).await
        }
    }
}

async fn cmd_resources_status() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!("{}/api/v1/runtime/resources", daemon_url()))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Runtime resources".bold().blue());
            println!(
                "  profile: {}",
                body["profile"].as_str().unwrap_or("balanced").cyan()
            );
            println!(
                "  heavy_model_slots: {}",
                body["heavy_model_slots"].as_u64().unwrap_or(1)
            );
            println!(
                "  cgroup_enabled: {}",
                body["cgroup_enabled"].as_bool().unwrap_or(false)
            );
            let order = body["backend_order"]
                .as_array()
                .map(|values| {
                    values
                        .iter()
                        .filter_map(|value| value.as_str())
                        .collect::<Vec<_>>()
                        .join(" -> ")
                })
                .unwrap_or_else(|| "cpu".to_string());
            println!("  backend_order: {}", order.cyan());
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to read runtime resources: {}", body);
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

async fn cmd_resources_set(profile: &str, actor: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/runtime/resources", daemon_url()))
        .json(&serde_json::json!({
            "profile": profile,
            "actor": actor,
        }))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Runtime resource profile updated".green().bold());
            println!(
                "  profile: {}",
                body["resources"]["profile"]
                    .as_str()
                    .unwrap_or(profile)
                    .cyan()
            );
            println!("  actor: {}", actor.cyan());
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to set runtime resources: {}", body);
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

async fn cmd_always_on(cmd: IntentAlwaysOnCommands) -> anyhow::Result<()> {
    match cmd {
        IntentAlwaysOnCommands::Status => cmd_always_on_status().await,
        IntentAlwaysOnCommands::Enable { wake_word, actor } => {
            cmd_always_on_set(true, &wake_word, &actor).await
        }
        IntentAlwaysOnCommands::Disable { actor } => cmd_always_on_set(false, "axi", &actor).await,
        IntentAlwaysOnCommands::Classify { input } => cmd_always_on_classify(&input).await,
    }
}

async fn cmd_always_on_status() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!("{}/api/v1/runtime/always-on", daemon_url()))
        .send()
        .await;
    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Always-on micro-model runtime".bold().blue());
            println!("  enabled: {}", body["enabled"].as_bool().unwrap_or(false));
            println!(
                "  wake_word: {}",
                body["wake_word"].as_str().unwrap_or("-").cyan()
            );
            println!(
                "  vad/hotword/classifier: {}/{}/{}",
                body["vad_enabled"].as_bool().unwrap_or(false),
                body["hotword_enabled"].as_bool().unwrap_or(false),
                body["intent_classifier_enabled"].as_bool().unwrap_or(false)
            );
            println!(
                "  last_label: {}",
                body["last_inference_label"]
                    .as_str()
                    .unwrap_or("-")
                    .dimmed()
            );
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to get always-on status: {}", body)
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

async fn cmd_always_on_set(enabled: bool, wake_word: &str, actor: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/runtime/always-on", daemon_url()))
        .json(&serde_json::json!({
            "enabled": enabled,
            "wake_word": wake_word,
            "actor": actor,
        }))
        .send()
        .await;
    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!(
                "{}",
                if enabled {
                    "Always-on runtime enabled".green().bold()
                } else {
                    "Always-on runtime disabled".yellow().bold()
                }
            );
            println!(
                "  wake_word: {}",
                body["always_on"]["wake_word"]
                    .as_str()
                    .unwrap_or(wake_word)
                    .cyan()
            );
            println!("  actor: {}", actor.cyan());
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to update always-on runtime: {}", body)
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

async fn cmd_always_on_classify(input: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!(
            "{}/api/v1/runtime/always-on/classify",
            daemon_url()
        ))
        .json(&serde_json::json!({ "input": input }))
        .send()
        .await;
    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            let cls = &body["classification"];
            println!("{}", "Always-on classification".bold().blue());
            println!("  label: {}", cls["label"].as_str().unwrap_or("-").cyan());
            println!(
                "  confidence: {:.2}",
                cls["confidence"].as_f64().unwrap_or(0.0)
            );
            println!(
                "  hotword_detected: {}",
                cls["hotword_detected"].as_bool().unwrap_or(false)
            );
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to classify always-on signal: {}", body)
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

async fn cmd_sensory(cmd: IntentSensoryCommands) -> anyhow::Result<()> {
    match cmd {
        IntentSensoryCommands::Status => cmd_sensory_status().await,
        IntentSensoryCommands::Start {
            audio,
            screen,
            camera,
            interval,
            actor,
        } => cmd_sensory_set(true, audio, screen, camera, interval, &actor).await,
        IntentSensoryCommands::Stop { actor } => {
            cmd_sensory_set(false, false, false, false, 10, &actor).await
        }
        IntentSensoryCommands::Snapshot {
            audio_file,
            model,
            no_screen,
        } => cmd_sensory_snapshot(audio_file.as_deref(), model.as_deref(), !no_screen).await,
    }
}

async fn cmd_sensory_status() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!("{}/api/v1/runtime/sensory", daemon_url()))
        .send()
        .await;
    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Sensory runtime".bold().blue());
            println!("  enabled: {}", body["enabled"].as_bool().unwrap_or(false));
            println!("  running: {}", body["running"].as_bool().unwrap_or(false));
            println!(
                "  audio/screen/camera: {}/{}/{}",
                body["audio_enabled"].as_bool().unwrap_or(false),
                body["screen_enabled"].as_bool().unwrap_or(false),
                body["camera_enabled"].as_bool().unwrap_or(false)
            );
            println!(
                "  kill_switch_active: {}",
                body["kill_switch_active"].as_bool().unwrap_or(false)
            );
            println!(
                "  capture_interval_seconds: {}",
                body["capture_interval_seconds"].as_u64().unwrap_or(10)
            );
            println!(
                "  last_screen_path: {}",
                body["last_screen_path"].as_str().unwrap_or("-").dimmed()
            );
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to get sensory status: {}", body)
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

async fn cmd_sensory_set(
    enabled: bool,
    audio: bool,
    screen: bool,
    camera: bool,
    interval: u64,
    actor: &str,
) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/runtime/sensory", daemon_url()))
        .json(&serde_json::json!({
            "enabled": enabled,
            "audio_enabled": audio,
            "screen_enabled": screen,
            "camera_enabled": camera,
            "capture_interval_seconds": interval,
            "actor": actor,
        }))
        .send()
        .await;
    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!(
                "{}",
                if enabled {
                    "Sensory runtime started".green().bold()
                } else {
                    "Sensory runtime stopped".yellow().bold()
                }
            );
            println!(
                "  audio/screen/camera: {}/{}/{}",
                body["sensory"]["audio_enabled"].as_bool().unwrap_or(false),
                body["sensory"]["screen_enabled"].as_bool().unwrap_or(false),
                body["sensory"]["camera_enabled"].as_bool().unwrap_or(false)
            );
            println!(
                "  capture_interval_seconds: {}",
                body["sensory"]["capture_interval_seconds"]
                    .as_u64()
                    .unwrap_or(10)
            );
            println!("  actor: {}", actor.cyan());
            if enabled {
                println!(
                    "  stt_started: {}",
                    body["stt_started"].as_bool().unwrap_or(false)
                );
            }
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to update sensory runtime: {}", body)
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

async fn cmd_sensory_snapshot(
    audio_file: Option<&str>,
    model: Option<&str>,
    include_screen: bool,
) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/runtime/sensory/snapshot", daemon_url()))
        .json(&serde_json::json!({
            "include_screen": include_screen,
            "audio_file": audio_file,
            "model": model,
        }))
        .send()
        .await;
    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Sensory snapshot".bold().blue());
            println!(
                "  screen_path: {}",
                body["snapshot"]["screen_path"]
                    .as_str()
                    .unwrap_or("-")
                    .dimmed()
            );
            println!(
                "  transcript: {}",
                body["snapshot"]["transcript"].as_str().unwrap_or("").trim()
            );
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to capture sensory snapshot: {}", body)
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

async fn cmd_model_route(priority: &str, preferred_model: Option<&str>) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/runtime/model-routing", daemon_url()))
        .json(&serde_json::json!({
            "priority": priority,
            "preferred_model": preferred_model,
        }))
        .send()
        .await;
    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            let decision = &body["decision"];
            println!("{}", "Model routing decision".bold().blue());
            println!(
                "  priority: {}",
                decision["priority"].as_str().unwrap_or("-")
            );
            println!(
                "  selected_tier: {}",
                decision["selected_tier"].as_str().unwrap_or("-").cyan()
            );
            println!(
                "  model_hint: {}",
                decision["model_hint"].as_str().unwrap_or("-").cyan()
            );
            println!(
                "  degraded: {}",
                decision["degraded"].as_bool().unwrap_or(false)
            );
            println!(
                "  pressure(cpu/mem): {:.1}%/{:.1}%",
                decision["cpu_pressure_percent"].as_f64().unwrap_or(0.0),
                decision["memory_pressure_percent"].as_f64().unwrap_or(0.0)
            );
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to route model: {}", body)
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

async fn cmd_defense(cmd: IntentDefenseCommands) -> anyhow::Result<()> {
    match cmd {
        IntentDefenseCommands::Status => cmd_defense_status().await,
        IntentDefenseCommands::Repair {
            auto_rollback,
            actor,
        } => cmd_defense_repair(auto_rollback, &actor).await,
    }
}

async fn cmd_defense_status() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!("{}/api/v1/runtime/self-defense", daemon_url()))
        .send()
        .await;
    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Self-defense status".bold().blue());
            println!(
                "  situational_awareness: {}",
                body["situational_awareness"].as_str().unwrap_or("-").cyan()
            );
            println!(
                "  ai_service_running/network_online: {}/{}",
                body["ai_service_running"].as_bool().unwrap_or(false),
                body["network_online"].as_bool().unwrap_or(false)
            );
            println!(
                "  degraded_offline: {}",
                body["degraded_offline"].as_bool().unwrap_or(false)
            );
            if let Some(actions) = body["recommended_actions"].as_array() {
                if !actions.is_empty() {
                    println!("  recommended_actions:");
                    for action in actions {
                        println!("    - {}", action.as_str().unwrap_or("?").dimmed());
                    }
                }
            }
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to get self-defense status: {}", body)
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

async fn cmd_defense_repair(auto_rollback: bool, actor: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!(
            "{}/api/v1/runtime/self-defense/repair",
            daemon_url()
        ))
        .json(&serde_json::json!({
            "auto_rollback": auto_rollback,
            "actor": actor,
        }))
        .send()
        .await;
    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Self-defense repair executed".green().bold());
            if let Some(actions) = body["repair"]["actions_taken"].as_array() {
                if !actions.is_empty() {
                    println!("  actions_taken:");
                    for action in actions {
                        println!("    - {}", action.as_str().unwrap_or("?").dimmed());
                    }
                }
            }
            println!("  actor: {}", actor.cyan());
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to run self-defense repair: {}", body)
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

async fn cmd_heartbeat(cmd: IntentHeartbeatCommands) -> anyhow::Result<()> {
    match cmd {
        IntentHeartbeatCommands::Status => cmd_heartbeat_status().await,
        IntentHeartbeatCommands::Enable { interval, actor } => {
            cmd_heartbeat_set(true, Some(interval), &actor).await
        }
        IntentHeartbeatCommands::Disable { actor } => cmd_heartbeat_set(false, None, &actor).await,
        IntentHeartbeatCommands::Tick { actor } => cmd_heartbeat_tick(&actor).await,
    }
}

async fn cmd_heartbeat_status() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!("{}/api/v1/runtime/heartbeat", daemon_url()))
        .send()
        .await;
    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Heartbeat runtime".bold().blue());
            println!("  enabled: {}", body["enabled"].as_bool().unwrap_or(false));
            println!(
                "  interval_seconds: {}",
                body["interval_seconds"].as_u64().unwrap_or(300)
            );
            println!(
                "  last_tick_at: {}",
                body["last_tick_at"].as_str().unwrap_or("-").dimmed()
            );
            println!(
                "  last_summary: {}",
                body["last_summary"].as_str().unwrap_or("-").dimmed()
            );
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to get heartbeat status: {}", body)
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

async fn cmd_heartbeat_set(
    enabled: bool,
    interval_seconds: Option<u64>,
    actor: &str,
) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/runtime/heartbeat", daemon_url()))
        .json(&serde_json::json!({
            "enabled": enabled,
            "interval_seconds": interval_seconds,
            "actor": actor,
        }))
        .send()
        .await;
    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!(
                "{}",
                if enabled {
                    "Heartbeat runtime enabled".green().bold()
                } else {
                    "Heartbeat runtime disabled".yellow().bold()
                }
            );
            println!(
                "  interval_seconds: {}",
                body["heartbeat"]["interval_seconds"]
                    .as_u64()
                    .unwrap_or(300)
            );
            println!("  actor: {}", actor.cyan());
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to update heartbeat runtime: {}", body)
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

async fn cmd_heartbeat_tick(actor: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/runtime/heartbeat/tick", daemon_url()))
        .json(&serde_json::json!({
            "actor": actor,
        }))
        .send()
        .await;
    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Heartbeat tick executed".green().bold());
            println!(
                "  awareness: {}",
                body["tick"]["awareness"].as_str().unwrap_or("-").cyan()
            );
            if let Some(actions) = body["tick"]["actions"].as_array() {
                if !actions.is_empty() {
                    println!("  actions:");
                    for action in actions {
                        println!("    - {}", action.as_str().unwrap_or("?").dimmed());
                    }
                }
            }
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to run heartbeat tick: {}", body)
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

async fn cmd_orchestrate(
    objective: &str,
    specialists: &[String],
    approve: bool,
) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/orchestrator/team-run", daemon_url()))
        .json(&serde_json::json!({
            "objective": objective,
            "specialists": specialists,
            "approved": approve,
        }))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            let run = &body["run"];
            println!("{}", "Team orchestration started".green().bold());
            println!(
                "  Run ID:    {}",
                run["run_id"].as_str().unwrap_or("?").cyan()
            );
            println!("  Objective: {}", run["objective"].as_str().unwrap_or("?"));
            println!(
                "  Status:    {}",
                run["status"].as_str().unwrap_or("?").cyan()
            );
            if let Some(steps) = run["steps"].as_array() {
                println!("  Steps:     {}", steps.len());
                for step in steps {
                    println!(
                        "    - {} => {}",
                        step["specialist"].as_str().unwrap_or("?").cyan(),
                        step["status"].as_str().unwrap_or("?")
                    );
                }
            }
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to orchestrate team run: {}", body);
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

async fn cmd_team_runs(limit: usize) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!(
            "{}/api/v1/orchestrator/team-runs?limit={}",
            daemon_url(),
            limit.clamp(1, 200)
        ))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", "Team orchestrations".bold().blue());
            if let Some(runs) = body["runs"].as_array() {
                if runs.is_empty() {
                    println!("  {}", "No team runs yet.".dimmed());
                } else {
                    for run in runs {
                        println!(
                            "  {} [{}] {}",
                            run["run_id"].as_str().unwrap_or("?").cyan(),
                            run["status"].as_str().unwrap_or("?"),
                            run["objective"].as_str().unwrap_or("?")
                        );
                    }
                }
            }
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to list team runs: {}", body);
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
