use clap::Subcommand;
use colored::Colorize;
use std::process::Command;
use std::io::{self, Write};

#[derive(Subcommand)]
pub enum AiCommands {
    /// Start Ollama AI service
    Start {
        /// Start with specific model preloaded
        #[arg(short, long)]
        model: Option<String>,
        /// Enable auto-start on boot
        #[arg(short, long)]
        enable: bool,
    },
    /// Stop Ollama AI service
    Stop,
    /// Ask the AI assistant a single question
    Ask { prompt: String },
    /// Execute action in natural language
    Do { action: String },
    /// List available and installed models
    Models {
        /// Show all available models (not just installed)
        #[arg(short, long)]
        all: bool,
    },
    /// Pull a model from Ollama registry
    Pull {
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
        /// Model to use for chat (default: qwen3:8b)
        #[arg(short, long, default_value = "qwen3:8b")]
        model: String,
    },
    /// Check AI service status and system info
    Status {
        /// Show detailed information
        #[arg(short, long)]
        verbose: bool,
    },
    /// Run model with custom parameters
    Run {
        model: String,
        /// System prompt
        #[arg(short, long)]
        system: Option<String>,
        /// Temperature (0.0-1.0)
        #[arg(short, long)]
        temp: Option<f32>,
    },
}

pub async fn execute(args: AiCommands) -> anyhow::Result<()> {
    match args {
        AiCommands::Start { model, enable } => start_ollama(model, enable).await,
        AiCommands::Stop => stop_ollama().await,
        AiCommands::Ask { prompt } => ask_ai(&prompt).await,
        AiCommands::Do { action } => do_action(&action).await,
        AiCommands::Models { all } => list_models(all).await,
        AiCommands::Pull { model, force } => pull_model(&model, force).await,
        AiCommands::Remove { model, yes } => remove_model(&model, yes).await,
        AiCommands::Chat { model } => interactive_chat(&model).await,
        AiCommands::Status { verbose } => check_status(verbose).await,
        AiCommands::Run { model, system, temp } => run_model(&model, system, temp).await,
    }
}

// ==================== COMMAND IMPLEMENTATIONS ====================

