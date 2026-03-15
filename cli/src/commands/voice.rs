use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum VoiceCommands {
    /// Show local STT daemon status
    Status,
    /// Show unified sensory voice/vision pipeline status
    PipelineStatus,
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
    /// Speak text with local TTS (Piper)
    Speak {
        text: String,
        #[arg(long)]
        language: Option<String>,
        #[arg(long)]
        voice_model: Option<String>,
        #[arg(long)]
        no_playback: bool,
    },
    /// Run full voice loop (prompt or audio -> LLM -> TTS)
    Session {
        #[arg(long)]
        prompt: Option<String>,
        #[arg(long)]
        audio_file: Option<String>,
        #[arg(long)]
        include_screen: bool,
        #[arg(long)]
        screen_source: Option<String>,
        #[arg(long)]
        language: Option<String>,
        #[arg(long)]
        voice_model: Option<String>,
        #[arg(long)]
        no_playback: bool,
    },
    /// Ask Axi to describe the current screen
    DescribeScreen {
        #[arg(long)]
        source: Option<String>,
        #[arg(long)]
        question: Option<String>,
        #[arg(long)]
        language: Option<String>,
        #[arg(long)]
        voice_model: Option<String>,
        #[arg(long)]
        no_speak: bool,
    },
    /// Interrupt current TTS playback / voice session
    Interrupt,
    /// Show presence detection status
    Presence {
        #[arg(long)]
        refresh: bool,
    },
}

pub async fn execute(cmd: VoiceCommands) -> anyhow::Result<()> {
    match cmd {
        VoiceCommands::Status => cmd_status().await,
        VoiceCommands::PipelineStatus => cmd_pipeline_status().await,
        VoiceCommands::Start { enable } => cmd_start(enable).await,
        VoiceCommands::Stop => cmd_stop().await,
        VoiceCommands::Transcribe { file, model } => cmd_transcribe(&file, model.as_deref()).await,
        VoiceCommands::Speak {
            text,
            language,
            voice_model,
            no_playback,
        } => {
            cmd_speak(
                &text,
                language.as_deref(),
                voice_model.as_deref(),
                !no_playback,
            )
            .await
        }
        VoiceCommands::Session {
            prompt,
            audio_file,
            include_screen,
            screen_source,
            language,
            voice_model,
            no_playback,
        } => {
            cmd_session(
                prompt.as_deref(),
                audio_file.as_deref(),
                include_screen,
                screen_source.as_deref(),
                language.as_deref(),
                voice_model.as_deref(),
                !no_playback,
            )
            .await
        }
        VoiceCommands::DescribeScreen {
            source,
            question,
            language,
            voice_model,
            no_speak,
        } => {
            cmd_describe_screen(
                source.as_deref(),
                question.as_deref(),
                language.as_deref(),
                voice_model.as_deref(),
                !no_speak,
            )
            .await
        }
        VoiceCommands::Interrupt => cmd_interrupt().await,
        VoiceCommands::Presence { refresh } => cmd_presence(refresh).await,
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

async fn cmd_pipeline_status() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!(
            "{}/api/v1/sensory/status",
            daemon_client::daemon_url()
        ))
        .send()
        .await?;
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to get sensory status: {}", body);
    }
    let body: serde_json::Value = resp.json().await?;
    println!("{}", "Sensory pipeline".bold().blue());
    println!(
        "  axi_state: {}",
        body["axi_state"].as_str().unwrap_or("unknown").cyan()
    );
    println!(
        "  kill_switch_active: {}",
        body["kill_switch_active"].as_bool().unwrap_or(false)
    );
    println!(
        "  leds mic/cam/screen: {}/{}/{}",
        body["leds"]["mic_active"].as_bool().unwrap_or(false),
        body["leds"]["camera_active"].as_bool().unwrap_or(false),
        body["leds"]["screen_active"].as_bool().unwrap_or(false)
    );
    println!(
        "  gpu tier: {} ({})",
        body["gpu"]["profile_tier"]
            .as_str()
            .unwrap_or("cpu_only")
            .cyan(),
        body["gpu"]["backend"].as_str().unwrap_or("cpu").dimmed()
    );
    println!(
        "  llm/vision offload: {}/{}",
        body["gpu"]["llm_offload"].as_str().unwrap_or("cpu only"),
        body["gpu"]["vision_offload"].as_str().unwrap_or("cpu only")
    );
    println!(
        "  last voice latency: {} ms",
        body["voice"]["last_latency_ms"]
            .as_u64()
            .unwrap_or_default()
    );
    println!(
        "  last tokens/s: {:.1}",
        body["voice"]["last_tokens_per_second"]
            .as_f64()
            .unwrap_or_default()
    );
    println!(
        "  always_on/wake_word: {}/{}",
        body["voice"]["always_on_active"].as_bool().unwrap_or(false),
        body["voice"]["wake_word"].as_str().unwrap_or("axi")
    );
    println!(
        "  capture interval: {} s",
        body["vision"]["capture_interval_seconds"]
            .as_u64()
            .unwrap_or(10)
    );
    println!(
        "  degraded: {}",
        body["degraded_modes"]
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| "none".to_string())
            .dimmed()
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

