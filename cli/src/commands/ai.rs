use clap::Subcommand;
use colored::Colorize;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::io::{self, Write};
use std::path::PathBuf;
use std::process::Command;

use crate::daemon_client;

/// Default llama-server host
const LLAMA_SERVER_HOST: &str = "http://localhost:8082";
/// Default model directory
const MODEL_DIR: &str = "/var/lib/lifeos/models";
/// Persisted tombstones for models explicitly removed by the user.
const REMOVED_MODELS_FILE: &str = "/var/lib/lifeos/models/.removed-models";
/// Shared llama-server env file
const LLAMA_ENV_FILE: &str = "/etc/lifeos/llama-server.env";
/// Default remote model catalog
const MODEL_CATALOG_URL: &str = "https://models.lifeos.dev/catalog/v1.json";
/// Default remote model catalog detached signature (sha256 digest string)
const MODEL_CATALOG_SIG_URL: &str = "https://models.lifeos.dev/catalog/v1.json.sig";
/// Embedded offline fallback catalog bundled in the repo/ISO
const EMBEDDED_MODEL_CATALOG: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/assets/models/v1/catalog.json"
));
/// Embedded detached signature for the fallback catalog
const EMBEDDED_MODEL_CATALOG_SIG: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/assets/models/v1/catalog.json.sig"
));

#[derive(Subcommand)]
pub enum AiCommands {
    /// Start llama-server AI service
    Start {
        /// Start with specific model loaded
        #[arg(short, long)]
        model: Option<String>,
        /// Enable auto-start on boot
        #[arg(short, long)]
        enable: bool,
    },
    /// Stop llama-server AI service
    Stop,
    /// Ask the AI assistant a single question
    Ask { prompt: String },
    /// Execute action in natural language
    Do { action: String },
    /// List available and installed models
    Models {
        /// Show download URLs for available models
        #[arg(short, long)]
        all: bool,
    },
    /// Download a GGUF model from HuggingFace
    Pull {
        /// Model name or HuggingFace URL
        model: String,
        /// Force re-download even if model exists
        #[arg(short, long)]
        force: bool,
    },
    /// Select installed model as the default for llama-server and life ai
    Select {
        /// Installed GGUF filename
        model: String,
        /// Restart llama-server after applying the selection
        #[arg(long)]
        restart: bool,
    },
    /// Remove a model to free disk space
    Remove {
        model: String,
        /// Skip confirmation
        #[arg(short, long)]
        yes: bool,
    },
    /// Interactive chat with AI
    Chat {
        /// Model GGUF file to use (default: configured model)
        #[arg(short, long)]
        model: Option<String>,
    },
    /// Check AI service status and system info
    Status {
        /// Show detailed information
        #[arg(short, long)]
        verbose: bool,
    },
    /// Benchmark local models (latency + success rate)
    Benchmark {
        /// Optional model to benchmark (default: all installed models)
        #[arg(short, long)]
        model: Option<String>,
        /// Run a shorter benchmark profile
        #[arg(long)]
        short: bool,
        /// Repetitions per model
        #[arg(long, default_value = "2")]
        repeats: u32,
    },
    /// Run sensory benchmark suite (voice loop, vision query, GPU throughput)
    BenchSensory {
        #[arg(long)]
        audio_file: Option<String>,
        #[arg(long)]
        prompt: Option<String>,
        #[arg(long)]
        include_screen: bool,
        #[arg(long)]
        screen_source: Option<String>,
        #[arg(long, default_value = "3")]
        repeats: u32,
    },
    /// Auto-select best local model from latest benchmark
    Autotune {
        /// Only show recommendation, do not apply
        #[arg(long)]
        dry_run: bool,
    },
    /// Detect and persist hardware runtime profile (lite/edge/secure/pro)
    Profile {
        /// Optional explicit profile override (lite|edge|secure|pro)
        #[arg(long)]
        runtime: Option<String>,
        /// Persist the detected/selected profile to model-profile.toml
        #[arg(long)]
        apply: bool,
    },
    /// Show model catalog source and signature verification status
    Catalog {
        /// Try remote refresh before fallback
        #[arg(long)]
        refresh: bool,
    },
    /// Run OS-level OCR on a file or current screen capture
    Ocr {
        /// Existing image path to OCR
        #[arg(long)]
        source: Option<String>,
        /// Force capture screen before OCR
        #[arg(long)]
        capture_screen: bool,
        /// OCR language (default: eng)
        #[arg(long)]
        language: Option<String>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RuntimeExecutionMode {
    Interactive,
    RunUntilDone,
    SilentUntilDone,
}

impl RuntimeExecutionMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Interactive => "interactive",
            Self::RunUntilDone => "run-until-done",
            Self::SilentUntilDone => "silent-until-done",
        }
    }

    fn from_str(value: &str) -> Self {
        match value {
            "run-until-done" => Self::RunUntilDone,
            "silent-until-done" => Self::SilentUntilDone,
            _ => Self::Interactive,
        }
    }
}

#[derive(Debug, Clone)]
struct ModelArtifactDownload {
    url: String,
    filename: String,
}

#[derive(Debug, Clone)]
struct ModelDownload {
    url: String,
    filename: String,
    companion_mmproj: Option<ModelArtifactDownload>,
}

pub async fn execute(args: AiCommands) -> anyhow::Result<()> {
    match args {
        AiCommands::Start { model, enable } => start_ai(model, enable).await,
        AiCommands::Stop => stop_ai().await,
        AiCommands::Ask { prompt } => ask_ai(&prompt).await,
        AiCommands::Do { action } => do_action(&action).await,
        AiCommands::Models { all } => list_models(all).await,
        AiCommands::Pull { model, force } => pull_model(&model, force).await,
        AiCommands::Select { model, restart } => select_model(&model, restart).await,
        AiCommands::Remove { model, yes } => remove_model(&model, yes).await,
        AiCommands::Chat { model } => interactive_chat(model.as_deref()).await,
        AiCommands::Status { verbose } => check_status(verbose).await,
        AiCommands::Benchmark {
            model,
            short,
            repeats,
        } => benchmark_models(model.as_deref(), short, repeats).await,
        AiCommands::BenchSensory {
            audio_file,
            prompt,
            include_screen,
            screen_source,
            repeats,
        } => {
            benchmark_sensory(
                audio_file.as_deref(),
                prompt.as_deref(),
                include_screen,
                screen_source.as_deref(),
                repeats,
            )
            .await
        }
        AiCommands::Autotune { dry_run } => autotune_model(dry_run).await,
        AiCommands::Profile { runtime, apply } => detect_profile(runtime.as_deref(), apply).await,
        AiCommands::Catalog { refresh } => show_catalog_status(refresh).await,
        AiCommands::Ocr {
            source,
            capture_screen,
            language,
        } => ocr_screen(source.as_deref(), capture_screen, language.as_deref()).await,
    }
}

// ==================== COMMAND IMPLEMENTATIONS ====================

async fn start_ai(model: Option<String>, enable: bool) -> anyhow::Result<()> {
    println!("{}", "Starting AI services...".bold().blue());
    println!();

    // Step 1: Check if llama-server is installed
    print!("Checking llama-server installation... ");
    let installed = Command::new("which")
        .arg("llama-server")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if !installed {
        println!("{}", "not found".red());
        anyhow::bail!("llama-server is not installed. It should be bundled with LifeOS.");
    }
    println!("{}", "OK".green());

    // Step 2: Check GPU availability
    print!("Checking GPU availability... ");
    let gpu_info = check_gpu();
    match &gpu_info {
        GpuInfo::Nvidia { name, vram } => {
            println!("{}", "OK".green());
            println!("  {} {} ({} MB VRAM)", "->".dimmed(), name, vram);
        }
        GpuInfo::Amd { name } => {
            println!("{}", "OK".green());
            println!("  {} {}", "->".dimmed(), name);
        }
        GpuInfo::Intel { name } => {
            println!("{}", "OK".green());
            println!("  {} {}", "->".dimmed(), name);
        }
        GpuInfo::None => {
            println!("{}", "CPU only".yellow());
            println!("  {} No GPU detected - will use CPU mode", "->".dimmed());
        }
    }

    // Step 3: Check available models
    print!("Checking AI models... ");
    let models = list_gguf_models();
    if models.is_empty() {
        println!("{}", "none found".yellow());
        println!(
            "  {} Downloading default model on service start...",
            "->".dimmed()
        );
    } else {
        println!("{} ({} model(s))", "OK".green(), models.len());
        for m in &models {
            println!("  {} {}", "->".dimmed(), m);
        }
    }

    // Step 4: Update model in env if specified
    if let Some(ref model_name) = model {
        let model_path = format!("{}/{}", MODEL_DIR, model_name);
        if std::path::Path::new(&model_path).exists() {
            ensure_companion_artifacts(model_name, false)?;
            apply_model_selection(model_name)?;
            println!("  {} Model set to: {}", "->".dimmed(), model_name.cyan());
        } else {
            println!(
                "  {} Model {} not found in {}",
                "!".yellow(),
                model_name,
                MODEL_DIR
            );
        }
    }

    // Step 5: Start the service
    print!("Starting llama-server service... ");
    let running = is_server_running().await;

    if running && model.is_some() {
        match Command::new("sudo")
            .args(["systemctl", "restart", "llama-server"])
            .output()
        {
            Ok(output) if output.status.success() => println!("{}", "restarted".green()),
            _ => {
                println!("{}", "FAILED".red());
                anyhow::bail!("Could not restart llama-server with the selected model");
            }
        }
    } else if running {
        println!("{}", "already running".green());
    } else {
        match Command::new("sudo")
            .args(["systemctl", "start", "llama-server"])
            .output()
        {
            Ok(output) if output.status.success() => {
                // Wait for service to become ready
                tokio::time::sleep(tokio::time::Duration::from_secs(3)).await;
                println!("{}", "OK".green());
            }
            _ => {
                println!("{}", "FAILED".red());
                println!();
                println!(
                    "Check logs with: {}",
                    "journalctl -u llama-server -n 50".cyan()
                );
                anyhow::bail!("Could not start llama-server service");
            }
        }
    }

    // Enable auto-start if requested
    if enable {
        print!("Enabling auto-start on boot... ");
        match Command::new("sudo")
            .args(["systemctl", "enable", "llama-server.service"])
            .output()
        {
            Ok(output) if output.status.success() => println!("{}", "OK".green()),
            _ => println!("{}", "FAILED".yellow()),
        }
    }

    // Step 6: Verify connectivity
    print!("Verifying AI server connectivity... ");
    match check_server_health().await {
        Ok(_) => println!("{}", "OK".green()),
        Err(e) => {
            println!("{}", "FAILED".red());
            println!("  {} {}", "->".dimmed(), e);
        }
    }

    println!();
    println!("{}", "AI services ready".green().bold());
    println!();
    println!(
        "Try: {} or {}",
        "life ai chat".cyan(),
        "life ai ask 'hello'".cyan()
    );

    Ok(())
}

