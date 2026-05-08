use clap::Subcommand;
use colored::Colorize;
use dialoguer::{theme::ColorfulTheme, Confirm, Input, Select};
use serde::{Deserialize, Serialize};

use crate::daemon_client;

#[derive(Subcommand)]
pub enum WorkflowCommands {
    /// Interactive no-code workflow builder (TUI)
    Build {
        #[arg(long, default_value = "life-workflow.json")]
        output: String,
    },
    /// Validate workflow definition file
    Validate { path: String },
    /// Run workflow via team orchestrator
    Run {
        path: String,
        /// Explicit approval for high-risk generated intents
        #[arg(long)]
        approve: bool,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct WorkflowManifest {
    schema_version: String,
    name: String,
    objective: String,
    specialists: Vec<String>,
    steps: Vec<WorkflowStep>,
    created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct WorkflowStep {
    id: String,
    kind: String,
    description: String,
}

pub async fn execute(cmd: WorkflowCommands) -> anyhow::Result<()> {
    match cmd {
        WorkflowCommands::Build { output } => cmd_build(&output),
        WorkflowCommands::Validate { path } => cmd_validate(&path),
        WorkflowCommands::Run { path, approve } => cmd_run(&path, approve).await,
    }
}

fn cmd_build(output: &str) -> anyhow::Result<()> {
    let theme = ColorfulTheme::default();
    println!("{}", "Workflow Builder (No-Code)".bold().blue());

    let name: String = Input::with_theme(&theme)
        .with_prompt("Workflow name")
        .default("LifeOS Flow".to_string())
        .interact_text()?;
    let objective: String = Input::with_theme(&theme)
        .with_prompt("Main objective")
        .default("Complete assigned objective safely".to_string())
        .interact_text()?;

    let mut specialists = Vec::new();
    loop {
        let specialist: String = Input::with_theme(&theme)
            .with_prompt("Add specialist (e.g. planner, implementer, reviewer)")
            .allow_empty(true)
            .interact_text()?;
        let specialist = specialist.trim().to_string();
        if specialist.is_empty() {
            if !specialists.is_empty() {
                break;
            }
            println!("{}", "At least one specialist is required.".yellow());
            continue;
        }
        specialists.push(specialist);
        let add_more = Confirm::with_theme(&theme)
            .with_prompt("Add another specialist?")
            .default(true)
            .interact()?;
        if !add_more {
            break;
        }
    }

    let mut steps = Vec::new();
    let step_kinds = vec!["intent", "workspace", "browser", "memory", "done"];
    let mut idx = 1usize;
    loop {
        let selected = Select::with_theme(&theme)
            .with_prompt("Select step kind")
            .items(&step_kinds)
            .default(0)
            .interact()?;
        let kind = step_kinds[selected];
        if kind == "done" {
            break;
        }
        let description: String = Input::with_theme(&theme)
            .with_prompt(format!("Describe step #{}", idx))
            .interact_text()?;
        steps.push(WorkflowStep {
            id: format!("step-{}", idx),
            kind: kind.to_string(),
            description,
        });
        idx += 1;
    }

    if steps.is_empty() {
        steps.push(WorkflowStep {
            id: "step-1".to_string(),
            kind: "intent".to_string(),
            description: objective.clone(),
        });
    }

    let manifest = WorkflowManifest {
        schema_version: "life-workflow/v1".to_string(),
        name,
        objective,
        specialists,
        steps,
        created_at: chrono::Utc::now().to_rfc3339(),
    };
    validate_manifest(&manifest)?;
    std::fs::write(output, serde_json::to_string_pretty(&manifest)?)?;

    println!("{}", "Workflow generated".green().bold());
    println!("  file: {}", output.cyan());
    Ok(())
}

fn cmd_validate(path: &str) -> anyhow::Result<()> {
    let manifest = load_manifest(path)?;
    validate_manifest(&manifest)?;
    println!("{}", "Workflow valid".green().bold());
    println!("  name: {}", manifest.name.cyan());
    println!("  specialists: {}", manifest.specialists.len());
    println!("  steps: {}", manifest.steps.len());
    Ok(())
}

async fn cmd_run(path: &str, approve: bool) -> anyhow::Result<()> {
    let manifest = load_manifest(path)?;
    validate_manifest(&manifest)?;

    let payload = serde_json::json!({
        "objective": manifest.objective,
        "specialists": manifest.specialists,
        "approved": approve,
    });
    let body: serde_json::Value =
        daemon_client::post_json("/api/v1/orchestrator/team-run", &payload).await?;

    println!("{}", "Workflow executed".green().bold());
    println!(
        "  run_id: {}",
        body["run"]["run_id"].as_str().unwrap_or("?").cyan()
    );
    println!(
        "  status: {}",
        body["run"]["status"].as_str().unwrap_or("?")
    );
    Ok(())
}

fn load_manifest(path: &str) -> anyhow::Result<WorkflowManifest> {
    let raw = std::fs::read_to_string(path)?;
    let parsed = serde_json::from_str::<WorkflowManifest>(&raw)
        .map_err(|e| anyhow::anyhow!("Invalid workflow JSON '{}': {}", path, e))?;
    Ok(parsed)
}

fn validate_manifest(manifest: &WorkflowManifest) -> anyhow::Result<()> {
    if manifest.schema_version != "life-workflow/v1" {
        anyhow::bail!("Unsupported schema_version '{}'", manifest.schema_version);
    }
    if manifest.name.trim().is_empty() {
        anyhow::bail!("Workflow name is required");
    }
    if manifest.objective.trim().is_empty() {
        anyhow::bail!("Workflow objective is required");
    }
    if manifest.specialists.is_empty() {
        anyhow::bail!("Workflow must include at least one specialist");
    }
    if manifest.steps.is_empty() {
        anyhow::bail!("Workflow must include at least one step");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_manifest_requires_specialists() {
        let manifest = WorkflowManifest {
            schema_version: "life-workflow/v1".to_string(),
            name: "demo".to_string(),
            objective: "test".to_string(),
            specialists: vec![],
            steps: vec![WorkflowStep {
                id: "step-1".to_string(),
                kind: "intent".to_string(),
                description: "test".to_string(),
            }],
            created_at: chrono::Utc::now().to_rfc3339(),
        };
        assert!(validate_manifest(&manifest).is_err());
    }
}
