use clap::Subcommand;
use colored::Colorize;
use tokio::process::Command;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum VoiceCommands {
    /// Show local STT daemon status
    Status,
    /// Show unified sensory voice/vision pipeline status
    PipelineStatus,
    /// Show the current system audio devices Axi will use for playback/capture
    DeviceStatus,
    /// Show a combined voice/audio diagnostic report
    Doctor,
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
    /// Speak text with local TTS (Kokoro)
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
    /// List all known speaker profiles (including anonymous ones auto-created from meetings)
    Speakers,
    /// Attach a real name to an anonymous speaker profile so future
    /// diarizations surface it in the transcript and participants list.
    /// Use `life voice speakers` to see the profile IDs.
    NameSpeaker {
        /// Speaker profile id (e.g. `speaker_234bc0c2f5f34b...`)
        id: String,
        /// Human-readable name to associate with this profile
        name: String,
    },
    /// Delete a speaker profile — use when a profile was mis-merged or you
    /// want Axi to re-learn the voice from scratch.
    DeleteSpeaker {
        /// Speaker profile id
        id: String,
    },
}

pub async fn execute(cmd: VoiceCommands) -> anyhow::Result<()> {
    match cmd {
        VoiceCommands::Status => cmd_status().await,
        VoiceCommands::PipelineStatus => cmd_pipeline_status().await,
        VoiceCommands::DeviceStatus => cmd_device_status().await,
        VoiceCommands::Doctor => cmd_doctor().await,
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
        VoiceCommands::Speakers => cmd_speakers_list().await,
        VoiceCommands::NameSpeaker { id, name } => cmd_speakers_name(&id, &name).await,
        VoiceCommands::DeleteSpeaker { id } => cmd_speakers_delete(&id).await,
    }
}