async fn stop_ai() -> anyhow::Result<()> {
    println!("{}", "Stopping AI services...".bold().blue());

    match Command::new("sudo")
        .args(["systemctl", "stop", "llama-server.service"])
        .output()
    {
        Ok(output) if output.status.success() => {
            println!("{}", "llama-server service stopped".green());
        }
        _ => {
            println!("{}", "Service may not be running".yellow());
        }
    }

    Ok(())
}

async fn ask_ai(prompt: &str) -> anyhow::Result<()> {
    // Ensure server is running
    if !is_server_running().await {
        println!("AI server is not running. Starting now...");
        start_ai(None, false).await?;
    }

    println!("{}", "Thinking...".dimmed());

    let client = reqwest::Client::new();
    let response = client
        .post(format!("{}/v1/chat/completions", LLAMA_SERVER_HOST))
        .json(&serde_json::json!({
            "messages": [
                {"role": "user", "content": prompt}
            ],
            "stream": false
        }))
        .send()
        .await?;

    if response.status().is_success() {
        let json: serde_json::Value = response.json().await?;
        if let Some(text) = json
            .get("choices")
            .and_then(|c| c.get(0))
            .and_then(|c| c.get("message"))
            .and_then(|m| m.get("content"))
            .and_then(|c| c.as_str())
        {
            println!("\n{}", text);
        }
    } else {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!("AI server error ({}): {}", status, body);
    }

    Ok(())
}

async fn do_action(action: &str) -> anyhow::Result<()> {
    println!(
        "{} {}",
        "Routing action through intents:".bold(),
        action.cyan()
    );

    let client = daemon_client::authenticated_client();
    let base_url = daemon_client::daemon_url();

    let plan_resp = client
        .post(format!("{}/api/v1/intents/plan", base_url))
        .json(&serde_json::json!({ "description": action }))
        .send()
        .await?;

    if !plan_resp.status().is_success() {
        let status = plan_resp.status();
        let body = plan_resp.text().await.unwrap_or_default();
        anyhow::bail!("Could not plan intent ({}): {}", status, body);
    }

    let plan_json: serde_json::Value = plan_resp.json().await?;
    let intent = &plan_json["intent"];
    let intent_id = intent["intent_id"].as_str().unwrap_or_default();
    let risk = intent["risk"].as_str().unwrap_or("unknown");

    if intent_id.is_empty() {
        anyhow::bail!("Daemon did not return intent_id");
    }

    println!("  {} {}", "Intent ID:".dimmed(), intent_id.cyan());
    println!("  {} {}", "Risk:".dimmed(), risk);

    let execution_mode = fetch_runtime_mode(&client, &base_url).await;
    println!(
        "  {} {}",
        "Execution mode:".dimmed(),
        execution_mode.as_str().cyan()
    );

    let mut approved = false;
    if matches!(risk, "high" | "critical") {
        if execution_mode == RuntimeExecutionMode::Interactive {
            println!(
                "\n{} {}",
                "This action requires explicit approval due to risk level:".yellow(),
                risk.yellow().bold()
            );
            print!("Approve execution? [y/N] ");
            io::stdout().flush()?;

            let mut input = String::new();
            io::stdin().read_line(&mut input)?;
            approved = input.trim().eq_ignore_ascii_case("y");
        } else {
            println!(
                "\n{} {}",
                "High-risk intent detected: local prompt skipped by execution mode."
                    .yellow()
                    .bold(),
                execution_mode.as_str().yellow()
            );
            println!(
                "  {}",
                "Daemon policy will enforce approval or auto-approval via trust mode.".dimmed()
            );
        }
    }

    let apply_resp = client
        .post(format!("{}/api/v1/intents/apply", base_url))
        .json(&serde_json::json!({
            "intent_id": intent_id,
            "approved": approved
        }))
        .send()
        .await?;

    if !apply_resp.status().is_success() {
        let status = apply_resp.status();
        let body = apply_resp.text().await.unwrap_or_default();
        anyhow::bail!("Could not apply intent ({}): {}", status, body);
    }

    let apply_json: serde_json::Value = apply_resp.json().await?;
    let status = apply_json["intent"]["status"]
        .as_str()
        .unwrap_or("unknown")
        .to_string();

    println!();
    println!("{}", "Intent pipeline result".bold().blue());
    println!("  {} {}", "Intent:".dimmed(), intent_id.cyan());
    println!("  {} {}", "Status:".dimmed(), status.cyan());
    if status == "awaiting_approval" {
        println!(
            "  {}",
            format!(
                "Run with explicit approval: life intents apply {} --approve",
                intent_id
            )
            .yellow()
        );
    }

    Ok(())
}

async fn fetch_runtime_mode(client: &reqwest::Client, base_url: &str) -> RuntimeExecutionMode {
    let response = client
        .get(format!("{}/api/v1/runtime/mode", base_url))
        .send()
        .await;

    let Ok(resp) = response else {
        return RuntimeExecutionMode::Interactive;
    };
    if !resp.status().is_success() {
        return RuntimeExecutionMode::Interactive;
    }

    let Ok(body) = resp.json::<serde_json::Value>().await else {
        return RuntimeExecutionMode::Interactive;
    };
    let mode = body["mode"].as_str().unwrap_or("interactive");
    RuntimeExecutionMode::from_str(mode)
}

async fn list_models(all: bool) -> anyhow::Result<()> {
    println!("{}", "AI Models".bold().blue());
    println!();
    let active_model = configured_model();

    // List installed GGUF models
    let models = list_gguf_models();
    if models.is_empty() {
        println!("{}", "  No models installed".dimmed());
        println!();
        println!("Download a model with:");
        println!("  {}", "life ai pull qwen3.5-4b".cyan());
    } else {
        println!("{}", "Installed Models:".bold());
        println!("{:<40} {:>10} {:>10}", "Name", "Size", "State");
        println!("{}", "-".repeat(64).dimmed());

        for model in &models {
            let path = format!("{}/{}", MODEL_DIR, model);
            let size = std::fs::metadata(&path)
                .map(|m| format_size(m.len()))
                .unwrap_or_else(|_| "?".to_string());
            let state = if active_model.as_deref() == Some(model.as_str()) {
                "default".green().to_string()
            } else {
                "-".dimmed().to_string()
            };
            println!("{:<40} {:>10} {:>10}", model.cyan(), size.dimmed(), state);
        }
    }

    if all {
        println!();
        println!("{}", "Available to Download:".bold());
        let loaded_catalog = load_model_catalog(false).await?;
        for model in &loaded_catalog.catalog.models {
            println!(
                "  {:<45} {:>8}  roles: {}",
                model.id.cyan(),
                format_size(model.size_bytes).dimmed(),
                if model.roles.is_empty() {
                    "general".to_string()
                } else {
                    model.roles.join(",")
                }
            );
        }
        println!();
        println!(
            "Catalog source: {} ({})",
            loaded_catalog.source.cyan(),
            if loaded_catalog.signature_valid {
                "signature valid".green().to_string()
            } else {
                "signature invalid".red().to_string()
            }
        );
        println!("Or download any GGUF model directly:");
        println!(
            "  {}",
            "life ai pull https://huggingface.co/.../model.gguf".cyan()
        );
    }

    println!();
    println!("Pull a model: {}", "life ai pull <model>".cyan());
    println!("Set default:   {}", "life ai select <model>".cyan());

    Ok(())
}