async fn cmd_speak(
    text: &str,
    language: Option<&str>,
    voice_model: Option<&str>,
    playback: bool,
) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!(
            "{}/api/v1/sensory/tts/speak",
            daemon_client::daemon_url()
        ))
        .json(&serde_json::json!({
            "text": text,
            "language": language,
            "voice_model": voice_model,
            "playback": playback,
        }))
        .send()
        .await?;
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to synthesize TTS: {}", body);
    }
    let body: serde_json::Value = resp.json().await?;
    println!("{}", "TTS preview".bold().blue());
    println!(
        "  text: {}",
        body["tts"]["text"].as_str().unwrap_or("").trim()
    );
    println!(
        "  audio_path: {}",
        body["tts"]["audio_path"].as_str().unwrap_or("-").dimmed()
    );
    println!(
        "  engine/backend: {}/{}",
        body["tts"]["tts_engine"].as_str().unwrap_or("-"),
        body["tts"]["playback_backend"].as_str().unwrap_or("-")
    );
    Ok(())
}

async fn cmd_session(
    prompt: Option<&str>,
    audio_file: Option<&str>,
    include_screen: bool,
    screen_source: Option<&str>,
    language: Option<&str>,
    voice_model: Option<&str>,
    playback: bool,
) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!(
            "{}/api/v1/sensory/voice/session",
            daemon_client::daemon_url()
        ))
        .json(&serde_json::json!({
            "prompt": prompt,
            "audio_file": audio_file,
            "include_screen": include_screen,
            "screen_source": screen_source,
            "language": language,
            "voice_model": voice_model,
            "playback": playback,
        }))
        .send()
        .await?;
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to run voice loop: {}", body);
    }
    let body: serde_json::Value = resp.json().await?;
    let loop_body = &body["voice_loop"];
    println!("{}", "Voice loop".bold().blue());
    println!(
        "  transcript: {}",
        loop_body["transcript"].as_str().unwrap_or("").trim()
    );
    println!(
        "  response: {}",
        loop_body["response"].as_str().unwrap_or("").trim()
    );
    println!(
        "  latency: {} ms",
        loop_body["latency_ms"].as_u64().unwrap_or_default()
    );
    println!(
        "  playback: {}/{}",
        loop_body["tts_engine"].as_str().unwrap_or("-"),
        loop_body["playback_backend"].as_str().unwrap_or("-")
    );
    println!(
        "  screen_path: {}",
        loop_body["screen_path"].as_str().unwrap_or("-").dimmed()
    );
    Ok(())
}

async fn cmd_describe_screen(
    source: Option<&str>,
    question: Option<&str>,
    language: Option<&str>,
    voice_model: Option<&str>,
    speak: bool,
) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!(
            "{}/api/v1/sensory/vision/describe",
            daemon_client::daemon_url()
        ))
        .json(&serde_json::json!({
            "source": source,
            "capture_screen": source.is_none(),
            "speak": speak,
            "question": question,
            "language": language,
            "voice_model": voice_model,
        }))
        .send()
        .await?;
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to describe screen: {}", body);
    }
    let body: serde_json::Value = resp.json().await?;
    let vision = &body["vision"];
    println!("{}", "Screen description".bold().blue());
    println!(
        "  response: {}",
        vision["response"].as_str().unwrap_or("").trim()
    );
    println!(
        "  screen_path: {}",
        vision["screen_path"].as_str().unwrap_or("-").dimmed()
    );
    println!(
        "  latency: {} ms",
        vision["latency_ms"].as_u64().unwrap_or_default()
    );
    Ok(())
}

async fn cmd_interrupt() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!(
            "{}/api/v1/sensory/voice/interrupt",
            daemon_client::daemon_url()
        ))
        .send()
        .await?;
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to interrupt voice session: {}", body);
    }
    let body: serde_json::Value = resp.json().await?;
    println!("{}", "Voice interrupt".bold().yellow());
    println!(
        "  interrupted: {}",
        body["interrupted"].as_bool().unwrap_or(false)
    );
    Ok(())
}

async fn cmd_presence(refresh: bool) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let req = if refresh {
        client.post(format!(
            "{}/api/v1/sensory/presence",
            daemon_client::daemon_url()
        ))
    } else {
        client.get(format!(
            "{}/api/v1/sensory/presence",
            daemon_client::daemon_url()
        ))
    };
    let resp = req.send().await?;
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to get presence status: {}", body);
    }
    let body: serde_json::Value = resp.json().await?;
    let presence = if refresh { &body["presence"] } else { &body };
    println!("{}", "Presence status".bold().blue());
    println!(
        "  present/source: {}/{}",
        presence["present"].as_bool().unwrap_or(false),
        presence["source"].as_str().unwrap_or("unknown")
    );
    println!(
        "  fatigue/posture: {}/{}",
        presence["fatigue_alert"].as_bool().unwrap_or(false),
        presence["posture_alert"].as_bool().unwrap_or(false)
    );
    println!(
        "  away_seconds: {}",
        presence["away_seconds"].as_u64().unwrap_or_default()
    );
    Ok(())
}
