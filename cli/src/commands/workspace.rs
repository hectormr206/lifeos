//! Workspace execution commands.
//!
//! Phase 2 baseline for isolated intent execution.

use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum WorkspaceCommands {
    /// Run an intent inside an isolated workspace
    Run {
        /// Intent identifier
        #[arg(long)]
        intent: String,
        /// Optional command override (default comes from intent action)
        #[arg(long)]
        command: Option<String>,
        /// Requested isolation mode: sandbox|container|microvm
        #[arg(long, default_value = "sandbox")]
        isolation: String,
        /// Explicitly approve high/critical risk intents
        #[arg(long)]
        approve: bool,
    },
    /// List recent workspace runs
    List {
        /// Maximum number of records
        #[arg(short, long, default_value = "20")]
        limit: usize,
    },
}

pub async fn execute(cmd: WorkspaceCommands) -> anyhow::Result<()> {
    match cmd {
        WorkspaceCommands::Run {
            intent,
            command,
            isolation,
            approve,
        } => cmd_run(&intent, command.as_deref(), &isolation, approve).await,
        WorkspaceCommands::List { limit } => cmd_list(limit).await,
    }
}

async fn cmd_run(
    intent_id: &str,
    command: Option<&str>,
    isolation: &str,
    approve: bool,
) -> anyhow::Result<()> {
    let payload = serde_json::json!({
        "intent_id": intent_id,
        "command": command,
        "isolation": isolation,
        "approved": approve,
    });
    match daemon_client::post_json::<_, serde_json::Value>("/api/v1/workspace/run", &payload).await
    {
        Ok(body) => {
            let run = &body["run"];
            println!("{}", "Workspace run completed".green().bold());
            println!(
                "  Run ID:     {}",
                run["run_id"].as_str().unwrap_or("?").cyan()
            );
            println!(
                "  Intent ID:  {}",
                run["intent_id"].as_str().unwrap_or("?").cyan()
            );
            println!(
                "  Isolation:  {} -> {}",
                run["requested_isolation"].as_str().unwrap_or("?"),
                run["effective_isolation"].as_str().unwrap_or("?").dimmed()
            );
            println!(
                "  Exit code:  {}",
                run["exit_code"].as_i64().unwrap_or(-1).to_string().cyan()
            );
            println!(
                "  Succeeded:  {}",
                if run["succeeded"].as_bool().unwrap_or(false) {
                    "yes".green()
                } else {
                    "no".red()
                }
            );
            println!(
                "  Duration:   {} ms",
                run["duration_ms"].as_u64().unwrap_or(0)
            );
            println!(
                "  Workspace:  {}",
                run["workspace_path"].as_str().unwrap_or("?").dimmed()
            );

            let stdout = run["stdout"].as_str().unwrap_or("");
            if !stdout.is_empty() {
                println!();
                println!("{}", "stdout:".bold().blue());
                println!("{}", stdout);
            }

            let stderr = run["stderr"].as_str().unwrap_or("");
            if !stderr.is_empty() {
                println!();
                println!("{}", "stderr:".bold().yellow());
                println!("{}", stderr);
            }
            Ok(())
        }
        Err(e) if e.to_string().contains("HTTP 409") => {
            // Extract body from error message: "daemon returned HTTP 409: {body}"
            let msg = e.to_string();
            let body = msg
                .split_once("HTTP 409: ")
                .map(|x| x.1)
                .unwrap_or("approval required");
            println!("{}", "Workspace run blocked".yellow().bold());
            println!("  {}", body);
            println!();
            println!(
                "Retry with approval: {}",
                format!("life workspace run --intent {} --approve", intent_id).cyan()
            );
            Ok(())
        }
        Err(e) if e.to_string().contains("is lifeosd running") => {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
            Ok(())
        }
        Err(e) => anyhow::bail!("Failed to run workspace: {}", e),
    }
}

async fn cmd_list(limit: usize) -> anyhow::Result<()> {
    let limit = limit.clamp(1, 200);
    let path = format!("/api/v1/workspace/runs?limit={}", limit);
    match daemon_client::get_json::<serde_json::Value>(&path).await {
        Ok(body) => {
            println!("{}", "Workspace runs".bold().blue());
            println!();

            if let Some(runs) = body["runs"].as_array() {
                if runs.is_empty() {
                    println!("  {}", "No workspace runs yet.".dimmed());
                } else {
                    for run in runs {
                        let run_id = run["run_id"].as_str().unwrap_or("?");
                        let intent_id = run["intent_id"].as_str().unwrap_or("?");
                        let exit_code = run["exit_code"].as_i64().unwrap_or(-1);
                        let ok = run["succeeded"].as_bool().unwrap_or(false);
                        let status = if ok { "ok".green() } else { "failed".red() };
                        println!("  {} [{}] {}", run_id.cyan(), status, intent_id);
                        println!(
                            "    code={} isolation={} duration={}ms",
                            exit_code,
                            run["effective_isolation"].as_str().unwrap_or("?"),
                            run["duration_ms"].as_u64().unwrap_or(0)
                        );
                    }
                }
            }
            Ok(())
        }
        Err(e) if e.to_string().contains("is lifeosd running") => {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
            Ok(())
        }
        Err(e) => anyhow::bail!("Failed to list workspace runs: {}", e),
    }
}