async fn cmd_status() -> anyhow::Result<()> {
    let body: serde_json::Value = daemon_client::get_json("/api/v1/audio/stt/status").await?;
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
    let body: serde_json::Value = daemon_client::get_json("/api/v1/sensory/status").await?;
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

async fn cmd_device_status() -> anyhow::Result<()> {
    let info = run_pactl(&["info"]).await?;
    let sinks = run_pactl(&["list", "short", "sinks"]).await?;
    let sources = run_pactl(&["list", "short", "sources"]).await?;

    let default_sink = parse_default_route(&info, &["Default Sink:", "Destino por defecto:"])
        .unwrap_or_else(|| "unknown".to_string());
    let default_source = parse_default_route(&info, &["Default Source:", "Fuente por defecto:"])
        .unwrap_or_else(|| "unknown".to_string());

    println!("{}", "Voice device status".bold().blue());
    println!("  axi playback: {}", default_sink.cyan());
    println!("  axi capture: {}", default_source.cyan());
    println!(
        "  tts/stt routing: {}/{}",
        "system default sink".dimmed(),
        "system default source".dimmed()
    );

    if let Some(line) = find_route_line(&sinks, &default_sink) {
        println!("  active sink: {}", summarize_pactl_route(&line));
    }
    if let Some(line) = find_route_line(&sources, &default_source) {
        println!("  active source: {}", summarize_pactl_route(&line));
    }

    let available_sinks = summarize_short_routes(&sinks, false);
    let available_sources = summarize_short_routes(&sources, true);

    println!(
        "  available sinks: {}",
        if available_sinks.is_empty() {
            "none".dimmed().to_string()
        } else {
            available_sinks.join(", ")
        }
    );
    println!(
        "  available sources: {}",
        if available_sources.is_empty() {
            "none".dimmed().to_string()
        } else {
            available_sources.join(", ")
        }
    );

    Ok(())
}

async fn cmd_doctor() -> anyhow::Result<()> {
    let pipeline = fetch_pipeline_status().await?;
    let info = run_pactl(&["info"]).await?;
    let sinks = run_pactl(&["list", "short", "sinks"]).await?;
    let sources = run_pactl(&["list", "short", "sources"]).await?;

    let default_sink = parse_default_route(&info, &["Default Sink:", "Destino por defecto:"])
        .unwrap_or_else(|| "unknown".to_string());
    let default_source = parse_default_route(&info, &["Default Source:", "Fuente por defecto:"])
        .unwrap_or_else(|| "unknown".to_string());

    let sink_line = find_route_line(&sinks, &default_sink);
    let source_line = find_route_line(&sources, &default_source);
    let sink_ok = sink_line.is_some();
    let source_ok = source_line.is_some();

    println!("{}", "Voice doctor".bold().blue());
    println!(
        "  pipeline: {}",
        pipeline["axi_state"].as_str().unwrap_or("unknown").cyan()
    );
    println!(
        "  always_on/wake_word: {}/{}",
        pipeline["voice"]["always_on_active"]
            .as_bool()
            .unwrap_or(false),
        pipeline["voice"]["wake_word"].as_str().unwrap_or("axi")
    );
    println!(
        "  sensory leds mic/cam/screen: {}/{}/{}",
        pipeline["leds"]["mic_active"].as_bool().unwrap_or(false),
        pipeline["leds"]["camera_active"].as_bool().unwrap_or(false),
        pipeline["leds"]["screen_active"].as_bool().unwrap_or(false)
    );
    println!("  axi playback: {}", default_sink.cyan());
    println!("  axi capture: {}", default_source.cyan());
    println!(
        "  routing health: sink={} source={}",
        if sink_ok {
            "ok".green()
        } else {
            "missing".red()
        },
        if source_ok {
            "ok".green()
        } else {
            "missing".red()
        }
    );

    if let Some(line) = sink_line {
        println!("  active sink: {}", summarize_pactl_route(&line));
    }
    if let Some(line) = source_line {
        println!("  active source: {}", summarize_pactl_route(&line));
    }

    let bt_sink_count = summarize_short_routes(&sinks, false)
        .iter()
        .filter(|item| item.starts_with("bluez_output."))
        .count();
    let bt_source_count = summarize_short_routes(&sources, true)
        .iter()
        .filter(|item| item.starts_with("bluez_input."))
        .count();

    println!(
        "  bluetooth io: sinks={} sources={}",
        bt_sink_count.to_string().cyan(),
        bt_source_count.to_string().cyan()
    );
    println!(
        "  available sinks: {}",
        render_available_routes(&sinks, false)
    );
    println!(
        "  available sources: {}",
        render_available_routes(&sources, true)
    );

    if !sink_ok || !source_ok {
        println!(
            "  recommendation: {}",
            "rerun your desired pactl defaults, then restart sensory".yellow()
        );
    } else {
        println!(
            "  recommendation: {}",
            "Axi should respect the current system defaults shown above".green()
        );
    }

    Ok(())
}

async fn fetch_pipeline_status() -> anyhow::Result<serde_json::Value> {
    daemon_client::get_json("/api/v1/sensory/status").await
}

async fn run_pactl(args: &[&str]) -> anyhow::Result<String> {
    let output = Command::new("pactl").args(args).output().await?;
    if !output.status.success() {
        anyhow::bail!(
            "pactl {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

fn parse_default_route(info: &str, prefixes: &[&str]) -> Option<String> {
    info.lines().find_map(|line| {
        prefixes.iter().find_map(|prefix| {
            line.strip_prefix(prefix)
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
        })
    })
}

fn find_route_line(routes: &str, route_name: &str) -> Option<String> {
    routes.lines().find_map(|line| {
        let columns: Vec<&str> = line.split_whitespace().collect();
        if columns.len() >= 2 && columns[1] == route_name {
            Some(line.to_string())
        } else {
            None
        }
    })
}

fn summarize_pactl_route(line: &str) -> String {
    let columns: Vec<&str> = line.split_whitespace().collect();
    if columns.len() >= 5 {
        format!(
            "{} {} {}",
            columns[1].cyan(),
            format!("[{}]", columns[3]).dimmed(),
            columns[4..].join(" ")
        )
    } else {
        line.to_string()
    }
}

fn summarize_short_routes(routes: &str, is_source: bool) -> Vec<String> {
    routes
        .lines()
        .filter_map(|line| {
            let columns: Vec<&str> = line.split_whitespace().collect();
            if columns.len() < 2 {
                return None;
            }
            if is_source && columns[1].ends_with(".monitor") {
                return None;
            }
            Some(columns[1].to_string())
        })
        .collect()
}

fn render_available_routes(routes: &str, is_source: bool) -> String {
    let items = summarize_short_routes(routes, is_source);
    if items.is_empty() {
        "none".dimmed().to_string()
    } else {
        items.join(", ")
    }
}

async fn cmd_start(enable: bool) -> anyhow::Result<()> {
    let body: serde_json::Value = daemon_client::post_json(
        "/api/v1/audio/stt/start",
        &serde_json::json!({ "enable": enable }),
    )
    .await?;
    let _ = body;
    println!("{}", "STT daemon start requested".green().bold());
    println!("  enable_on_boot: {}", enable);
    Ok(())
}

async fn cmd_stop() -> anyhow::Result<()> {
    daemon_client::post_empty::<serde_json::Value>("/api/v1/audio/stt/stop").await?;
    println!("{}", "STT daemon stop requested".green().bold());
    Ok(())
}

async fn cmd_transcribe(file: &str, model: Option<&str>) -> anyhow::Result<()> {
    let body: serde_json::Value = daemon_client::post_json(
        "/api/v1/audio/stt/transcribe",
        &serde_json::json!({
            "file": file,
            "model": model,
        }),
    )
    .await?;
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
    let body: serde_json::Value = daemon_client::post_json(
        "/api/v1/sensory/tts/speak",
        &serde_json::json!({
            "text": text,
            "language": language,
            "voice_model": voice_model,
            "playback": playback,
        }),
    )
    .await?;
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
    let body: serde_json::Value = daemon_client::post_json(
        "/api/v1/sensory/voice/session",
        &serde_json::json!({
            "prompt": prompt,
            "audio_file": audio_file,
            "include_screen": include_screen,
            "screen_source": screen_source,
            "language": language,
            "voice_model": voice_model,
            "playback": playback,
        }),
    )
    .await?;
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
    let body: serde_json::Value = daemon_client::post_json(
        "/api/v1/sensory/vision/describe",
        &serde_json::json!({
            "source": source,
            "capture_screen": source.is_none(),
            "speak": speak,
            "question": question,
            "language": language,
            "voice_model": voice_model,
        }),
    )
    .await?;
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
    let body: serde_json::Value =
        daemon_client::post_empty("/api/v1/sensory/voice/interrupt").await?;
    println!("{}", "Voice interrupt".bold().yellow());
    println!(
        "  interrupted: {}",
        body["interrupted"].as_bool().unwrap_or(false)
    );
    Ok(())
}

async fn cmd_presence(refresh: bool) -> anyhow::Result<()> {
    let body: serde_json::Value = if refresh {
        daemon_client::post_empty("/api/v1/sensory/presence").await?
    } else {
        daemon_client::get_json("/api/v1/sensory/presence").await?
    };
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

async fn cmd_speakers_list() -> anyhow::Result<()> {
    let body: serde_json::Value = daemon_client::get_json("/api/v1/speakers").await?;
    let count = body["count"].as_u64().unwrap_or(0);
    println!("{} ({} perfiles)", "Speaker profiles".bold().blue(), count);
    let empty = vec![];
    let profiles = body["profiles"].as_array().unwrap_or(&empty);
    if profiles.is_empty() {
        println!("  (no profiles yet — Axi creates these automatically as it hears new voices)");
        return Ok(());
    }
    for p in profiles {
        let id = p["id"].as_str().unwrap_or("?");
        let name_cell = match p["name"].as_str() {
            Some(n) if !n.is_empty() => n.green().bold().to_string(),
            _ => "(sin nombre)".yellow().to_string(),
        };
        let emb = p["embedding_count"].as_u64().unwrap_or(0);
        let interactions = p["interaction_count"].as_u64().unwrap_or(0);
        let last = p["last_seen_at"].as_str().unwrap_or("");
        println!(
            "  {} {}\n    id: {}\n    embeddings: {}   interactions: {}   last_seen: {}",
            "•".cyan(),
            name_cell,
            id.dimmed(),
            emb,
            interactions,
            last.dimmed()
        );
    }
    println!();
    println!(
        "{}",
        "Use `life voice name-speaker <id> <nombre>` to name a profile.".dimmed()
    );
    Ok(())
}

async fn cmd_speakers_name(id: &str, name: &str) -> anyhow::Result<()> {
    daemon_client::post_json::<_, serde_json::Value>(
        &format!("/api/v1/speakers/{}/name", id),
        &serde_json::json!({ "name": name }),
    )
    .await?;
    println!("{} {} → {}", "✓".green(), id.dimmed(), name.green().bold());
    Ok(())
}

async fn cmd_speakers_delete(id: &str) -> anyhow::Result<()> {
    daemon_client::delete_json::<serde_json::Value>(&format!("/api/v1/speakers/{}", id)).await?;
    println!("{} deleted: {}", "✓".green(), id.dimmed());
    Ok(())
}
