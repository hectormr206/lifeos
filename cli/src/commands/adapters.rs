use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum AdaptersCommands {
    /// Draft actionable response for an email thread
    Email {
        /// Email thread summary/content
        content: String,
    },
    /// Analyze image context (path metadata + request prompt)
    Image {
        /// Path to image file
        path: String,
        /// Optional focus instruction
        #[arg(long)]
        prompt: Option<String>,
    },
    /// Summarize and prioritize global search query intent
    Search { query: String },
}

pub async fn execute(cmd: AdaptersCommands) -> anyhow::Result<()> {
    match cmd {
        AdaptersCommands::Email { content } => {
            let prompt = format!(
                "You are the LifeOS email adapter. Draft a concise reply and next actions for this thread:\n{}",
                content
            );
            run_adapter("email", &prompt).await
        }
        AdaptersCommands::Image { path, prompt } => {
            let focus = prompt
                .unwrap_or_else(|| "Describe key elements and suggested actions.".to_string());
            let adapter_prompt = format!(
                "You are the LifeOS image adapter. Image path: {}. Instruction: {}",
                path, focus
            );
            run_adapter("image", &adapter_prompt).await
        }
        AdaptersCommands::Search { query } => {
            let prompt = format!(
                "You are the LifeOS global search adapter. Build an action-oriented search plan for: {}",
                query
            );
            run_adapter("search", &prompt).await
        }
    }
}

async fn run_adapter(name: &str, prompt: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/ai/chat", daemon_client::daemon_url()))
        .json(&serde_json::json!({
            "message": prompt,
            "stream": false
        }))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
            println!("{}", format!("AI adapter: {}", name).bold().blue());
            println!("{}", body["response"].as_str().unwrap_or("").trim());
            Ok(())
        }
        Ok(r) => {
            let status = r.status();
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Adapter '{}' failed ({}): {}", name, status, body);
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