async fn pull_model(model: &str, force: bool) -> anyhow::Result<()> {
    println!("{}", format!("Pulling model: {}", model).bold().blue());

    // Determine the URL and filename
    let download = resolve_model_download(model);

    let dest_path = format!("{}/{}", MODEL_DIR, download.filename);
    let companion = download.companion_mmproj.clone();

    // Check if model already exists
    let model_exists = std::path::Path::new(&dest_path).exists();
    let companion_exists = companion
        .as_ref()
        .map(|artifact| {
            std::path::Path::new(&format!("{}/{}", MODEL_DIR, artifact.filename)).exists()
        })
        .unwrap_or(true);
    if !force && model_exists && companion_exists {
        println!("Model {} already installed", download.filename);
        println!("Use {} to re-download", "--force".cyan());
        return Ok(());
    }

    println!("Downloading from: {}", download.url.dimmed());
    println!("This may take several minutes depending on your connection...");
    println!();

    if force || !model_exists {
        download_file_as_root(&download.url, &dest_path)?;
    }

    if let Some(artifact) = companion {
        let companion_path = format!("{}/{}", MODEL_DIR, artifact.filename);
        if force || !std::path::Path::new(&companion_path).exists() {
            println!(
                "Downloading companion vision projector: {}",
                artifact.filename.cyan()
            );
            download_file_as_root(&artifact.url, &companion_path)?;
        }
    }

    clear_removed_model(&download.filename)?;

    if std::path::Path::new(&dest_path).exists() {
        println!();
        println!(
            "{}",
            format!("Model {} downloaded successfully", download.filename).green()
        );

        // Show file size
        if let Ok(meta) = std::fs::metadata(&dest_path) {
            println!("  Size: {}", format_size(meta.len()));
        }
        println!(
            "  Set as default with: {}",
            format!("life ai select {}", download.filename).cyan()
        );
        return Ok(());
    }

    anyhow::bail!("Failed to download model");
}

async fn select_model(model: &str, restart: bool) -> anyhow::Result<()> {
    let model_path = format!("{}/{}", MODEL_DIR, model);
    if !std::path::Path::new(&model_path).exists() {
        anyhow::bail!("Model {} not found in {}", model, MODEL_DIR);
    }

    ensure_companion_artifacts(model, false)?;
    apply_model_selection(model)?;
    println!(
        "{} {}",
        "Default model updated:".green().bold(),
        model.cyan()
    );

    if restart {
        let output = Command::new("sudo")
            .args(["systemctl", "restart", "llama-server"])
            .output()?;
        if output.status.success() {
            println!("{}", "llama-server restarted".green());
        } else {
            println!("{}", "llama-server restart failed".yellow());
        }
    } else {
        println!(
            "Restart service with: {}",
            "sudo systemctl restart llama-server".cyan()
        );
    }

    Ok(())
}

async fn remove_model(model: &str, yes: bool) -> anyhow::Result<()> {
    let model_path = format!("{}/{}", MODEL_DIR, model);
    let was_default = configured_model().as_deref() == Some(model);

    if !std::path::Path::new(&model_path).exists() {
        anyhow::bail!("Model {} not found in {}", model, MODEL_DIR);
    }

    // Show size
    let size = std::fs::metadata(&model_path)
        .map(|m| format_size(m.len()))
        .unwrap_or_else(|_| "?".to_string());

    println!(
        "{}",
        format!("Removing model: {} ({})", model, size)
            .bold()
            .yellow()
    );

    if !yes {
        print!("\nAre you sure? This will free disk space. [y/N] ");
        io::stdout().flush()?;

        let mut input = String::new();
        io::stdin().read_line(&mut input)?;

        if !input.trim().eq_ignore_ascii_case("y") {
            println!("Cancelled.");
            return Ok(());
        }
    }

    match Command::new("sudo")
        .args(["rm", "-f", &model_path])
        .output()
    {
        Ok(output) if output.status.success() => {
            println!("{}", format!("Model {} removed", model).green());
            if let Some(companion_name) = qwen_companion_mmproj_filename(model) {
                let companion_path = format!("{}/{}", MODEL_DIR, companion_name);
                if std::path::Path::new(&companion_path).exists() {
                    let _ = Command::new("sudo")
                        .args(["rm", "-f", &companion_path])
                        .output();
                    println!(
                        "{}",
                        format!("Companion asset {} removed", companion_name).green()
                    );
                }
            }

            mark_model_removed(model)?;

            if was_default {
                let _ = Command::new("sudo")
                    .args(["systemctl", "stop", "llama-server"])
                    .output();

                if let Some(fallback) = list_gguf_models()
                    .into_iter()
                    .find(|candidate| candidate != model)
                {
                    apply_model_selection(&fallback)?;
                    println!(
                        "{} {}",
                        "Fallback default selected:".green().bold(),
                        fallback.cyan()
                    );
                    println!(
                        "Restart service with: {}",
                        "sudo systemctl start llama-server".cyan()
                    );
                } else {
                    println!(
                        "{}",
                        "No heavy model remains installed. llama-server will stay unavailable until you pull/select another model."
                            .yellow()
                    );
                }
            } else {
                println!(
                    "{}",
                    "Removal persisted. LifeOS will not auto-reinstall this heavy model unless you pull/select it again."
                        .yellow()
                );
            }
        }
        _ => {
            anyhow::bail!("Failed to remove model file");
        }
    }

    Ok(())
}

async fn interactive_chat(model: Option<&str>) -> anyhow::Result<()> {
    // Ensure server is running
    if !is_server_running().await {
        println!("AI server is not running. Starting now...");
        start_ai(None, false).await?;
    }

    let model_display = model.unwrap_or("default");

    println!("{}", "-".repeat(60).dimmed());
    println!(
        "{}  {}  Type 'exit' or 'quit' to end",
        "Chat".bold(),
        format!("Model: {}", model_display).bold().cyan()
    );
    println!("{}", "-".repeat(60).dimmed());

    let client = reqwest::Client::new();
    let mut messages: Vec<serde_json::Value> = vec![];

    loop {
        print!("\n{} ", "You:".bold().green());
        io::stdout().flush()?;

        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        let input = input.trim();

        if input.eq_ignore_ascii_case("exit") || input.eq_ignore_ascii_case("quit") {
            println!("\nGoodbye!");
            break;
        }

        if input.is_empty() {
            continue;
        }

        messages.push(serde_json::json!({"role": "user", "content": input}));

        // Keep only last 20 messages for context
        if messages.len() > 20 {
            messages.drain(0..messages.len() - 20);
        }

        print!("\n{} ", "AI:".bold().cyan());
        io::stdout().flush()?;

        // Stream response
        let response = client
            .post(format!("{}/v1/chat/completions", LLAMA_SERVER_HOST))
            .json(&serde_json::json!({
                "messages": messages,
                "stream": true
            }))
            .send()
            .await?;

        if response.status().is_success() {
            let mut full_response = String::new();
            let mut stream = response.bytes_stream();

            while let Some(chunk) = stream.next().await {
                if let Ok(bytes) = chunk {
                    let text = String::from_utf8_lossy(&bytes);
                    for line in text.lines() {
                        let line = line.strip_prefix("data: ").unwrap_or(line);
                        if line == "[DONE]" {
                            break;
                        }
                        if let Ok(json) = serde_json::from_str::<serde_json::Value>(line) {
                            if let Some(content) = json
                                .get("choices")
                                .and_then(|c| c.get(0))
                                .and_then(|c| c.get("delta"))
                                .and_then(|d| d.get("content"))
                                .and_then(|c| c.as_str())
                            {
                                print!("{}", content);
                                io::stdout().flush()?;
                                full_response.push_str(content);
                            }
                        }
                    }
                }
            }

            println!();
            messages.push(serde_json::json!({"role": "assistant", "content": full_response}));
        } else {
            println!("{}", "Error getting response".red());
        }
    }

    Ok(())
}

