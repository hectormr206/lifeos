use crate::config;
use anyhow::Result;
use clap::{Args, Subcommand};
use colored::Colorize;
use serde::{Deserialize, Serialize};

#[derive(Args)]
pub struct LabArgs {
    #[command(subcommand)]
    pub command: LabCommands,
}

#[derive(Subcommand)]
pub enum LabCommands {
    #[command(about = "Show lab status")]
    Status {
        #[arg(long)]
        json: bool,
    },

    #[command(about = "Start a new experiment")]
    Start {
        #[arg(value_name = "TYPE")]
        experiment_type: String,
        #[arg(value_name = "HYPOTHESIS")]
        hypothesis: String,
    },

    #[command(about = "Start canary phase")]
    Canary {
        #[arg(value_name = "EXPERIMENT_ID")]
        experiment_id: String,
    },

    #[command(about = "Promote experiment")]
    Promote {
        #[arg(value_name = "EXPERIMENT_ID")]
        experiment_id: String,
    },

    #[command(about = "Rollback experiment")]
    Rollback {
        #[arg(value_name = "EXPERIMENT_ID")]
        experiment_id: String,
        #[arg(short, long)]
        reason: Option<String>,
    },

    #[command(about = "Generate experiment report")]
    Report {
        #[arg(value_name = "EXPERIMENT_ID")]
        experiment_id: String,
        #[arg(long)]
        json: bool,
    },

    #[command(about = "Show experiment history")]
    History {
        #[arg(long)]
        json: bool,
        #[arg(short = 'n', long, default_value = "10")]
        limit: usize,
    },
}