async fn start_ollama(model: Option<String>, enable: bool) -> anyhow::Result<()> {
    println!("{}", "🤖 Starting AI services...".bold().blue());
    println!();

    // Step 1: Check if Ollama is installed
    print!("Checking Ollama installation... ");
    let ollama_installed = Command::new("which")
        .arg("ollama")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if !ollama_installed {
        println!("{}", "✗".red());
        println!();
        println!("{}", "Ollama is not installed".red());
        println!();
        println!("Installing Ollama automatically...");
        println!("  {}", "sudo ollama-install.sh".cyan());
        println!();
        
        // Try to install
        match Command::new("sudo")
            .args(["/usr/local/bin/ollama-install.sh", "install"])
            .status() 
        {
            Ok(status) if status.success() => {
                println!("{}", "✓ Ollama installed successfully".green());
            }
            _ => {
                anyhow::bail!("Failed to install Ollama. Please install manually.");
            }
        }
    } else {
        println!("{}", "✓".green());
    }

    // Step 2: Check GPU availability
    print!("Checking GPU availability... ");
    let gpu_info = check_gpu();
    match &gpu_info {
        GpuInfo::Nvidia { name, vram } => {
            println!("{}", "✓".green());
            println!("  {} {} ({} MB VRAM)", "→".dimmed(), name, vram);
        }
        GpuInfo::Amd { name } => {
            println!("{}", "✓".green());
            println!("  {} {}", "→".dimmed(), name);
        }
        GpuInfo::Intel { name } => {
            println!("{}", "✓".green());
            println!("  {} {}", "→".dimmed(), name);
        }
        GpuInfo::None => {
            println!("{}", "⚠".yellow());
            println!("  {} No GPU detected - will use CPU mode", "→".dimmed());
        }
    }

    // Step 3: Check if Ollama service is already running
    print!("Checking Ollama service status... ");
    let service_running = is_ollama_running().await;
    
    if service_running {
        println!("{}", "✓".green());
        println!("  {} Ollama service is already running", "→".dimmed());
    } else {
        println!("{}", "⚠".yellow());
        println!("  {} Ollama service is not running", "→".dimmed());
        
        // Try to start the service
        println!();
        println!("Starting Ollama service...");
        
        let start_result = start_ollama_service().await;
        match start_result {
            Ok(_) => {
                println!("{}", "✓ Ollama service started".green());
            }
            Err(e) => {
                println!("{}", format!("✗ Failed to start service: {}", e).red());
                println!();
                println!("Try starting manually:");
                println!("  {}", "ollama serve".cyan());
                anyhow::bail!("Could not start Ollama service");
            }
        }
    }

    // Enable auto-start if requested
    if enable {
        print!("Enabling auto-start on boot... ");
        match Command::new("sudo")
            .args(["systemctl", "enable", "ollama.service"])
            .output() 
        {
            Ok(output) if output.status.success() => {
                println!("{}", "✓".green());
            }
            _ => {
                println!("{}", "⚠".yellow());
                println!("  {} Could not enable auto-start", "→".dimmed());
            }
        }
    }

    // Step 4: Verify connectivity
    print!("Verifying Ollama connectivity... ");
    match verify_ollama_connection().await {
        Ok(version) => {
            println!("{}", "✓".green());
            println!("  {} Version: {}", "→".dimmed(), version);
        }
        Err(e) => {
            println!("{}", "✗".red());
            println!("  {} Error: {}", "→".dimmed(), e);
        }
    }

    // Step 5: Preload model if requested
    if let Some(model_name) = model {
        println!();
        println!("{} Preloading model: {}", "→".dimmed(), model_name.cyan());
        match preload_model(&model_name).await {
            Ok(_) => println!("  {} Model ready", "✓".green()),
            Err(e) => println!("  {} Could not preload: {}", "⚠".yellow(), e),
        }
    }

    // Step 6: Check available models
    println!();
    println!("{}", "Installed Models:".bold());
    match list_ollama_models().await {
        Ok(models) if !models.is_empty() => {
            for model in models {
                println!("  • {}", model);
            }
        }
        Ok(_) => {
            println!("  {} No models installed", "⚠".yellow());
            println!();
            println!("Pull a model with:");
            println!("  {}", "life ai pull qwen3:8b".cyan());
        }
        Err(e) => {
            println!("  {} Could not list models: {}", "⚠".yellow(), e);
        }
    }

    println!();
    println!("{}", "✅ AI services ready".green().bold());
    println!();
    println!("Try: {} or {}", 
        "life ai chat".cyan(),
        "life ask 'hello'".cyan()
    );

    Ok(())
}

async fn stop_ollama() -> anyhow::Result<()> {
    println!("{}", "🛑 Stopping AI services...".bold().blue());
    
    match Command::new("sudo")
        .args(["systemctl", "stop", "ollama.service"])
        .output() 
    {
        Ok(output) if output.status.success() => {
            println!("{}", "✓ Ollama service stopped".green());
        }
        _ => {
            println!("{}", "⚠ Service may not be running".yellow());
        }
    }
    
    Ok(())
}

async fn ask_ai(prompt: &str) -> anyhow::Result<()> {
    // Ensure Ollama is running
    if !is_ollama_running().await {
        println!("Ollama is not running. Starting now...");
        start_ollama(None, false).await?;
    }

    let model = "qwen3:8b";
    
    println!("{} {}", "🤖".bold(), "Thinking...".dimmed());
    
    let client = reqwest::Client::new();
    let response = client
        .post("http://localhost:11434/api/generate")
        .json(&serde_json::json!({
            "model": model,
            "prompt": prompt,
            "stream": false
        }))
        .send()
        .await?;
    
    if response.status().is_success() {
        let json: serde_json::Value = response.json().await?;
        if let Some(text) = json.get("response").and_then(|r| r.as_str()) {
            println!("\n{}", text);
        }
    } else {
        anyhow::bail!("Failed to get response: {}", response.status());
    }
    
    Ok(())
}

