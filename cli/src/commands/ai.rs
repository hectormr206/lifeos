use clap::Subcommand;
use colored::Colorize;
use std::process::Command;
use std::io::{self, Write};

/// Default llama-server host
const LLAMA_SERVER_HOST: &str = "http://localhost:8080";
/// Default model directory
const MODEL_DIR: &str = "/var/lib/lifeos/models";

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
}

pub async fn execute(args: AiCommands) -> anyhow::Result<()> {
    match args {
        AiCommands::Start { model, enable } => start_ai(model, enable).await,
        AiCommands::Stop => stop_ai().await,
        AiCommands::Ask { prompt } => ask_ai(&prompt).await,
        AiCommands::Do { action } => do_action(&action).await,
        AiCommands::Models { all } => list_models(all).await,
        AiCommands::Pull { model, force } => pull_model(&model, force).await,
        AiCommands::Remove { model, yes } => remove_model(&model, yes).await,
        AiCommands::Chat { model } => interactive_chat(model.as_deref()).await,
        AiCommands::Status { verbose } => check_status(verbose).await,
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
        println!("  {} Downloading default model on service start...", "->".dimmed());
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
            // Update the env file
            let _ = Command::new("sudo")
                .args(["sed", "-i", &format!("s/^LIFEOS_AI_MODEL=.*/LIFEOS_AI_MODEL={}/", model_name), "/etc/lifeos/llama-server.env"])
                .output();
            println!("  {} Model set to: {}", "->".dimmed(), model_name.cyan());
        } else {
            println!("  {} Model {} not found in {}", "!".yellow(), model_name, MODEL_DIR);
        }
    }

    // Step 5: Start the service
    print!("Starting llama-server service... ");
    let running = is_server_running().await;

    if running {
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
                println!("Check logs with: {}", "journalctl -u llama-server -n 50".cyan());
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
    println!("Try: {} or {}",
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
    println!("{} {}", "Executing:".bold(), action.cyan());

    let prompt = format!(
        "The user wants to: {}. \
         Generate a shell command to accomplish this. \
         Respond ONLY with the command, no explanation.",
        action
    );

    let client = reqwest::Client::new();
    let response = client
        .post(format!("{}/v1/chat/completions", LLAMA_SERVER_HOST))
        .json(&serde_json::json!({
            "messages": [
                {"role": "system", "content": "You are a command generator. Output only the shell command, no markdown, no explanation."},
                {"role": "user", "content": prompt}
            ],
            "stream": false
        }))
        .send()
        .await?;

    if response.status().is_success() {
        let json: serde_json::Value = response.json().await?;
        if let Some(cmd) = json
            .get("choices")
            .and_then(|c| c.get(0))
            .and_then(|c| c.get("message"))
            .and_then(|m| m.get("content"))
            .and_then(|c| c.as_str())
        {
            let cmd = cmd.trim();
            println!("\nGenerated command:");
            println!("  {}", cmd.cyan());
            println!("\nExecute? [Y/n] ");

            let mut input = String::new();
            io::stdin().read_line(&mut input)?;

            if input.trim().is_empty() || input.trim().eq_ignore_ascii_case("y") {
                println!("\nExecuting...\n");
                let output = Command::new("sh")
                    .arg("-c")
                    .arg(cmd)
                    .output()?;

                print!("{}", String::from_utf8_lossy(&output.stdout));
                eprint!("{}", String::from_utf8_lossy(&output.stderr));
            } else {
                println!("Cancelled.");
            }
        }
    }

    Ok(())
}

async fn list_models(all: bool) -> anyhow::Result<()> {
    println!("{}", "AI Models".bold().blue());
    println!();

    // List installed GGUF models
    let models = list_gguf_models();
    if models.is_empty() {
        println!("{}", "  No models installed".dimmed());
        println!();
        println!("Download a model with:");
        println!("  {}", "life ai pull qwen3-8b".cyan());
    } else {
        println!("{}", "Installed Models:".bold());
        println!("{:<40} {:>10}", "Name", "Size");
        println!("{}", "-".repeat(52).dimmed());

        for model in &models {
            let path = format!("{}/{}", MODEL_DIR, model);
            let size = std::fs::metadata(&path)
                .map(|m| format_size(m.len()))
                .unwrap_or_else(|_| "?".to_string());
            println!("{:<40} {:>10}", model.cyan(), size.dimmed());
        }
    }

    if all {
        println!();
        println!("{}", "Available to Download:".bold());
        let available = vec![
            ("qwen3-8b-q4_k_m.gguf", "~5.0GB", "Qwen3 8B - Fast general assistant"),
            ("qwen3-1.7b-q4_k_m.gguf", "~1.2GB", "Qwen3 1.7B - Ultra-lightweight"),
            ("llama-3.2-3b-instruct-q4_k_m.gguf", "~2.0GB", "Llama 3.2 3B - Lightweight"),
            ("llama-3.2-1b-instruct-q4_k_m.gguf", "~0.8GB", "Llama 3.2 1B - Minimal"),
            ("mistral-7b-instruct-v0.3-q4_k_m.gguf", "~4.1GB", "Mistral 7B - General purpose"),
            ("codellama-7b-instruct-q4_k_m.gguf", "~3.8GB", "CodeLlama 7B - Code generation"),
        ];

        for (name, size, desc) in available {
            println!("  {:<45} {:>8}  {}",
                name.cyan(),
                size.dimmed(),
                desc
            );
        }
        println!();
        println!("Or download any GGUF model directly:");
        println!("  {}", "life ai pull https://huggingface.co/.../model.gguf".cyan());
    }

    println!();
    println!("Pull a model: {}", "life ai pull <model>".cyan());

    Ok(())
}

async fn pull_model(model: &str, force: bool) -> anyhow::Result<()> {
    println!("{}", format!("Pulling model: {}", model).bold().blue());

    // Determine the URL and filename
    let (url, filename) = resolve_model_url(model);

    let dest_path = format!("{}/{}", MODEL_DIR, filename);

    // Check if model already exists
    if !force && std::path::Path::new(&dest_path).exists() {
        println!("Model {} already installed", filename);
        println!("Use {} to re-download", "--force".cyan());
        return Ok(());
    }

    println!("Downloading from: {}", url.dimmed());
    println!("This may take several minutes depending on your connection...");
    println!();

    // Use curl for download with progress
    let tmp_path = format!("{}.tmp", dest_path);

    // Ensure directory exists
    let _ = Command::new("sudo").args(["mkdir", "-p", MODEL_DIR]).output();

    let status = Command::new("sudo")
        .args(["curl", "-fSL", "--progress-bar", "-o", &tmp_path, &url])
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()?;

    if status.success() {
        let _ = Command::new("sudo").args(["mv", &tmp_path, &dest_path]).output();
        println!();
        println!("{}", format!("Model {} downloaded successfully", filename).green());

        // Show file size
        if let Ok(meta) = std::fs::metadata(&dest_path) {
            println!("  Size: {}", format_size(meta.len()));
        }
    } else {
        let _ = Command::new("sudo").args(["rm", "-f", &tmp_path]).output();
        anyhow::bail!("Failed to download model");
    }

    Ok(())
}

async fn remove_model(model: &str, yes: bool) -> anyhow::Result<()> {
    let model_path = format!("{}/{}", MODEL_DIR, model);

    if !std::path::Path::new(&model_path).exists() {
        anyhow::bail!("Model {} not found in {}", model, MODEL_DIR);
    }

    // Show size
    let size = std::fs::metadata(&model_path)
        .map(|m| format_size(m.len()))
        .unwrap_or_else(|_| "?".to_string());

    println!("{}", format!("Removing model: {} ({})", model, size).bold().yellow());

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

    match Command::new("sudo").args(["rm", "-f", &model_path]).output() {
        Ok(output) if output.status.success() => {
            println!("{}", format!("Model {} removed", model).green());
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

    print!("{}\n", "-".repeat(60).dimmed());
    println!("{}  {}  {}",
        "Chat".bold(),
        format!("Model: {}", model_display).bold().cyan(),
        "Type 'exit' or 'quit' to end"
    );
    print!("{}\n", "-".repeat(60).dimmed());

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
        if let Ok(_) = check_server_health().await {
            println!("  {} API: responding on {}", "OK".green(), LLAMA_SERVER_HOST);
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
                    .args(["--query-gpu=driver_version,temperature.gpu,utilization.gpu", "--format=csv,noheader"])
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

    // Models
    println!();
    println!("{}", "Models:".bold());
    let models = list_gguf_models();
    if models.is_empty() {
        println!("  {} No models installed", "->".dimmed());
        println!("  Download with: {}", "life ai pull qwen3-8b".cyan());
    } else {
        for model in &models {
            let path = format!("{}/{}", MODEL_DIR, model);
            let size = std::fs::metadata(&path)
                .map(|m| format_size(m.len()))
                .unwrap_or_else(|_| "?".to_string());
            println!("  {} {:<40} {}", "->".dimmed(), model.cyan(), size.dimmed());
        }
    }

    // Current config
    if verbose {
        println!();
        println!("{}", "Configuration:".bold());
        if let Ok(env) = std::fs::read_to_string("/etc/lifeos/llama-server.env") {
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
                    println!("  {} PID {}: {} MB",
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
        .args(["--query-gpu=name,memory.total", "--format=csv,noheader,nounits"])
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
            let name = line.split(':')
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
                let name = line.split(": ")
                    .nth(1)
                    .unwrap_or("AMD GPU")
                    .to_string();
                return GpuInfo::Amd { name };
            }
        }
    }

    // Check for Intel GPU via lspci
    if let Ok(output) = Command::new("lspci").output() {
        let output_str = String::from_utf8_lossy(&output.stdout);
        for line in output_str.lines() {
            if line.contains("VGA") && line.contains("Intel") {
                let name = line.split(": ")
                    .nth(1)
                    .unwrap_or("Intel GPU")
                    .to_string();
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

    // Check if port 8080 is listening
    if let Ok(output) = Command::new("ss")
        .args(["-tlnp"])
        .output()
    {
        let output_str = String::from_utf8_lossy(&output.stdout);
        if output_str.contains(":8080") {
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
                            models.push(name.to_string_lossy().to_string());
                        }
                    }
                }
            }
        }
    }
    models.sort();
    models
}

/// Resolve a model name or URL to (download_url, filename)
fn resolve_model_url(model: &str) -> (String, String) {
    // If it's already a URL, use it directly
    if model.starts_with("http://") || model.starts_with("https://") {
        let filename = model.rsplit('/').next().unwrap_or("model.gguf").to_string();
        return (model.to_string(), filename);
    }

    // If it ends with .gguf, assume it's a filename - check known models
    if model.ends_with(".gguf") {
        let url = format!("https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/{}", model);
        return (url, model.to_string());
    }

    // Map common short names to HuggingFace URLs
    match model.to_lowercase().as_str() {
        "qwen3-8b" | "qwen3:8b" | "qwen3" => (
            "https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/qwen3-8b-q4_k_m.gguf".to_string(),
            "qwen3-8b-q4_k_m.gguf".to_string(),
        ),
        "qwen3-1.7b" | "qwen3:1.7b" | "qwen3-small" => (
            "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/qwen3-1.7b-q4_k_m.gguf".to_string(),
            "qwen3-1.7b-q4_k_m.gguf".to_string(),
        ),
        "llama3.2-3b" | "llama3.2:3b" => (
            "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf".to_string(),
            "llama-3.2-3b-instruct-q4_k_m.gguf".to_string(),
        ),
        "llama3.2-1b" | "llama3.2:1b" => (
            "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf".to_string(),
            "llama-3.2-1b-instruct-q4_k_m.gguf".to_string(),
        ),
        "mistral" | "mistral-7b" | "mistral:7b" => (
            "https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/Mistral-7B-Instruct-v0.3-Q4_K_M.gguf".to_string(),
            "mistral-7b-instruct-v0.3-q4_k_m.gguf".to_string(),
        ),
        "codellama" | "codellama-7b" | "codellama:7b" => (
            "https://huggingface.co/bartowski/CodeLlama-7B-Instruct-GGUF/resolve/main/CodeLlama-7B-Instruct-Q4_K_M.gguf".to_string(),
            "codellama-7b-instruct-q4_k_m.gguf".to_string(),
        ),
        _ => {
            // Assume it's a HuggingFace model path
            let filename = format!("{}.gguf", model.replace('/', "-").replace(':', "-"));
            let url = format!("https://huggingface.co/{}", model);
            (url, filename)
        }
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

// Required for streaming in chat
use futures::StreamExt;