async fn check_status(verbose: bool) -> anyhow::Result<()> {
    println!("{}", "AI Service Status".bold().blue());
    println!();

    let daemon_ai_status = fetch_daemon_ai_status().await;

    // Installation status
    let installed = Command::new("which")
        .arg("llama-server")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if installed {
        println!("  {} llama-server: installed", "OK".green());
    } else {
        println!("  {} llama-server: not installed", "!!".red());
        return Ok(());
    }

    // Service status
    let running = is_server_running().await;
    if running {
        println!("  {} Service: {}", "OK".green(), "running".green());

        // Health check
        if check_server_health().await.is_ok() {
            println!(
                "  {} API: responding on {}",
                "OK".green(),
                LLAMA_SERVER_HOST
            );
        }
    } else {
        println!("  {} Service: {}", "!!".red(), "not running".red());
    }

    // GPU Info
    println!();
    println!("{}", "GPU Information:".bold());
    let gpu_info = check_gpu();
    match gpu_info {
        GpuInfo::Nvidia { name, vram } => {
            println!("  {} NVIDIA {}", "OK".green(), name);
            println!("    VRAM: {} MB", vram.to_string().cyan());

            if verbose {
                if let Ok(output) = Command::new("nvidia-smi")
                    .args([
                        "--query-gpu=driver_version,temperature.gpu,utilization.gpu",
                        "--format=csv,noheader",
                    ])
                    .output()
                {
                    let info = String::from_utf8_lossy(&output.stdout);
                    let parts: Vec<&str> = info.split(',').collect();
                    if parts.len() >= 3 {
                        println!("    Driver: {}", parts[0].trim().cyan());
                        println!("    Temperature: {}C", parts[1].trim().cyan());
                        println!("    Utilization: {}", parts[2].trim().cyan());
                    }
                }
            }
        }
        GpuInfo::Amd { name } => {
            println!("  {} AMD {}", "OK".green(), name);
        }
        GpuInfo::Intel { name } => {
            println!("  {} Intel {}", "OK".green(), name);
        }
        GpuInfo::None => {
            println!("  {} No GPU detected", "!!".yellow());
            println!("    Running in CPU mode (slower)");
        }
    }

    let sensory_status = match daemon_client::authenticated_client()
        .get(format!(
            "{}/api/v1/sensory/status",
            daemon_client::daemon_url()
        ))
        .send()
        .await
    {
        Ok(resp) if resp.status().is_success() => resp.json::<serde_json::Value>().await.ok(),
        _ => None,
    };

    if let Some(sensory) = sensory_status {
        println!();
        println!("{}", "Sensory Runtime:".bold());
        println!(
            "  Axi: {}",
            sensory["axi_state"].as_str().unwrap_or("unknown").cyan()
        );
        println!(
            "  Offload: {} / {}",
            sensory["gpu"]["llm_offload"].as_str().unwrap_or("cpu only"),
            sensory["gpu"]["vision_offload"]
                .as_str()
                .unwrap_or("cpu only")
        );
        println!(
            "  Voice SLO: {} ms (last {} ms)",
            sensory["voice"]["slo_target_ms"].as_u64().unwrap_or(5000),
            sensory["voice"]["last_latency_ms"]
                .as_u64()
                .unwrap_or_default()
        );
        if let Some(tps) = sensory["gpu"]["tokens_per_second"].as_f64() {
            println!("  GPU throughput: {:.1} tok/s", tps);
        }
        if let Some(temp) = sensory["gpu"]["gpu_temp_celsius"].as_f64() {
            println!("  GPU temperature: {:.1}C", temp);
        }
        println!(
            "  Kill switch: {}",
            sensory["kill_switch_active"].as_bool().unwrap_or(false)
        );
    }

    if let Some(ai_status) = daemon_ai_status.as_ref() {
        if let Some(runtime) = ai_status.runtime.as_ref() {
            println!();
            println!("{}", "Axi Runtime:".bold());
            println!(
                "  Modo: {} ({})",
                runtime.mode.as_str().cyan(),
                runtime.mode_confidence.as_str().dimmed()
            );
            println!("  Motivo: {}", runtime.mode_reason);
            if let Some(profile) = runtime.active_profile.as_ref() {
                let source = runtime
                    .profile_source
                    .as_deref()
                    .map(|value| format!(" [{}]", value))
                    .unwrap_or_default();
                println!("  Perfil activo: {}{}", profile.cyan(), source.dimmed());
            }
            if let Some(gpu_layers) = runtime.effective_gpu_layers {
                let source = runtime
                    .gpu_layers_source
                    .as_deref()
                    .map(|value| format!(" ({value})"))
                    .unwrap_or_default();
                println!(
                    "  GPU layers: {}{}",
                    gpu_layers.to_string().cyan(),
                    source.dimmed()
                );
            }
            if let Some(backend) = runtime.backend.as_ref() {
                let backend_name = runtime
                    .backend_name
                    .as_deref()
                    .map(|value| format!(" / {value}"))
                    .unwrap_or_default();
                println!("  Backend: {}{}", backend.cyan(), backend_name.dimmed());
            }
            println!(
                "  Servicio: {}{}{}",
                runtime.service_state.as_str().cyan(),
                runtime
                    .service_scope
                    .as_deref()
                    .map(|value| format!(" ({value})"))
                    .unwrap_or_default(),
                runtime
                    .service_pid
                    .map(|pid| format!(" pid {pid}"))
                    .unwrap_or_default()
            );
            if let Some(memory_mb) = runtime.gpu_memory_mb {
                println!("  VRAM llama-server: {} MiB", memory_mb.to_string().cyan());
            }
            if let Some(memory_mb) = runtime.rss_memory_mb {
                println!("  RSS llama-server: {} MiB", memory_mb.to_string().cyan());
            }
            if let Some(game_guard) = runtime.game_guard.as_ref() {
                let status = if game_guard.guard_enabled {
                    "activo".green().to_string()
                } else if game_guard.supported {
                    "desactivado".yellow().to_string()
                } else {
                    "no soportado".yellow().to_string()
                };
                println!("  Game Guard: {}", status);
                if game_guard.game_detected {
                    println!(
                        "    Juego detectado: {}{}",
                        game_guard
                            .game_name
                            .as_deref()
                            .unwrap_or("desconocido")
                            .cyan(),
                        game_guard
                            .game_pid
                            .map(|pid| format!(" (pid {pid})"))
                            .unwrap_or_default()
                    );
                }
            }
            if let Some(reason) = runtime.preflight_reason.as_ref() {
                println!("  Preflight: {}", reason.yellow());
            }
            if let Some(reason) = runtime.benchmark_pending_reason.as_ref() {
                println!("  Benchmark: {}", reason.yellow());
            } else if runtime.benchmark_completed == Some(true) {
                println!("  Benchmark: {}", "completado".green());
            }
            for note in &runtime.notes {
                println!("  Nota: {}", note.dimmed());
            }
        }
    }

    // Models
    println!();
    println!("{}", "Models:".bold());
    let models = list_gguf_models();
    if models.is_empty() {
        println!("  {} No models installed", "->".dimmed());
        println!("  Download with: {}", "life ai pull qwen3.5-4b".cyan());
    } else {
        let active_model = configured_model();
        for model in &models {
            let path = format!("{}/{}", MODEL_DIR, model);
            let size = std::fs::metadata(&path)
                .map(|m| format_size(m.len()))
                .unwrap_or_else(|_| "?".to_string());
            let state = if active_model.as_deref() == Some(model.as_str()) {
                "(default)".green().to_string()
            } else {
                String::new()
            };
            println!(
                "  {} {:<40} {} {}",
                "->".dimmed(),
                model.cyan(),
                size.dimmed(),
                state
            );
        }
    }

    // Current config
    if verbose {
        println!();
        println!("{}", "Configuration:".bold());
        if let Ok(env) = std::fs::read_to_string(LLAMA_ENV_FILE) {
            for line in env.lines() {
                if !line.starts_with('#') && !line.is_empty() {
                    println!("  {}", line.dimmed());
                }
            }
        }
    }

    // Memory usage if verbose and running
    if verbose && running {
        println!();
        println!("{}", "Memory Usage:".bold());

        if let Ok(output) = Command::new("ps")
            .args(["-o", "pid,rss,comm", "-C", "llama-server"])
            .output()
        {
            let mem_info = String::from_utf8_lossy(&output.stdout);
            for line in mem_info.lines().skip(1) {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 3 {
                    let rss_kb: i64 = parts[1].parse().unwrap_or(0);
                    let rss_mb = rss_kb / 1024;
                    println!(
                        "  {} PID {}: {} MB",
                        "->".dimmed(),
                        parts[0].cyan(),
                        rss_mb.to_string().cyan()
                    );
                }
            }
        }
    }

    if !running {
        println!();
        println!("Start it with: {}", "life ai start".cyan());
    }

    Ok(())
}

#[derive(Debug, Clone, Deserialize)]
struct DaemonAiStatus {
    runtime: Option<DaemonAiRuntimeStatus>,
}