async fn do_action(action: &str) -> anyhow::Result<()> {
    println!("{} {}", "🎯".bold(), format!("Executing: {}", action).cyan());
    
    // Use AI to interpret the action and generate a command
    let prompt = format!(
        "The user wants to: {}. \
         Generate a shell command to accomplish this. \
         Respond ONLY with the command, no explanation.",
        action
    );
    
    let client = reqwest::Client::new();
    let response = client
        .post("http://localhost:11434/api/generate")
        .json(&serde_json::json!({
            "model": "qwen3:8b",
            "prompt": prompt,
            "stream": false,
            "system": "You are a command generator. Output only the shell command, no markdown, no explanation."
        }))
        .send()
        .await?;
    
    if response.status().is_success() {
        let json: serde_json::Value = response.json().await?;
        if let Some(cmd) = json.get("response").and_then(|r| r.as_str()) {
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
    println!("{}", "📦 AI Models".bold().blue());
    println!();

    // Check if Ollama is running
    if !is_ollama_running().await {
        println!("{}", "⚠ Ollama is not running".yellow());
        println!("Start it with: {}", "life ai start".cyan());
        return Ok(());
    }

    // Fetch installed models
    match list_ollama_models_detailed().await {
        Ok(models) => {
            if models.is_empty() {
                println!("{}", "  No models installed".dimmed());
            } else {
                println!("{}", "Installed Models:".bold());
                println!("{:<20} {:>10} {:>12} {}", "Name", "Size", "Parameters", "Modified".dimmed());
                println!("{}", "─".repeat(70).dimmed());
                
                for model in models {
                    println!("{:<20} {:>10} {:>12} {}",
                        model.name.cyan(),
                        model.size,
                        model.parameter_size,
                        model.modified.dimmed()
                    );
                }
            }
        }
        Err(e) => {
            println!("{} Could not fetch models: {}", "✗".red(), e);
        }
    }

    if all {
        println!();
        println!("{}", "Available to Pull:".bold());
        let available = vec![
            ("qwen3:8b", "8B", "4.8GB", "Fast, efficient Chinese/English model"),
            ("llama3.2:3b", "3B", "2.0GB", "Lightweight, great for quick tasks"),
            ("llama3.2:1b", "1B", "1.3GB", "Ultra-lightweight for edge devices"),
            ("gemma2:2b", "2B", "1.6GB", "Google's efficient model"),
            ("phi3:medium", "14B", "7.9GB", "Microsoft's capable model"),
            ("mistral:7b", "7B", "4.1GB", "Strong general-purpose model"),
            ("codellama:7b", "7B", "3.8GB", "Optimized for code generation"),
            ("deepseek-coder:6.7b", "6.7B", "3.8GB", "Excellent coding assistant"),
        ];
        
        for (name, params, size, desc) in available {
            println!("  {:<20} {:>6} {:>8}  {}",
                name.cyan(),
                params.dimmed(),
                size.dimmed(),
                desc
            );
        }
    }

    println!();
    println!("Pull a model: {}", "life ai pull <model>".cyan());
    
    Ok(())
}

async fn pull_model(model: &str, force: bool) -> anyhow::Result<()> {
    println!("{}", format!("📥 Pulling model: {}", model).bold().blue());
    
    // Check if Ollama is running
    if !is_ollama_running().await {
        println!("Ollama is not running. Starting now...");
        start_ollama(None, false).await?;
    }

    // Check if model already exists
    if !force {
        match list_ollama_models().await {
            Ok(models) if models.contains(&model.to_string()) => {
                println!("{} Model {} already installed", "ℹ".blue(), model);
                println!("Use {} to re-download", "--force".cyan());
                return Ok(());
            }
            _ => {}
        }
    }

    // Pull with progress display
    println!("This may take several minutes depending on your connection...");
    println!();
    
    let mut child = tokio::process::Command::new("ollama")
        .args(["pull", model])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()?;

    // Stream output
    if let Some(stdout) = child.stdout.take() {
        use tokio::io::{AsyncBufReadExt, BufReader};
        let reader = BufReader::new(stdout);
        let mut lines = reader.lines();
        
        while let Some(line) = lines.next_line().await? {
            if line.contains("pulling") || line.contains("downloading") {
                print!("\r{} {}", "→".dimmed(), line);
                io::stdout().flush()?;
            }
        }
    }

    let status = child.wait().await?;
    println!(); // New line after progress

    if status.success() {
        println!("{}", format!("✅ Model {} pulled successfully", model).green());
        
        // Show model info
        if let Ok(info) = get_model_info(model).await {
            println!();
            println!("Model details:");
            println!("  Parameters: {}", info.parameter_size.dimmed());
            println!("  Size: {}", info.size.dimmed());
            println!("  Format: {}", info.format.dimmed());
        }
    } else {
        anyhow::bail!("Failed to pull model");
    }

    Ok(())
}

async fn remove_model(model: &str, yes: bool) -> anyhow::Result<()> {
    println!("{}", format!("🗑️  Removing model: {}", model).bold().yellow());
    
    // Confirm unless --yes
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
    
    let output = Command::new("ollama")
        .args(["rm", model])
        .output()?;
    
    if output.status.success() {
        println!("{}", format!("✅ Model {} removed", model).green());
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("Failed to remove model: {}", stderr);
    }
    
    Ok(())
}

async fn interactive_chat(model: &str) -> anyhow::Result<()> {
    // Ensure Ollama is running
    if !is_ollama_running().await {
        println!("Ollama is not running. Starting now...");
        start_ollama(None, false).await?;
    }

    // Check if model exists
    match list_ollama_models().await {
        Ok(models) if !models.contains(&model.to_string()) => {
            println!("Model {} not found. Pulling now...", model.cyan());
            pull_model(model, false).await?;
        }
        _ => {}
    }

    print!("{}\n", "─".repeat(60).dimmed());
    println!("{}  {}  {}", 
        "💬".bold(),
        format!("Chat with {}", model).bold().cyan(),
        "Type 'exit' or 'quit' to end"
    );
    print!("{}\n", "─".repeat(60).dimmed());

    let client = reqwest::Client::new();
    let mut history: Vec<String> = vec![];

    loop {
        print!("\n{} ", "You:".bold().green());
        io::stdout().flush()?;
        
        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        let input = input.trim();
        
        if input.eq_ignore_ascii_case("exit") || input.eq_ignore_ascii_case("quit") {
            println!("\n{} Goodbye!", "👋".bold());
            break;
        }
        
        if input.is_empty() {
            continue;
        }

        print!("\n{} ", "AI:".bold().cyan());
        io::stdout().flush()?;

        // Build context from history
        let context = if history.len() > 10 {
            // Keep last 10 exchanges
            history.truncate(history.len().saturating_sub(10));
            history.join("\n")
        } else {
            history.join("\n")
        };

        let full_prompt = if context.is_empty() {
            input.to_string()
        } else {
            format!("{context}\nHuman: {input}")
        };

        // Stream response
        let response = client
            .post("http://localhost:11434/api/generate")
            .json(&serde_json::json!({
                "model": model,
                "prompt": full_prompt,
                "stream": true
            }))
            .send()
            .await?;

        if response.status().is_success() {
            let mut full_response = String::new();
            let mut stream = response.bytes_stream();
            
            while let Some(chunk) = stream.next().await {
                if let Ok(bytes) = chunk {
                    if let Ok(text) = String::from_utf8(bytes.to_vec()) {
                        for line in text.lines() {
                            if let Ok(json) = serde_json::from_str::<serde_json::Value>(line) {
                                if let Some(token) = json.get("response").and_then(|r| r.as_str()) {
                                    print!("{}", token);
                                    io::stdout().flush()?;
                                    full_response.push_str(token);
                                }
                                if json.get("done").and_then(|d| d.as_bool()).unwrap_or(false) {
                                    break;
                                }
                            }
                        }
                    }
                }
            }
            
            println!();
            
            // Add to history
            history.push(format!("Human: {input}"));
            history.push(format!("Assistant: {full_response}"));
        }
    }

    Ok(())
}

async fn check_status(verbose: bool) -> anyhow::Result<()> {
    println!("{}", "🤖 AI Service Status".bold().blue());
    println!();

    // Installation status
    let installed = Command::new("which")
        .arg("ollama")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if installed {
        let version = Command::new("ollama")
            .arg("--version")
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|| "unknown".to_string());
        
        println!("  {} Ollama: {}", "✓".green(), version);
    } else {
        println!("  {} Ollama: not installed", "✗".red());
        println!();
        println!("Install with: {}", "sudo ollama-install.sh".cyan());
        return Ok(());
    }

    // Service status
    let running = is_ollama_running().await;
    if running {
        println!("  {} Service: {}", "✓".green(), "running".green());

        // Version from API
        if let Ok(version) = verify_ollama_connection().await {
            println!("  {} API Version: {}", "→".dimmed(), version);
        }
    } else {
        println!("  {} Service: {}", "✗".red(), "not running".red());
    }

    // GPU Info
    println!();
    println!("{}", "GPU Information:".bold());
    let gpu_info = check_gpu();
    match gpu_info {
        GpuInfo::Nvidia { name, vram } => {
            println!("  {} NVIDIA {}", "✓".green(), name);
            println!("    VRAM: {} MB", vram.to_string().cyan());
            
            if verbose {
                // Try to get more GPU details
                if let Ok(output) = Command::new("nvidia-smi")
                    .args(["--query-gpu=driver_version,temperature.gpu,utilization.gpu", "--format=csv,noheader"])
                    .output() 
                {
                    let info = String::from_utf8_lossy(&output.stdout);
                    let parts: Vec<&str> = info.split(',').collect();
                    if parts.len() >= 3 {
                        println!("    Driver: {}", parts[0].trim().cyan());
                        println!("    Temperature: {}°C", parts[1].trim().cyan());
                        println!("    Utilization: {}", parts[2].trim().cyan());
                    }
                }
            }
        }
        GpuInfo::Amd { name } => {
            println!("  {} AMD {}", "✓".green(), name);
        }
        GpuInfo::Intel { name } => {
            println!("  {} Intel {}", "✓".green(), name);
        }
        GpuInfo::None => {
            println!("  {} No GPU detected", "⚠".yellow());
            println!("    Running in CPU mode (slower)");
        }
    }

    // Models
    println!();
    println!("{}", "Models:".bold());
    match list_ollama_models_detailed().await {
        Ok(models) if !models.is_empty() => {
            for model in models {
                println!("  • {:<20} {:>10}",
                    model.name.cyan(),
                    model.size.dimmed()
                );
            }
        }
        Ok(_) => {
            println!("  {} No models installed", "→".dimmed());
        }
        Err(_) => {
            println!("  {} Cannot list models", "⚠".yellow());
        }
    }

    // Memory usage if verbose
    if verbose && running {
        println!();
        println!("{}", "Memory Usage:".bold());
        
        if let Ok(output) = Command::new("ps")
            .args(["-o", "pid,rss,comm", "-C", "ollama"])
            .output() 
        {
            let mem_info = String::from_utf8_lossy(&output.stdout);
            for line in mem_info.lines().skip(1) {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 3 {
                    let rss_kb: i64 = parts[1].parse().unwrap_or(0);
                    let rss_mb = rss_kb / 1024;
                    println!("  {} PID {}: {} MB", 
                        "→".dimmed(),
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

async fn run_model(model: &str, _system: Option<String>, temp: Option<f32>) -> anyhow::Result<()> {
    println!("{} Running: {}", "▶".bold().blue(), model.cyan());
    
    if !is_ollama_running().await {
        start_ollama(None, false).await?;
    }

    let args = vec!["run".to_string(), model.to_string()];
    
    // Ollama CLI doesn't directly support these flags, but we can use them
    // via environment variables or direct API calls
    
    let mut cmd = tokio::process::Command::new("ollama");
    cmd.args(&args);
    
    if let Some(t) = temp {
        cmd.env("OLLAMA_TEMPERATURE", t.to_string());
    }
    
    cmd.stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit());
    
    let mut child = cmd.spawn()?;
    child.wait().await?;
    
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

async fn is_ollama_running() -> bool {
    // Check via systemctl
    if let Ok(output) = Command::new("systemctl")
        .args(["is-active", "ollama"])
        .output() 
    {
        if output.status.success() {
            return true;
        }
    }

    // Check if port 11434 is listening
    if let Ok(output) = Command::new("ss")
        .args(["-tlnp"])
        .output() 
    {
        let output_str = String::from_utf8_lossy(&output.stdout);
        if output_str.contains(":11434") {
            return true;
        }
    }

    // Try HTTP check as fallback
    if let Ok(response) = reqwest::get("http://localhost:11434/api/version").await {
        return response.status().is_success();
    }

    false
}

async fn start_ollama_service() -> anyhow::Result<()> {
    // Try systemctl first
    let result = Command::new("sudo")
        .args(["systemctl", "start", "ollama"])
        .output();

    match result {
        Ok(output) if output.status.success() => {
            // Wait a moment for service to be ready
            tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
            Ok(())
        }
        _ => {
            anyhow::bail!("Failed to start service via systemctl");
        }
    }
}

async fn verify_ollama_connection() -> anyhow::Result<String> {
    let response = reqwest::get("http://localhost:11434/api/version")
        .await?;
    
    if !response.status().is_success() {
        anyhow::bail!("Ollama returned error: {}", response.status());
    }

    let json: serde_json::Value = response.json().await?;
    let version = json.get("version")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown");

    Ok(version.to_string())
}

async fn list_ollama_models() -> anyhow::Result<Vec<String>> {
    let response = reqwest::get("http://localhost:11434/api/tags")
        .await?;

    if !response.status().is_success() {
        anyhow::bail!("Failed to list models: {}", response.status());
    }

    let json: serde_json::Value = response.json().await?;
    let models = json.get("models")
        .and_then(|m| m.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|m| m.get("name").and_then(|n| n.as_str()).map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();

    Ok(models)
}

#[derive(Debug)]
struct ModelInfo {
    name: String,
    size: String,
    parameter_size: String,
    format: String,
    modified: String,
}

async fn list_ollama_models_detailed() -> anyhow::Result<Vec<ModelInfo>> {
    let response = reqwest::get("http://localhost:11434/api/tags")
        .await?;

    if !response.status().is_success() {
        anyhow::bail!("Failed to list models: {}", response.status());
    }

    let json: serde_json::Value = response.json().await?;
    let models = json.get("models")
        .and_then(|m| m.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|m| {
                    let name = m.get("name")?.as_str()?.to_string();
                    let size = format_size(m.get("size")?.as_u64()?);
                    let details = m.get("details")?;
                    let parameter_size = details.get("parameter_size")?.as_str()?.to_string();
                    let format = details.get("format")?.as_str()?.to_string();
                    let modified = m.get("modified_at")?.as_str()?.to_string();
                    // Truncate modified date
                    let modified = if modified.len() > 10 {
                        modified[..10].to_string()
                    } else {
                        modified
                    };
                    
                    Some(ModelInfo {
                        name,
                        size,
                        parameter_size,
                        format,
                        modified,
                    })
                })
                .collect()
        })
        .unwrap_or_default();

    Ok(models)
}

async fn get_model_info(model: &str) -> anyhow::Result<ModelInfo> {
    let response = reqwest::get("http://localhost:11434/api/tags")
        .await?;

    let json: serde_json::Value = response.json().await?;
    
    if let Some(models) = json.get("models").and_then(|m| m.as_array()) {
        for m in models {
            if let Some(name) = m.get("name").and_then(|n| n.as_str()) {
                if name == model {
                    let size = format_size(m.get("size").and_then(|s| s.as_u64()).unwrap_or(0));
                    let details = m.get("details").cloned().unwrap_or_default();
                    let parameter_size = details.get("parameter_size")
                        .and_then(|p| p.as_str())
                        .unwrap_or("unknown")
                        .to_string();
                    let format = details.get("format")
                        .and_then(|f| f.as_str())
                        .unwrap_or("unknown")
                        .to_string();
                    let modified = m.get("modified_at")
                        .and_then(|m| m.as_str())
                        .unwrap_or("unknown")
                        .to_string();
                    
                    return Ok(ModelInfo {
                        name: name.to_string(),
                        size,
                        parameter_size,
                        format,
                        modified,
                    });
                }
            }
        }
    }
    
    anyhow::bail!("Model not found")
}

async fn preload_model(model: &str) -> anyhow::Result<()> {
    let client = reqwest::Client::new();
    let _response = client
        .post("http://localhost:11434/api/generate")
        .json(&serde_json::json!({
            "model": model,
            "prompt": "",
            "keep_alive": "5m"
        }))
        .send()
        .await?;
    
    Ok(())
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