#[derive(Debug, Serialize, Deserialize)]
struct LabStatusResponse {
    current_experiment: Option<ExperimentInfo>,
    completed_experiments: usize,
    canary_active: bool,
    last_run: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ExperimentInfo {
    id: String,
    experiment_type: String,
    hypothesis: String,
    status: String,
    started_at: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct StartExperimentRequest {
    experiment_type: String,
    hypothesis: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct StartExperimentResponse {
    experiment_id: String,
    status: String,
    message: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct ExperimentReportResponse {
    experiment: ExperimentInfo,
    result: Option<ExperimentResultInfo>,
    recommendation: String,
    next_steps: Vec<String>,
    risk_level: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct ExperimentResultInfo {
    completed_at: String,
    success: bool,
    improvement_score: f32,
    rollback_performed: bool,
}

#[derive(Debug, Serialize, Deserialize)]
struct HistoryResponse {
    experiments: Vec<ExperimentHistoryItem>,
    count: usize,
}

#[derive(Debug, Serialize, Deserialize)]
struct ExperimentHistoryItem {
    id: String,
    experiment_type: String,
    hypothesis: String,
    success: bool,
    completed_at: String,
    improvement_score: f32,
}

pub async fn execute(args: LabArgs) -> Result<()> {
    match args.command {
        LabCommands::Status { json } => execute_status(json).await,
        LabCommands::Start {
            experiment_type,
            hypothesis,
        } => execute_start(experiment_type, hypothesis).await,
        LabCommands::Canary { experiment_id } => execute_canary(experiment_id).await,
        LabCommands::Promote { experiment_id } => execute_promote(experiment_id).await,
        LabCommands::Rollback {
            experiment_id,
            reason,
        } => execute_rollback(experiment_id, reason).await,
        LabCommands::Report {
            experiment_id,
            json,
        } => execute_report(experiment_id, json).await,
        LabCommands::History { json, limit } => execute_history(json, limit).await,
    }
}

async fn execute_status(json: bool) -> Result<()> {
    let client = DaemonClient::new().await?;

    let response: LabStatusResponse = client.get("/api/v1/lab/status").await?;

    if json {
        println!("{}", serde_json::to_string_pretty(&response)?);
    } else {
        print_status_report(&response);
    }

    Ok(())
}

fn print_status_report(status: &LabStatusResponse) {
    println!("{}", "LifeOS Lab Status".bold().blue());
    println!();

    if let Some(ref exp) = status.current_experiment {
        println!("{}", "Current Experiment:".bold());
        println!("  ID: {}", exp.id.cyan());
        println!("  Type: {}", exp.experiment_type);
        println!("  Status: {}", colorize_status(&exp.status));
        println!("  Hypothesis: {}", exp.hypothesis);
        println!("  Started: {}", exp.started_at);
    } else {
        println!("  {}", "No active experiment".yellow());
    }

    println!();
    println!(
        "  Completed experiments: {}",
        status.completed_experiments.to_string().green()
    );
    println!(
        "  Canary active: {}",
        if status.canary_active {
            "Yes".green()
        } else {
            "No".yellow()
        }
    );

    if let Some(ref last_run) = status.last_run {
        println!("  Last run: {}", last_run);
    }
}

async fn execute_start(experiment_type: String, hypothesis: String) -> Result<()> {
    let client = DaemonClient::new().await?;

    let request = StartExperimentRequest {
        experiment_type,
        hypothesis,
    };

    println!("Starting experiment...");

    let response: StartExperimentResponse = client
        .post("/api/v1/lab/experiment", &request)
        .await?;

    println!();
    println!("{}", "✓ Experiment started".green().bold());
    println!("  ID: {}", response.experiment_id.cyan());
    println!("  Status: {}", colorize_status(&response.status));
    println!("  {}", response.message);

    Ok(())
}

async fn execute_canary(experiment_id: String) -> Result<()> {
    let client = DaemonClient::new().await?;

    println!("Starting canary phase for experiment {}...", experiment_id.cyan());

    let _: serde_json::Value = client
        .post(&format!("/api/v1/lab/experiment/{}/canary", experiment_id), &())
        .await?;

    println!("{}", "✓ Canary phase started".green().bold());
    println!("  The system will monitor metrics for the configured duration.");

    Ok(())
}

async fn execute_promote(experiment_id: String) -> Result<()> {
    let client = DaemonClient::new().await?;

    println!("Promoting experiment {}...", experiment_id.cyan());

    let _: serde_json::Value = client
        .post(&format!("/api/v1/lab/experiment/{}/promote", experiment_id), &())
        .await?;

    println!("{}", "✓ Experiment promoted successfully".green().bold());
    println!("  Changes have been applied permanently.");

    Ok(())
}

async fn execute_rollback(experiment_id: String, reason: Option<String>) -> Result<()> {
    let client = DaemonClient::new().await?;

    let reason_text = reason.unwrap_or_else(|| "Manual rollback".to_string());

    println!("Rolling back experiment {}...", experiment_id.cyan());
    println!("  Reason: {}", reason_text);

    let _: serde_json::Value = client
        .post(
            &format!("/api/v1/lab/experiment/{}/rollback", experiment_id),
            &serde_json::json!({ "reason": reason_text }),
        )
        .await?;

    println!("{}", "✓ Experiment rolled back".yellow().bold());
    println!("  All changes have been reverted.");

    Ok(())
}

async fn execute_report(experiment_id: String, json: bool) -> Result<()> {
    let client = DaemonClient::new().await?;

    let response: ExperimentReportResponse = client
        .get(&format!("/api/v1/lab/experiment/{}/report", experiment_id))
        .await?;

    if json {
        println!("{}", serde_json::to_string_pretty(&response)?);
    } else {
        print_experiment_report(&response);
    }

    Ok(())
}

fn print_experiment_report(report: &ExperimentReportResponse) {
    println!("{}", "Experiment Report".bold().blue());
    println!();

    println!("{}", "Experiment Details:".bold());
    println!("  ID: {}", report.experiment.id.cyan());
    println!("  Type: {}", report.experiment.experiment_type);
    println!("  Status: {}", colorize_status(&report.experiment.status));
    println!("  Hypothesis: {}", report.experiment.hypothesis);
    println!("  Started: {}", report.experiment.started_at);

    if let Some(ref result) = report.result {
        println!();
        println!("{}", "Results:".bold());
        println!(
            "  Outcome: {}",
            if result.success {
                "Success".green()
            } else {
                "Failed".red()
            }
        );
        println!("  Completed: {}", result.completed_at);
        println!("  Improvement score: {:.2}%", result.improvement_score);
        println!(
            "  Rollback performed: {}",
            if result.rollback_performed {
                "Yes".yellow()
            } else {
                "No".green()
            }
        );
    }

    println!();
    println!("{}", "Recommendation:".bold());
    println!("  {}", report.recommendation);

    println!();
    println!("{}", "Next Steps:".bold());
    for (i, step) in report.next_steps.iter().enumerate() {
        println!("  {}. {}", i + 1, step);
    }

    println!();
    println!(
        "Risk Level: {}",
        colorize_risk_level(&report.risk_level)
    );
}

async fn execute_history(json: bool, limit: usize) -> Result<()> {
    let client = DaemonClient::new().await?;

    let response: HistoryResponse = client
        .get(&format!("/api/v1/lab/history?limit={}", limit))
        .await?;

    if json {
        println!("{}", serde_json::to_string_pretty(&response)?);
    } else {
        print_history(&response);
    }

    Ok(())
}

fn print_history(history: &HistoryResponse) {
    println!("{}", "Experiment History".bold().blue());
    println!();

    if history.experiments.is_empty() {
        println!("  No experiments completed yet.");
        return;
    }

    for exp in &history.experiments {
        println!(
            "{} {}",
            if exp.success { "✓".green() } else { "✗".red() },
            exp.id.cyan()
        );
        println!("  Type: {}", exp.experiment_type);
        println!("  Hypothesis: {}", exp.hypothesis);
        println!("  Completed: {}", exp.completed_at);
        println!("  Improvement: {:.2}%", exp.improvement_score);
        println!();
    }

    println!("Total: {} experiments", history.count);
}

fn colorize_status(status: &str) -> colored::ColoredString {
    match status {
        "proposed" => status.yellow(),
        "running" => status.blue(),
        "canary" => status.cyan(),
        "promoted" => status.green(),
        "rolled_back" => status.yellow(),
        "failed" => status.red(),
        _ => status.normal(),
    }
}

fn colorize_risk_level(level: &str) -> colored::ColoredString {
    match level {
        "low" => level.green(),
        "medium" => level.yellow(),
        "high" => level.bright_yellow(),
        "critical" => level.red(),
        _ => level.normal(),
    }
}

struct DaemonClient {
    base_url: String,
    token: Option<String>,
}

impl DaemonClient {
    async fn new() -> Result<Self> {
        let _config = config::load_config().ok();

        let runtime_dir =
            std::env::var("LIFEOS_RUNTIME_DIR").unwrap_or_else(|_| "/run/lifeos".to_string());
        let token_path = std::path::Path::new(&runtime_dir).join("bootstrap.token");
        let token = if token_path.exists() {
            Some(tokio::fs::read_to_string(&token_path).await?)
        } else {
            None
        };

        let base_url = std::env::var("LIFEOS_API_URL")
            .unwrap_or_else(|_| "http://127.0.0.1:8081".to_string());

        Ok(Self { base_url, token })
    }

    async fn get<T: for<'de> Deserialize<'de>>(&self, path: &str) -> Result<T> {
        let mut req = reqwest::Client::new().get(format!("{}{}", self.base_url, path));

        if let Some(ref token) = self.token {
            req = req.header("X-Bootstrap-Token", token);
        }

        let response = req.send().await?;

        if !response.status().is_success() {
            let error = response.text().await?;
            anyhow::bail!("API error: {}", error);
        }

        let data = response.json().await?;
        Ok(data)
    }

    async fn post<T: Serialize, R: for<'de> Deserialize<'de>>(
        &self,
        path: &str,
        body: &T,
    ) -> Result<R> {
        let mut req = reqwest::Client::new().post(format!("{}{}", self.base_url, path));

        if let Some(ref token) = self.token {
            req = req.header("X-Bootstrap-Token", token);
        }

        let response = req.json(body).send().await?;

        if !response.status().is_success() {
            let error = response.text().await?;
            anyhow::bail!("API error: {}", error);
        }

        let data = response.json().await?;
        Ok(data)
    }
}