#[derive(Debug, Clone, Deserialize)]
struct DaemonAiRuntimeStatus {
    service_state: String,
    service_scope: Option<String>,
    service_pid: Option<u32>,
    active_profile: Option<String>,
    profile_source: Option<String>,
    benchmark_completed: Option<bool>,
    benchmark_pending_reason: Option<String>,
    effective_gpu_layers: Option<i32>,
    gpu_layers_source: Option<String>,
    backend: Option<String>,
    backend_name: Option<String>,
    mode: String,
    mode_confidence: String,
    mode_reason: String,
    gpu_memory_mb: Option<u64>,
    rss_memory_mb: Option<u64>,
    preflight_reason: Option<String>,
    game_guard: Option<DaemonAiGameGuardStatus>,
    #[serde(default)]
    notes: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct DaemonAiGameGuardStatus {
    supported: bool,
    guard_enabled: bool,
    game_detected: bool,
    game_name: Option<String>,
    game_pid: Option<u32>,
}

async fn fetch_daemon_ai_status() -> Option<DaemonAiStatus> {
    let response = daemon_client::authenticated_client()
        .get(format!("{}/api/v1/ai/status", daemon_client::daemon_url()))
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    response.json::<DaemonAiStatus>().await.ok()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BenchmarkEntry {
    model: String,
    avg_latency_ms: u64,
    p95_latency_ms: u64,
    success_rate: f64,
    attempts: u32,
    model_size_bytes: u64,
    score: f64,
    benchmarked_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BenchmarkReport {
    generated_at: String,
    profile: String,
    prompt: String,
    entries: Vec<BenchmarkEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ModelCatalog {
    schema_version: String,
    catalog_version: String,
    generated_at: String,
    models: Vec<CatalogModelEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CatalogModelEntry {
    id: String,
    download_url: String,
    size_bytes: u64,
    #[serde(default)]
    runtime_profiles: Vec<String>,
    #[serde(default)]
    roles: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RuntimeProfileState {
    generated_at: String,
    runtime_profile: String,
    heavy_model_slots: u8,
    total_ram_gb: u32,
    total_vram_gb: Option<u32>,
    gpu: String,
    cpu_cores: u32,
    selected_model: Option<String>,
    catalog_version: Option<String>,
    catalog_source: Option<String>,
    catalog_signature_valid: bool,
}

#[derive(Debug, Clone)]
struct RuntimeProfileDetection {
    runtime_profile: String,
    total_ram_gb: u32,
    total_vram_gb: Option<u32>,
    gpu: String,
    cpu_cores: u32,
}

#[derive(Debug, Clone)]
struct LoadedCatalog {
    catalog: ModelCatalog,
    source: String,
    signature_valid: bool,
}

async fn benchmark_models(
    model_filter: Option<&str>,
    short: bool,
    repeats: u32,
) -> anyhow::Result<()> {
    if !is_server_running().await {
        println!("AI server is not running. Starting now...");
        start_ai(None, false).await?;
    }

    let mut models = if let Some(model) = model_filter {
        vec![model.to_string()]
    } else {
        list_gguf_models()
    };
    models.sort();
    models.dedup();

    if models.is_empty() {
        anyhow::bail!("No models found to benchmark");
    }

    let repeats = repeats.clamp(1, 10);
    let prompt = if short {
        "Reply with only: OK"
    } else {
        "In two short sentences, explain why local-first AI improves privacy and resilience."
    };
    let profile = if short { "short" } else { "standard" };

    println!("{}", "LifeOS Bench v1".bold().blue());
    println!("  Profile: {}", profile.cyan());
    println!("  Models:  {}", models.len());
    println!("  Repeats: {}", repeats);
    println!();

    let mut results = Vec::new();
    for model in &models {
        println!("{} {}", "Benchmarking".bold(), model.cyan());
        let mut latencies = Vec::new();
        let mut success = 0u32;
        for _ in 0..repeats {
            let started = std::time::Instant::now();
            let response = reqwest::Client::new()
                .post(format!("{}/v1/chat/completions", LLAMA_SERVER_HOST))
                .json(&serde_json::json!({
                    "model": model,
                    "messages": [{ "role": "user", "content": prompt }],
                    "stream": false,
                }))
                .send()
                .await;

            match response {
                Ok(r) if r.status().is_success() => {
                    latencies.push(started.elapsed().as_millis() as u64);
                    success += 1;
                }
                _ => {
                    latencies.push(started.elapsed().as_millis() as u64);
                }
            }
        }

        latencies.sort_unstable();
        let avg_latency_ms = latencies.iter().copied().sum::<u64>() / latencies.len() as u64;
        let p95_idx = ((latencies.len() as f64) * 0.95).ceil() as usize - 1;
        let p95_latency_ms = latencies
            .get(p95_idx.min(latencies.len().saturating_sub(1)))
            .copied()
            .unwrap_or(avg_latency_ms);
        let success_rate = success as f64 / repeats as f64;
        let model_size_bytes = model_file_size(model);

        // Weighted score: prioritize reliability + latency, with minor size bias.
        let score = (success_rate * 1000.0) + (10000.0 / (avg_latency_ms.max(1) as f64))
            - ((model_size_bytes as f64 / 1_000_000_000.0) * 2.0);

        let entry = BenchmarkEntry {
            model: model.to_string(),
            avg_latency_ms,
            p95_latency_ms,
            success_rate,
            attempts: repeats,
            model_size_bytes,
            score,
            benchmarked_at: chrono::Utc::now().to_rfc3339(),
        };

        println!(
            "  avg={}ms p95={}ms success={:.0}% score={:.2}",
            entry.avg_latency_ms,
            entry.p95_latency_ms,
            entry.success_rate * 100.0,
            entry.score
        );
        println!();
        results.push(entry);
    }

    results.sort_by(|a, b| b.score.total_cmp(&a.score));
    if let Some(best) = results.first() {
        println!(
            "{} {} (score {:.2})",
            "Recommended model:".green().bold(),
            best.model.cyan(),
            best.score
        );
    }

    let report = BenchmarkReport {
        generated_at: chrono::Utc::now().to_rfc3339(),
        profile: profile.to_string(),
        prompt: prompt.to_string(),
        entries: results,
    };

    save_benchmark_report(&report)?;
    println!(
        "Saved benchmark report: {}",
        benchmark_report_path().display().to_string().cyan()
    );
    Ok(())
}

async fn benchmark_sensory(
    audio_file: Option<&str>,
    prompt: Option<&str>,
    include_screen: bool,
    screen_source: Option<&str>,
    repeats: u32,
) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!(
            "{}/api/v1/sensory/benchmark",
            daemon_client::daemon_url()
        ))
        .json(&serde_json::json!({
            "audio_file": audio_file,
            "prompt": prompt,
            "include_screen": include_screen,
            "screen_source": screen_source,
            "repeats": repeats,
        }))
        .send()
        .await?;

    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to run sensory benchmark: {}", body);
    }

    let body: serde_json::Value = resp.json().await?;
    println!("{}", "LifeOS Sensory Bench".bold().blue());
    println!(
        "  avg voice loop: {} ms",
        body["avg_voice_loop_latency_ms"]
            .as_u64()
            .unwrap_or_default()
    );
    println!(
        "  avg vision query: {} ms",
        body["avg_vision_query_latency_ms"]
            .as_u64()
            .unwrap_or_default()
    );
    println!(
        "  avg gpu throughput: {:.1} tok/s",
        body["avg_gpu_tokens_per_second"]
            .as_f64()
            .unwrap_or_default()
    );
    if let Some(entries) = body["entries"].as_array() {
        println!("  iterations: {}", entries.len());
    }
    Ok(())
}

async fn autotune_model(dry_run: bool) -> anyhow::Result<()> {
    let report = load_benchmark_report()?;
    if report.entries.is_empty() {
        anyhow::bail!("No benchmark entries found. Run: life ai benchmark --short");
    }

    let detected = detect_runtime_profile(None)?;
    let loaded_catalog = load_model_catalog(true).await?;

    let mut runtime_state = load_runtime_profile().unwrap_or_else(|_| RuntimeProfileState {
        generated_at: chrono::Utc::now().to_rfc3339(),
        runtime_profile: detected.runtime_profile.clone(),
        heavy_model_slots: 1,
        total_ram_gb: detected.total_ram_gb,
        total_vram_gb: detected.total_vram_gb,
        gpu: detected.gpu.clone(),
        cpu_cores: detected.cpu_cores,
        selected_model: None,
        catalog_version: Some(loaded_catalog.catalog.catalog_version.clone()),
        catalog_source: Some(loaded_catalog.source.clone()),
        catalog_signature_valid: loaded_catalog.signature_valid,
    });

    runtime_state.catalog_version = Some(loaded_catalog.catalog.catalog_version.clone());
    runtime_state.catalog_source = Some(loaded_catalog.source.clone());
    runtime_state.catalog_signature_valid = loaded_catalog.signature_valid;
    runtime_state.heavy_model_slots = 1;

    let allowed_models: Vec<String> = loaded_catalog
        .catalog
        .models
        .iter()
        .filter(|m| {
            m.runtime_profiles.is_empty()
                || m.runtime_profiles
                    .iter()
                    .any(|rp| rp.eq_ignore_ascii_case(&runtime_state.runtime_profile))
        })
        .map(|m| m.id.clone())
        .collect();

    let mut sorted = report.entries.clone();
    sorted.retain(|e| {
        if allowed_models.is_empty() {
            return true;
        }
        allowed_models.iter().any(|m| m == &e.model)
    });
    if sorted.is_empty() {
        anyhow::bail!(
            "No benchmark entries match runtime profile '{}' from verified catalog",
            runtime_state.runtime_profile
        );
    }
    sorted.sort_by(|a, b| b.score.total_cmp(&a.score));
    let best = sorted
        .first()
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("Benchmark report is empty"))?;

    println!("{}", "AI Autotune".bold().blue());
    println!(
        "  Selected: {} (score {:.2}, avg {}ms, success {:.0}%)",
        best.model.cyan(),
        best.score,
        best.avg_latency_ms,
        best.success_rate * 100.0
    );
    println!(
        "  Runtime profile: {} (heavy_model_slots={})",
        runtime_state.runtime_profile.cyan(),
        runtime_state.heavy_model_slots
    );
    println!(
        "  Catalog: {} ({})",
        loaded_catalog.catalog.catalog_version.cyan(),
        if loaded_catalog.signature_valid {
            "signature valid".green().to_string()
        } else {
            "signature invalid".red().to_string()
        }
    );

    if dry_run {
        println!("{}", "Dry run enabled: no changes applied.".yellow());
        return Ok(());
    }

    apply_model_selection(&best.model)?;
    runtime_state.selected_model = Some(best.model.clone());
    runtime_state.generated_at = chrono::Utc::now().to_rfc3339();
    save_runtime_profile(&runtime_state)?;
    println!(
        "{} {}",
        "Applied model to /etc/lifeos/llama-server.env:"
            .green()
            .bold(),
        best.model.cyan()
    );
    println!(
        "{} {}",
        "Saved runtime profile:".green().bold(),
        model_profile_path().display().to_string().cyan()
    );
    println!("Restart service with: {}", "life ai start".cyan());
    Ok(())
}

async fn detect_profile(runtime_override: Option<&str>, apply: bool) -> anyhow::Result<()> {
    let detected = detect_runtime_profile(runtime_override)?;

    println!("{}", "AI Runtime Profile".bold().blue());
    println!("  Runtime: {}", detected.runtime_profile.cyan());
    println!("  RAM:     {} GB", detected.total_ram_gb);
    println!(
        "  VRAM:    {}",
        detected
            .total_vram_gb
            .map(|v| format!("{} GB", v))
            .unwrap_or_else(|| "N/A".to_string())
            .cyan()
    );
    println!("  GPU:     {}", detected.gpu.cyan());
    println!("  CPU:     {} cores", detected.cpu_cores);
    println!("  heavy_model_slots: {}", "1".cyan());

    let loaded_catalog = load_model_catalog(false).await?;
    let preferred = loaded_catalog
        .catalog
        .models
        .iter()
        .find(|m| {
            m.runtime_profiles
                .iter()
                .any(|rp| rp.eq_ignore_ascii_case(&detected.runtime_profile))
        })
        .map(|m| m.id.clone());
    if let Some(model) = preferred.as_ref() {
        println!("  Suggested model: {}", model.cyan());
    }

    if apply {
        let profile = RuntimeProfileState {
            generated_at: chrono::Utc::now().to_rfc3339(),
            runtime_profile: detected.runtime_profile,
            heavy_model_slots: 1,
            total_ram_gb: detected.total_ram_gb,
            total_vram_gb: detected.total_vram_gb,
            gpu: detected.gpu,
            cpu_cores: detected.cpu_cores,
            selected_model: preferred.clone(),
            catalog_version: Some(loaded_catalog.catalog.catalog_version),
            catalog_source: Some(loaded_catalog.source),
            catalog_signature_valid: loaded_catalog.signature_valid,
        };
        save_runtime_profile(&profile)?;
        println!(
            "{} {}",
            "Saved profile to".green().bold(),
            model_profile_path().display().to_string().cyan()
        );
    } else {
        println!("{}", "Use --apply to persist this profile.".dimmed());
    }

    Ok(())
}

async fn show_catalog_status(refresh: bool) -> anyhow::Result<()> {
    let loaded_catalog = load_model_catalog(refresh).await?;
    println!("{}", "Model Catalog".bold().blue());
    println!("  Source: {}", loaded_catalog.source.as_str().cyan());
    println!(
        "  Version: {}",
        loaded_catalog.catalog.catalog_version.as_str().cyan()
    );
    println!(
        "  Signature: {}",
        if loaded_catalog.signature_valid {
            "valid".green()
        } else {
            "invalid".red()
        }
    );
    println!("  Models: {}", loaded_catalog.catalog.models.len());
    for model in loaded_catalog.catalog.models.iter().take(8) {
        println!(
            "  {} {} [{}]",
            "-".dimmed(),
            model.id.cyan(),
            if model.runtime_profiles.is_empty() {
                "all".to_string()
            } else {
                model.runtime_profiles.join(",")
            }
        );
    }
    if loaded_catalog.catalog.models.len() > 8 {
        println!("  {}", "...".dimmed());
    }
    Ok(())
}

async fn ocr_screen(
    source: Option<&str>,
    capture_screen: bool,
    language: Option<&str>,
) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let response = client
        .post(format!("{}/api/v1/vision/ocr", daemon_client::daemon_url()))
        .json(&serde_json::json!({
            "source": source,
            "capture_screen": capture_screen,
            "language": language,
        }))
        .send()
        .await;

    match response {
        Ok(resp) if resp.status().is_success() => {
            let body: serde_json::Value = resp.json().await?;
            println!("{}", "Vision OCR result".bold().blue());
            println!(
                "  source: {}",
                body["source"].as_str().unwrap_or("-").dimmed()
            );
            println!(
                "  language: {}",
                body["language"].as_str().unwrap_or("eng").cyan()
            );
            println!();
            println!("{}", body["text"].as_str().unwrap_or("").trim());
            Ok(())
        }
        Ok(resp) => {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("OCR request failed ({}): {}", status, body);
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

// ==================== HELPER FUNCTIONS ====================

enum GpuInfo {
    Nvidia { name: String, vram: u64 },
    Amd { name: String },
    Intel { name: String },
    None,
}

fn check_gpu() -> GpuInfo {
    // Check for NVIDIA GPU
    if let Ok(output) = Command::new("nvidia-smi")
        .args([
            "--query-gpu=name,memory.total",
            "--format=csv,noheader,nounits",
        ])
        .output()
    {
        if output.status.success() {
            let output_str = String::from_utf8_lossy(&output.stdout);
            let parts: Vec<&str> = output_str.split(',').collect();
            if parts.len() >= 2 {
                let name = parts[0].trim().to_string();
                let vram = parts[1].trim().parse().unwrap_or(0);
                return GpuInfo::Nvidia { name, vram };
            }
        }
    }

    // Check for AMD GPU via rocminfo
    if let Ok(output) = Command::new("rocminfo").output() {
        let output_str = String::from_utf8_lossy(&output.stdout);
        if let Some(line) = output_str.lines().find(|l| l.contains("Marketing Name")) {
            let name = line
                .split(':')
                .nth(1)
                .unwrap_or("AMD GPU")
                .trim()
                .to_string();
            return GpuInfo::Amd { name };
        }
    }

    // Check for AMD GPU via lspci
    if let Ok(output) = Command::new("lspci").output() {
        let output_str = String::from_utf8_lossy(&output.stdout);
        for line in output_str.lines() {
            if line.contains("VGA") && line.contains("AMD") {
                let name = line.split(": ").nth(1).unwrap_or("AMD GPU").to_string();
                return GpuInfo::Amd { name };
            }
        }
    }

    // Check for Intel GPU via lspci
    if let Ok(output) = Command::new("lspci").output() {
        let output_str = String::from_utf8_lossy(&output.stdout);
        for line in output_str.lines() {
            if line.contains("VGA") && line.contains("Intel") {
                let name = line.split(": ").nth(1).unwrap_or("Intel GPU").to_string();
                return GpuInfo::Intel { name };
            }
        }
    }

    GpuInfo::None
}

/// Check if llama-server is running
async fn is_server_running() -> bool {
    // Check via systemctl
    if let Ok(output) = Command::new("systemctl")
        .args(["is-active", "llama-server"])
        .output()
    {
        if output.status.success() {
            return true;
        }
    }

    // Check if port 8082 is listening
    if let Ok(output) = Command::new("ss").args(["-tlnp"]).output() {
        let output_str = String::from_utf8_lossy(&output.stdout);
        if output_str.contains(":8082") {
            return true;
        }
    }

    // Try HTTP health check as fallback
    if let Ok(response) = reqwest::get(format!("{}/health", LLAMA_SERVER_HOST)).await {
        return response.status().is_success();
    }

    false
}

/// Check llama-server health endpoint
async fn check_server_health() -> anyhow::Result<()> {
    let response = reqwest::get(format!("{}/health", LLAMA_SERVER_HOST)).await?;

    if !response.status().is_success() {
        anyhow::bail!("llama-server returned error: {}", response.status());
    }

    Ok(())
}

/// List GGUF model files in the model directory
fn list_gguf_models() -> Vec<String> {
    let model_dir = std::path::Path::new(MODEL_DIR);
    if !model_dir.exists() {
        return Vec::new();
    }

    let mut models = Vec::new();
    if let Ok(entries) = std::fs::read_dir(model_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() {
                if let Some(ext) = path.extension() {
                    if ext == "gguf" {
                        if let Some(name) = path.file_name() {
                            let candidate = name.to_string_lossy().to_string();
                            if is_selectable_model_asset(&candidate) {
                                models.push(candidate);
                            }
                        }
                    }
                }
            }
        }
    }
    models.sort();
    models
}

fn is_selectable_model_asset(model: &str) -> bool {
    let lower = model.to_ascii_lowercase();
    !lower.starts_with("mmproj-")
        && !lower.contains("-mmproj-")
        && !lower.starts_with("nomic-embed-")
        && !lower.starts_with("whisper")
        && !lower.contains("embedding")
}

fn qwen_download(repo: &str, filename: &str, mmproj_filename: &str) -> ModelDownload {
    ModelDownload {
        url: format!("https://huggingface.co/unsloth/{repo}/resolve/main/{filename}"),
        filename: filename.to_string(),
        companion_mmproj: Some(ModelArtifactDownload {
            url: format!("https://huggingface.co/unsloth/{repo}/resolve/main/mmproj-F16.gguf"),
            filename: mmproj_filename.to_string(),
        }),
    }
}

fn basic_download(url: &str, filename: &str) -> ModelDownload {
    ModelDownload {
        url: url.to_string(),
        filename: filename.to_string(),
        companion_mmproj: None,
    }
}

fn known_model_download(model: &str) -> Option<ModelDownload> {
    match model {
        "Qwen3.5-4B-Q4_K_M.gguf" | "qwen3.5-4b" | "qwen3.5:4b" | "qwen3.5" => {
            Some(qwen_download(
                "Qwen3.5-4B-GGUF",
                "Qwen3.5-4B-Q4_K_M.gguf",
                "Qwen3.5-4B-mmproj-F16.gguf",
            ))
        }
        "Qwen3.5-9B-Q4_K_M.gguf" | "qwen3.5-9b" | "qwen3.5:9b" => Some(qwen_download(
            "Qwen3.5-9B-GGUF",
            "Qwen3.5-9B-Q4_K_M.gguf",
            "Qwen3.5-9B-mmproj-F16.gguf",
        )),
        "Qwen3.5-27B-Q4_K_M.gguf" | "qwen3.5-27b" | "qwen3.5:27b" => {
            Some(qwen_download(
                "Qwen3.5-27B-GGUF",
                "Qwen3.5-27B-Q4_K_M.gguf",
                "Qwen3.5-27B-mmproj-F16.gguf",
            ))
        }
        "llama3.2-3b" | "llama3.2:3b" => Some(basic_download(
            "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            "llama-3.2-3b-instruct-q4_k_m.gguf",
        )),
        "llama3.2-1b" | "llama3.2:1b" => Some(basic_download(
            "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            "llama-3.2-1b-instruct-q4_k_m.gguf",
        )),
        "mistral" | "mistral-7b" | "mistral:7b" => Some(basic_download(
            "https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/Mistral-7B-Instruct-v0.3-Q4_K_M.gguf",
            "mistral-7b-instruct-v0.3-q4_k_m.gguf",
        )),
        "codellama" | "codellama-7b" | "codellama:7b" => Some(basic_download(
            "https://huggingface.co/bartowski/CodeLlama-7B-Instruct-GGUF/resolve/main/CodeLlama-7B-Instruct-Q4_K_M.gguf",
            "codellama-7b-instruct-q4_k_m.gguf",
        )),
        _ => None,
    }
}

fn qwen_companion_mmproj_filename(model: &str) -> Option<String> {
    known_model_download(model)
        .and_then(|download| download.companion_mmproj.map(|artifact| artifact.filename))
}

fn ensure_companion_artifacts(model: &str, force: bool) -> anyhow::Result<()> {
    let Some(download) = known_model_download(model) else {
        return Ok(());
    };

    let Some(companion) = download.companion_mmproj else {
        return Ok(());
    };

    let companion_path = format!("{}/{}", MODEL_DIR, companion.filename);
    if !force && std::path::Path::new(&companion_path).exists() {
        return Ok(());
    }

    println!(
        "  {} Ensuring companion asset {}",
        "->".dimmed(),
        companion.filename.cyan()
    );
    download_file_as_root(&companion.url, &companion_path)
}

fn download_file_as_root(url: &str, dest_path: &str) -> anyhow::Result<()> {
    if let Some(parent) = std::path::Path::new(dest_path).parent() {
        let _ = Command::new("sudo")
            .args(["mkdir", "-p", &parent.display().to_string()])
            .output();
    }

    let tmp_path = format!("{}.tmp", dest_path);
    let status = Command::new("sudo")
        .args(["curl", "-fSL", "--progress-bar", "-o", &tmp_path, url])
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()?;

    if !status.success() {
        let _ = Command::new("sudo").args(["rm", "-f", &tmp_path]).output();
        anyhow::bail!("Failed to download {}", url);
    }

    let mv_status = Command::new("sudo")
        .args(["mv", &tmp_path, dest_path])
        .status()?;
    if !mv_status.success() {
        anyhow::bail!("Failed to install downloaded artifact at {}", dest_path);
    }

    Ok(())
}

/// Resolve a model name or URL to a download target.
fn resolve_model_download(model: &str) -> ModelDownload {
    // If it's already a URL, use it directly
    if model.starts_with("http://") || model.starts_with("https://") {
        let filename = model.rsplit('/').next().unwrap_or("model.gguf").to_string();
        return ModelDownload {
            url: model.to_string(),
            filename,
            companion_mmproj: None,
        };
    }

    // If it ends with .gguf, assume it's a filename - check known models
    if model.ends_with(".gguf") {
        if let Some(download) = known_model_download(model) {
            return download;
        }

        return ModelDownload {
            url: format!(
                "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/{}",
                model
            ),
            filename: model.to_string(),
            companion_mmproj: None,
        };
    }

    // Map common short names to HuggingFace URLs
    if let Some(download) = known_model_download(model.to_lowercase().as_str()) {
        return download;
    }

    // Assume it's a HuggingFace model path
    let filename = format!("{}.gguf", model.replace(['/', ':'], "-"));
    let url = format!("https://huggingface.co/{}", model);
    ModelDownload {
        url,
        filename,
        companion_mmproj: None,
    }
}

fn format_size(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut size = bytes as f64;
    let mut unit_idx = 0;

    while size >= 1024.0 && unit_idx < UNITS.len() - 1 {
        size /= 1024.0;
        unit_idx += 1;
    }

    format!("{:.1} {}", size, UNITS[unit_idx])
}

fn model_file_size(model: &str) -> u64 {
    let path = std::path::Path::new(MODEL_DIR).join(model);
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

fn benchmark_report_path() -> std::path::PathBuf {
    let base = dirs::config_dir().unwrap_or_else(|| std::path::PathBuf::from("."));
    base.join("lifeos").join("bench").join("latest.json")
}

fn save_benchmark_report(report: &BenchmarkReport) -> anyhow::Result<()> {
    let path = benchmark_report_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let serialized = serde_json::to_string_pretty(report)?;
    std::fs::write(path, serialized)?;
    Ok(())
}

fn load_benchmark_report() -> anyhow::Result<BenchmarkReport> {
    let path = benchmark_report_path();
    let raw = std::fs::read_to_string(&path).map_err(|e| {
        anyhow::anyhow!("Failed to read benchmark report {}: {}", path.display(), e)
    })?;
    let parsed: BenchmarkReport = serde_json::from_str(&raw).map_err(|e| {
        anyhow::anyhow!("Failed to parse benchmark report {}: {}", path.display(), e)
    })?;
    Ok(parsed)
}

fn apply_model_selection(model_name: &str) -> anyhow::Result<()> {
    upsert_llama_env_var("LIFEOS_AI_MODEL", model_name)?;
    if let Some(mmproj) = qwen_companion_mmproj_filename(model_name) {
        upsert_llama_env_var("LIFEOS_AI_MMPROJ", &mmproj)?;
    }
    clear_removed_model(model_name)?;
    sync_selected_model_profile(model_name)?;
    Ok(())
}

fn configured_model() -> Option<String> {
    let content = std::fs::read_to_string(LLAMA_ENV_FILE).ok()?;
    content.lines().find_map(|line| {
        line.strip_prefix("LIFEOS_AI_MODEL=")
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
    })
}

fn upsert_llama_env_var(key: &str, value: &str) -> anyhow::Result<()> {
    let existing = std::fs::read_to_string(LLAMA_ENV_FILE).unwrap_or_default();
    let mut found = false;
    let mut lines = existing
        .lines()
        .map(|line| {
            if line.starts_with(&format!("{}=", key)) {
                found = true;
                format!("{}={}", key, value)
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>();

    if !found {
        lines.push(format!("{}={}", key, value));
    }

    let serialized = format!("{}\n", lines.join("\n"));
    let status = write_root_file(LLAMA_ENV_FILE, &serialized)?;
    if !status.success() {
        anyhow::bail!("Failed to update {}", LLAMA_ENV_FILE);
    }
    Ok(())
}

fn sync_selected_model_profile(model_name: &str) -> anyhow::Result<()> {
    let mut profile = match load_runtime_profile() {
        Ok(profile) => profile,
        Err(_) => return Ok(()),
    };
    profile.selected_model = Some(model_name.to_string());
    profile.generated_at = chrono::Utc::now().to_rfc3339();
    save_runtime_profile(&profile)
}

fn load_removed_models() -> BTreeSet<String> {
    std::fs::read_to_string(REMOVED_MODELS_FILE)
        .ok()
        .map(|content| {
            content
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .map(ToOwned::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

fn write_removed_models(models: &BTreeSet<String>) -> anyhow::Result<()> {
    let serialized = if models.is_empty() {
        String::new()
    } else {
        format!(
            "{}\n",
            models.iter().cloned().collect::<Vec<_>>().join("\n")
        )
    };
    let status = write_root_file(REMOVED_MODELS_FILE, &serialized)?;
    if !status.success() {
        anyhow::bail!("Failed to update {}", REMOVED_MODELS_FILE);
    }
    Ok(())
}

fn mark_model_removed(model_name: &str) -> anyhow::Result<()> {
    let mut removed = load_removed_models();
    removed.insert(model_name.to_string());
    write_removed_models(&removed)
}

fn clear_removed_model(model_name: &str) -> anyhow::Result<()> {
    let mut removed = load_removed_models();
    if removed.remove(model_name) {
        write_removed_models(&removed)?;
    }
    Ok(())
}

fn write_root_file(path: &str, contents: &str) -> anyhow::Result<std::process::ExitStatus> {
    let temp_path =
        std::env::temp_dir().join(format!("lifeos-root-write-{}.tmp", std::process::id()));
    std::fs::write(&temp_path, contents)?;

    let temp_path_string = temp_path.to_string_lossy().into_owned();
    let status = Command::new("sudo")
        .args(["install", "-D", "-m", "0644", &temp_path_string, path])
        .status()?;
    let _ = std::fs::remove_file(&temp_path);
    Ok(status)
}

fn model_profile_path() -> PathBuf {
    let base = dirs::config_dir().unwrap_or_else(|| PathBuf::from("."));
    base.join("lifeos").join("model-profile.toml")
}

fn model_catalog_cache_path() -> PathBuf {
    let base = dirs::config_dir().unwrap_or_else(|| PathBuf::from("."));
    base.join("lifeos").join("catalog").join("v1.json")
}

fn model_catalog_cache_sig_path() -> PathBuf {
    let base = dirs::config_dir().unwrap_or_else(|| PathBuf::from("."));
    base.join("lifeos").join("catalog").join("v1.json.sig")
}

fn save_runtime_profile(profile: &RuntimeProfileState) -> anyhow::Result<()> {
    let path = model_profile_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let serialized = toml::to_string_pretty(profile)?;
    std::fs::write(path, serialized)?;
    Ok(())
}

fn load_runtime_profile() -> anyhow::Result<RuntimeProfileState> {
    let path = model_profile_path();
    let raw = std::fs::read_to_string(&path)
        .map_err(|e| anyhow::anyhow!("Failed to read runtime profile {}: {}", path.display(), e))?;
    let profile: RuntimeProfileState = toml::from_str(&raw).map_err(|e| {
        anyhow::anyhow!("Failed to parse runtime profile {}: {}", path.display(), e)
    })?;
    Ok(profile)
}

fn total_ram_gb() -> u32 {
    if let Ok(content) = std::fs::read_to_string("/proc/meminfo") {
        for line in content.lines() {
            if line.starts_with("MemTotal:") {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if let Some(kb_str) = parts.get(1) {
                    if let Ok(kb) = kb_str.parse::<u64>() {
                        return ((kb / 1024 / 1024).max(1)) as u32;
                    }
                }
            }
        }
    }
    8
}

fn total_vram_gb(gpu: &GpuInfo) -> Option<u32> {
    match gpu {
        GpuInfo::Nvidia { vram, .. } => Some((vram / 1024) as u32),
        _ => None,
    }
}

fn normalize_runtime_profile(profile: &str) -> anyhow::Result<String> {
    let normalized = profile.trim().to_lowercase();
    if matches!(normalized.as_str(), "lite" | "edge" | "secure" | "pro") {
        Ok(normalized)
    } else {
        anyhow::bail!(
            "Invalid runtime profile '{}'. Use lite|edge|secure|pro",
            profile
        );
    }
}

fn detect_runtime_profile(
    runtime_override: Option<&str>,
) -> anyhow::Result<RuntimeProfileDetection> {
    let gpu = check_gpu();
    let total_ram_gb = total_ram_gb();
    let total_vram_gb = total_vram_gb(&gpu);
    let cpu_cores = num_cpus::get() as u32;

    let gpu_label = match &gpu {
        GpuInfo::Nvidia { name, .. } => format!("nvidia:{}", name),
        GpuInfo::Amd { name } => format!("amd:{}", name),
        GpuInfo::Intel { name } => format!("intel:{}", name),
        GpuInfo::None => "none".to_string(),
    };

    let auto = if total_ram_gb < 8 {
        "lite".to_string()
    } else if total_ram_gb < 16 {
        "edge".to_string()
    } else if total_ram_gb >= 24 && total_vram_gb.unwrap_or(0) >= 8 {
        "pro".to_string()
    } else if total_ram_gb >= 16 && matches!(gpu, GpuInfo::None) {
        "secure".to_string()
    } else {
        "edge".to_string()
    };

    let runtime_profile = if let Some(override_profile) = runtime_override {
        normalize_runtime_profile(override_profile)?
    } else {
        auto
    };

    Ok(RuntimeProfileDetection {
        runtime_profile,
        total_ram_gb,
        total_vram_gb,
        gpu: gpu_label,
        cpu_cores,
    })
}

fn parse_signature(sig: &str) -> String {
    sig.lines()
        .find_map(|line| {
            let t = line.trim();
            if t.is_empty() || t.starts_with('#') {
                return None;
            }
            Some(t.strip_prefix("sha256:").unwrap_or(t).trim().to_lowercase())
        })
        .unwrap_or_default()
}

fn digest_catalog_bytes(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(bytes);
    format!("{:x}", digest)
}

fn verify_catalog_signature(bytes: &[u8], signature_text: &str) -> anyhow::Result<bool> {
    let expected = parse_signature(signature_text);
    if expected.is_empty() {
        return Ok(false);
    }
    let actual = digest_catalog_bytes(bytes);
    Ok(actual.eq_ignore_ascii_case(&expected))
}

fn parse_catalog(bytes: &[u8]) -> anyhow::Result<ModelCatalog> {
    let catalog: ModelCatalog = serde_json::from_slice(bytes)?;
    if catalog.models.is_empty() {
        anyhow::bail!("Catalog has no models");
    }
    Ok(catalog)
}

fn cache_catalog(bytes: &[u8], signature_text: &str) -> anyhow::Result<()> {
    let path = model_catalog_cache_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, bytes)?;
    std::fs::write(model_catalog_cache_sig_path(), signature_text)?;
    Ok(())
}

fn load_cached_catalog() -> anyhow::Result<LoadedCatalog> {
    let bytes = std::fs::read(model_catalog_cache_path())?;
    let sig = std::fs::read_to_string(model_catalog_cache_sig_path())?;
    let signature_valid = verify_catalog_signature(&bytes, &sig)?;
    if !signature_valid {
        anyhow::bail!("Cached catalog signature verification failed");
    }
    let catalog = parse_catalog(&bytes)?;
    Ok(LoadedCatalog {
        catalog,
        source: "cache".to_string(),
        signature_valid,
    })
}

fn load_embedded_catalog() -> anyhow::Result<LoadedCatalog> {
    let bytes = EMBEDDED_MODEL_CATALOG.as_bytes();
    let signature_valid = verify_catalog_signature(bytes, EMBEDDED_MODEL_CATALOG_SIG)?;
    if !signature_valid {
        anyhow::bail!("Embedded catalog signature verification failed");
    }
    let catalog = parse_catalog(bytes)?;
    Ok(LoadedCatalog {
        catalog,
        source: "embedded-fallback".to_string(),
        signature_valid,
    })
}

async fn try_fetch_remote_catalog() -> anyhow::Result<LoadedCatalog> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(6))
        .build()?;

    let catalog_resp = client.get(MODEL_CATALOG_URL).send().await?;
    if !catalog_resp.status().is_success() {
        anyhow::bail!(
            "Remote catalog returned status {}",
            catalog_resp.status().as_u16()
        );
    }
    let catalog_bytes = catalog_resp.bytes().await?.to_vec();

    let sig_resp = client.get(MODEL_CATALOG_SIG_URL).send().await?;
    if !sig_resp.status().is_success() {
        anyhow::bail!(
            "Remote catalog signature returned status {}",
            sig_resp.status().as_u16()
        );
    }
    let sig_text = sig_resp.text().await?;

    let signature_valid = verify_catalog_signature(&catalog_bytes, &sig_text)?;
    if !signature_valid {
        anyhow::bail!("Remote catalog signature verification failed");
    }

    let catalog = parse_catalog(&catalog_bytes)?;
    cache_catalog(&catalog_bytes, &sig_text)?;

    Ok(LoadedCatalog {
        catalog,
        source: "remote".to_string(),
        signature_valid,
    })
}

async fn load_model_catalog(refresh: bool) -> anyhow::Result<LoadedCatalog> {
    if refresh {
        if let Ok(remote) = try_fetch_remote_catalog().await {
            return Ok(remote);
        }
    }

    if !refresh {
        if let Ok(cached) = load_cached_catalog() {
            return Ok(cached);
        }
    }

    if let Ok(remote) = try_fetch_remote_catalog().await {
        return Ok(remote);
    }

    if let Ok(cached) = load_cached_catalog() {
        return Ok(cached);
    }

    load_embedded_catalog()
}

// Required for streaming in chat
use futures::StreamExt;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_resolve_qwen_9b_exact_filename_uses_correct_repo_and_mmproj() {
        let download = resolve_model_download("Qwen3.5-9B-Q4_K_M.gguf");
        assert!(download.url.contains("Qwen3.5-9B-GGUF"));
        assert_eq!(download.filename, "Qwen3.5-9B-Q4_K_M.gguf");
        let companion = download
            .companion_mmproj
            .expect("Expected Qwen companion mmproj");
        assert_eq!(companion.filename, "Qwen3.5-9B-mmproj-F16.gguf");
        assert!(companion.url.contains("Qwen3.5-9B-GGUF"));
    }

    #[test]
    fn test_resolve_qwen_27b_short_name_uses_correct_repo() {
        let download = resolve_model_download("qwen3.5-27b");
        assert!(download.url.contains("Qwen3.5-27B-GGUF"));
        assert_eq!(download.filename, "Qwen3.5-27B-Q4_K_M.gguf");
    }

    #[test]
    fn test_selectable_model_asset_filters_auxiliary_ggufs() {
        assert!(is_selectable_model_asset("Qwen3.5-4B-Q4_K_M.gguf"));
        assert!(!is_selectable_model_asset("Qwen3.5-4B-mmproj-F16.gguf"));
        assert!(!is_selectable_model_asset("nomic-embed-text-v1.5.f16.gguf"));
        assert!(!is_selectable_model_asset("whisper-small.gguf"));
    }
}
