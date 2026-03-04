use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum VoiceCommands {
    /// Show local STT daemon status
    Status,
    /// Start STT daemon service
    Start {
        #[arg(long)]
        enable: bool,
    },
    /// Stop STT daemon service
    Stop,
    /// Transcribe local audio file
    Transcribe {
        file: String,
        #[arg(long)]
        model: Option<String>,
    },
}

pub async fn execute(cmd: VoiceCommands) -> anyhow::Result<()> {
    match cmd {
        VoiceCommands::Status => cmd_status().await,
        VoiceCommands::Start { enable } => cmd_start(enable).await,
        VoiceCommands::Stop => cmd_stop().await,
        VoiceCommands::Transcribe { file, model } => cmd_transcribe(&file, model.as_deref()).await,
    }
}

async fn cmd_status() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!(
            "{}/api/v1/audio/stt/status",
            daemon_client::daemon_url()
        ))
        .send()
        .await?;
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to get STT status: {}", body);
    }
    let body: serde_json::Value = resp.json().await?;
    println!("{}", "STT daemon status".bold().blue());
    println!("  running: {}", body["running"].as_bool().unwrap_or(false));
    println!(
        "  service: {}",
        body["service"]
            .as_str()
            .unwrap_or("whisper-stt.service")
            .cyan()
    );
    println!(
        "  binary: {}",
        body["binary"].as_str().unwrap_or("whisper-cli").dimmed()
    );
    Ok(())
}

async fn cmd_start(enable: bool) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!(
            "{}/api/v1/audio/stt/start",
            daemon_client::daemon_url()
        ))
        .json(&serde_json::json!({
            "enable": enable
        }))
        .send()
        .await?;
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to start STT daemon: {}", body);
    }
    println!("{}", "STT daemon start requested".green().bold());
    println!("  enable_on_boot: {}", enable);
    Ok(())
}

async fn cmd_stop() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!(
            "{}/api/v1/audio/stt/stop",
            daemon_client::daemon_url()
        ))
        .send()
        .await?;
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to stop STT daemon: {}", body);
    }
    println!("{}", "STT daemon stop requested".green().bold());
    Ok(())
}

async fn cmd_transcribe(file: &str, model: Option<&str>) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!(
            "{}/api/v1/audio/stt/transcribe",
            daemon_client::daemon_url()
        ))
        .json(&serde_json::json!({
            "file": file,
            "model": model,
        }))
        .send()
        .await?;
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to transcribe audio: {}", body);
    }
    let body: serde_json::Value = resp.json().await?;
    println!("{}", "STT transcription".bold().blue());
    println!("{}", body["text"].as_str().unwrap_or("").trim());
    Ok(())
}
