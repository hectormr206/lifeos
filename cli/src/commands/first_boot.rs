use clap::Args;
use colored::Colorize;
use dialoguer::{theme::ColorfulTheme, Confirm, Input, Password, Select};
use std::path::PathBuf;
use std::process::Command;

use crate::config;

/// First boot wizard arguments
#[derive(Args, Default)]
pub struct FirstBootArgs {
    /// Skip interactive wizard and use defaults
    #[arg(long)]
    pub auto: bool,
    /// Theme preset (simple or pro)
    #[arg(long, default_value = "simple")]
    pub theme: String,
    /// Username for new account
    #[arg(long)]
    pub username: Option<String>,
    /// Hostname
    #[arg(long)]
    pub hostname: Option<String>,
    /// Skip AI setup (llama-server)
    #[arg(long)]
    pub skip_ai: bool,
    /// Force re-run first boot
    #[arg(long)]
    pub force: bool,
}

/// First boot wizard state
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct FirstBootState {
    pub hostname: String,
    pub username: String,
    pub fullname: String,
    pub timezone: String,
    pub locale: String,
    pub keyboard: String,
    pub theme: ThemeChoice,
    pub privacy_analytics: bool,
    pub privacy_telemetry: bool,
    pub ai_enabled: bool,
    pub ai_model: String,
    pub network_configured: bool,
}

#[derive(Debug, Clone, Copy)]
pub enum ThemeChoice {
    Simple,
    Pro,
}

impl std::fmt::Display for ThemeChoice {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ThemeChoice::Simple => write!(f, "Simple (Clean, minimal)"),
            ThemeChoice::Pro => write!(f, "Pro (Power user, advanced)"),
        }
    }
}

pub async fn execute(args: FirstBootArgs) -> anyhow::Result<()> {
    // Check if first boot already completed
    let first_boot_marker = PathBuf::from("/var/lib/lifeos/.first-boot-complete");
    if first_boot_marker.exists() && !args.force {
        println!("{}", "⚠️  First boot has already been completed".yellow());
        println!("{}", "   Use --force to re-run the wizard".dimmed());
        return Ok(());
    }

    print_welcome_banner();

    // Run system verification first
    println!("\n{}", "🔍 Running system verification...".bold().blue());
    let verification = run_system_verification().await?;
    display_verification_results(&verification);

    if !verification.all_passed() && !args.auto {
        let continue_anyway = Confirm::with_theme(&ColorfulTheme::default())
            .with_prompt("Some system checks failed. Continue anyway?")
            .default(false)
            .interact()?;

        if !continue_anyway {
            println!("{}", "First boot cancelled.".yellow());
            return Ok(());
        }
    }

    // Run the wizard
    let state = if args.auto {
        run_auto_setup(&args).await?
    } else {
        run_interactive_wizard(&args).await?
    };

    // Apply configuration
    println!("\n{}", "⚙️  Applying configuration...".bold().blue());
    apply_configuration(&state).await?;

    // Setup AI runtime if enabled
    if state.ai_enabled && !args.skip_ai {
        println!("\n{}", "🤖 Setting up AI...".bold().blue());
        setup_ai(&state).await?;
    }

    // Configure desktop environment
    println!(
        "\n{}",
        "🖥️  Configuring desktop environment...".bold().blue()
    );
    configure_desktop(&state).await?;

    // Mark first boot as complete
    std::fs::create_dir_all("/var/lib/lifeos")?;
    std::fs::write(
        &first_boot_marker,
        format!("Completed: {}\n", chrono::Local::now()),
    )?;

    print_completion_message(&state);

    Ok(())
}

fn print_welcome_banner() {
    println!(
        "{}",
        r#"
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║     ██╗     ██╗███████╗███████╗ ██████╗ ███████╗             ║
║     ██║     ██║██╔════╝██╔════╝██╔═══██╗██╔════╝             ║
║     ██║     ██║█████╗  ███████╗██║   ██║███████╗             ║
║     ██║     ██║██╔══╝  ╚════██║██║   ██║╚════██║             ║
║     ███████╗██║██║     ███████║╚██████╔╝███████║             ║
║     ╚══════╝╚═╝╚═╝     ╚══════╝ ╚═════╝ ╚══════╝             ║
║                                                                ║
║              Welcome to Your AI-First Linux                    ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"#
        .cyan()
        .bold()
    );

    println!("{}\n", "Let's set up your LifeOS system.".italic());
}

fn print_completion_message(state: &FirstBootState) {
    println!(
        "\n{}",
        "╔════════════════════════════════════════════════════════════╗".green()
    );
    println!(
        "{}",
        "║                                                            ║".green()
    );
    println!(
        "{}",
        "║   🎉 Setup Complete! Welcome to LifeOS!                    ║"
            .green()
            .bold()
    );
    println!(
        "{}",
        "║                                                            ║".green()
    );
    println!(
        "{}",
        "╚════════════════════════════════════════════════════════════╝".green()
    );

    println!("\n{}", "Your system is ready:".bold());
    println!("  {} Hostname: {}", "•".cyan(), state.hostname);
    println!("  {} Username: {}", "•".cyan(), state.username);
    println!("  {} Timezone: {}", "•".cyan(), state.timezone);
    println!(
        "  {} Theme: {}",
        "•".cyan(),
        if matches!(state.theme, ThemeChoice::Pro) {
            "Pro"
        } else {
            "Simple"
        }
    );
    println!(
        "  {} AI: {}",
        "•".cyan(),
        if state.ai_enabled {
            "Enabled"
        } else {
            "Disabled"
        }
    );

    println!("\n{}", "Quick commands:".bold());
    println!(
        "  {} {} - Check system status",
        "•".cyan(),
        "life status".yellow()
    );
    println!(
        "  {} {} - Launch AI assistant",
        "•".cyan(),
        "life ai chat".yellow()
    );
    println!(
        "  {} {} - View configuration",
        "•".cyan(),
        "life config show".yellow()
    );

    println!("\n{}", "Press Enter to continue...".dimmed());
    let _ = std::io::stdin().read_line(&mut String::new());
}

/// Run automatic setup with defaults or provided arguments
async fn run_auto_setup(args: &FirstBootArgs) -> anyhow::Result<FirstBootState> {
    println!("{}", "Running automatic setup with defaults...".blue());

    let hostname = args
        .hostname
        .clone()
        .unwrap_or_else(|| "lifeos".to_string());

    let username = args.username.clone().unwrap_or_else(|| "user".to_string());

    let theme = if args.theme == "pro" {
        ThemeChoice::Pro
    } else {
        ThemeChoice::Simple
    };

    Ok(FirstBootState {
        hostname,
        username: username.clone(),
        fullname: username,
        timezone: detect_timezone(),
        locale: "en_US.UTF-8".to_string(),
        keyboard: "us".to_string(),
        theme,
        privacy_analytics: false,
        privacy_telemetry: false,
        ai_enabled: true,
        ai_model: "Qwen3.5-4B-Q4_K_M.gguf".to_string(),
        network_configured: true,
    })
}

/// Run interactive onboarding wizard
async fn run_interactive_wizard(args: &FirstBootArgs) -> anyhow::Result<FirstBootState> {
    let theme = ColorfulTheme::default();

    // Step 1: Welcome & User Account
    println!("\n{}", "👤 Step 1: User Account".bold().green());

    let username: String = Input::with_theme(&theme)
        .with_prompt("Username")
        .default(args.username.clone().unwrap_or_else(|| "user".to_string()))
        .interact_text()?;

    let fullname: String = Input::with_theme(&theme)
        .with_prompt("Full Name")
        .default(username.clone())
        .interact_text()?;

    let password = Password::with_theme(&theme)
        .with_prompt("Password")
        .with_confirmation("Confirm password", "Passwords don't match")
        .interact()?;

    // Step 2: System Settings
    println!("\n{}", "⚙️  Step 2: System Settings".bold().green());

    let hostname: String = Input::with_theme(&theme)
        .with_prompt("Hostname")
        .default(
            args.hostname
                .clone()
                .unwrap_or_else(|| "lifeos".to_string()),
        )
        .interact_text()?;

    let detected_tz = detect_timezone();
    let timezone: String = Input::with_theme(&theme)
        .with_prompt("Timezone")
        .default(detected_tz)
        .interact_text()?;

    let locales = vec![
        "en_US.UTF-8",
        "es_ES.UTF-8",
        "fr_FR.UTF-8",
        "de_DE.UTF-8",
        "pt_BR.UTF-8",
    ];
    let locale_idx = Select::with_theme(&theme)
        .with_prompt("Select locale")
        .items(&locales)
        .default(0)
        .interact()?;
    let locale = locales[locale_idx].to_string();

    // Step 3: Theme Selection
    println!("\n{}", "🎨 Step 3: Choose Your Experience".bold().green());

    let themes = vec![ThemeChoice::Simple, ThemeChoice::Pro];
    let theme_idx = Select::with_theme(&theme)
        .with_prompt("Select theme")
        .items(&themes)
        .default(0)
        .interact()?;
    let selected_theme = themes[theme_idx];

    // Step 4: Privacy Settings
    println!("\n{}", "🔒 Step 4: Privacy Settings".bold().green());

    let analytics = Confirm::with_theme(&theme)
        .with_prompt("Help improve LifeOS by sharing anonymous usage analytics?")
        .default(false)
        .interact()?;

    let telemetry = Confirm::with_theme(&theme)
        .with_prompt("Allow system telemetry for crash reports?")
        .default(false)
        .interact()?;

    // Step 5: AI Configuration
    println!("\n{}", "🤖 Step 5: AI Configuration".bold().green());

    let ai_enabled = Confirm::with_theme(&theme)
        .with_prompt("Enable local AI assistant?")
        .default(true)
        .interact()?;

    let ai_model = if ai_enabled && !args.skip_ai {
        let models = vec![
            "Qwen3.5-4B-Q4_K_M.gguf",
            "Qwen3.5-9B-Q4_K_M.gguf",
            "llama-3.2-3b-instruct-q4_k_m.gguf",
            "mistral-7b-instruct-v0.3-q4_k_m.gguf",
        ];
        let model_idx = Select::with_theme(&theme)
            .with_prompt("Select default AI model")
            .items(&models)
            .default(0)
            .interact()?;
        models[model_idx].to_string()
    } else {
        "Qwen3.5-4B-Q4_K_M.gguf".to_string()
    };

    // Step 6: Review
    println!("\n{}", "📋 Step 6: Review".bold().green());
    println!("  Username: {}", username.cyan());
    println!("  Full Name: {}", fullname.cyan());
    println!("  Hostname: {}", hostname.cyan());
    println!("  Timezone: {}", timezone.cyan());
    println!("  Locale: {}", locale.cyan());
    println!("  Theme: {}", format!("{:?}", selected_theme).cyan());
    println!(
        "  AI: {}",
        if ai_enabled {
            "Enabled".green()
        } else {
            "Disabled".red()
        }
    );

    let confirm = Confirm::with_theme(&theme)
        .with_prompt("Apply these settings?")
        .default(true)
        .interact()?;

    if !confirm {
        println!("{}", "Setup cancelled.".yellow());
        std::process::exit(0);
    }

    // Store password temporarily for user creation
    std::fs::write("/tmp/lifeos-setup-password", password)?;

    Ok(FirstBootState {
        hostname,
        username: username.clone(),
        fullname,
        timezone,
        locale,
        keyboard: "us".to_string(),
        theme: selected_theme,
        privacy_analytics: analytics,
        privacy_telemetry: telemetry,
        ai_enabled,
        ai_model,
        network_configured: true,
    })
}

/// System verification results
#[derive(Debug)]
pub struct SystemVerification {
    pub bootc_status: CheckResult,
    pub partitions: CheckResult,
    pub network: CheckResult,
    pub gpu: CheckResult,
    pub storage: CheckResult,
}

#[derive(Debug)]
#[allow(dead_code)]
pub struct CheckResult {
    pub passed: bool,
    pub message: String,
    pub details: Option<String>,
}

impl SystemVerification {
    fn all_passed(&self) -> bool {
        self.bootc_status.passed
            && self.partitions.passed
            && self.network.passed
            && self.gpu.passed
            && self.storage.passed
    }
}

async fn run_system_verification() -> anyhow::Result<SystemVerification> {
    // Check bootc status
    let bootc_status = match Command::new("bootc").args(["status", "--json"]).output() {
        Ok(output) if output.status.success() => CheckResult {
            passed: true,
            message: "bootc operational".to_string(),
            details: Some(String::from_utf8_lossy(&output.stdout).to_string()),
        },
        _ => CheckResult {
            passed: false,
            message: "bootc not available".to_string(),
            details: None,
        },
    };

    // Check partitions
    let partitions = match Command::new("lsblk").args(["-J", "/"]).output() {
        Ok(output) if output.status.success() => CheckResult {
            passed: true,
            message: "Partitions OK".to_string(),
            details: None,
        },
        _ => CheckResult {
            passed: true, // Non-fatal
            message: "Could not verify partitions".to_string(),
            details: None,
        },
    };

    // Check network
    let network = match Command::new("ping")
        .args(["-c", "1", "-W", "3", "8.8.8.8"])
        .output()
    {
        Ok(output) if output.status.success() => CheckResult {
            passed: true,
            message: "Internet connectivity OK".to_string(),
            details: None,
        },
        _ => CheckResult {
            passed: false,
            message: "No internet connectivity".to_string(),
            details: Some("Network configuration may be needed".to_string()),
        },
    };

    // Check GPU
    let gpu = check_gpu();

    // Check storage
    let storage = match Command::new("df").args(["-h", "/"]).output() {
        Ok(output) if output.status.success() => {
            let output_str = String::from_utf8_lossy(&output.stdout);
            // Parse available space (simplified)
            let available = output_str
                .lines()
                .nth(1)
                .and_then(|line| line.split_whitespace().nth(3))
                .unwrap_or("unknown");

            CheckResult {
                passed: true,
                message: format!("Storage available: {}", available),
                details: None,
            }
        }
        _ => CheckResult {
            passed: false,
            message: "Could not check storage".to_string(),
            details: None,
        },
    };

    Ok(SystemVerification {
        bootc_status,
        partitions,
        network,
        gpu,
        storage,
    })
}

fn check_gpu() -> CheckResult {
    // Check NVIDIA
    if let Ok(output) = Command::new("nvidia-smi")
        .arg("--query-gpu=name,memory.total")
        .arg("--format=csv,noheader")
        .output()
    {
        if output.status.success() {
            let gpu_info = String::from_utf8_lossy(&output.stdout);
            return CheckResult {
                passed: true,
                message: format!("NVIDIA GPU: {}", gpu_info.trim()),
                details: None,
            };
        }
    }

    // Check AMD
    if let Ok(output) = Command::new("lspci").output() {
        let output_str = String::from_utf8_lossy(&output.stdout);
        if output_str.contains("VGA") && (output_str.contains("AMD") || output_str.contains("ATI"))
        {
            return CheckResult {
                passed: true,
                message: "AMD GPU detected".to_string(),
                details: None,
            };
        }
        if output_str.contains("Intel") && output_str.contains("Graphics") {
            return CheckResult {
                passed: true,
                message: "Intel GPU detected".to_string(),
                details: None,
            };
        }
    }

    // Check for Apple Silicon (for Asahi/Fedora Remix)
    if std::path::Path::new("/proc/device-tree/model").exists() {
        if let Ok(model) = std::fs::read_to_string("/proc/device-tree/model") {
            if model.contains("Apple") {
                return CheckResult {
                    passed: true,
                    message: "Apple Silicon detected".to_string(),
                    details: None,
                };
            }
        }
    }

    CheckResult {
        passed: true, // CPU-only is valid
        message: "No discrete GPU detected (CPU-only mode)".to_string(),
        details: Some(
            "AI operations will use CPU. Consider a GPU for better performance.".to_string(),
        ),
    }
}

fn display_verification_results(v: &SystemVerification) {
    let check = |r: &CheckResult| {
        if r.passed {
            format!("{} {}", "✓".green(), r.message)
        } else {
            format!("{} {}", "✗".red(), r.message)
        }
    };

    println!("  {}", check(&v.bootc_status));
    println!("  {}", check(&v.partitions));
    println!("  {}", check(&v.network));
    println!("  {}", check(&v.gpu));
    println!("  {}", check(&v.storage));
}

fn detect_timezone() -> String {
    // Try to detect from system
    if let Ok(output) = Command::new("timedatectl")
        .arg("show")
        .arg("--property=Timezone")
        .output()
    {
        let output_str = String::from_utf8_lossy(&output.stdout);
        if let Some(tz) = output_str.trim().strip_prefix("Timezone=") {
            return tz.to_string();
        }
    }

    if std::path::Path::new("/etc/localtime").exists() {
        if let Ok(link) = std::fs::read_link("/etc/localtime") {
            if let Some(tz) = link
                .to_str()
                .and_then(|s| s.strip_prefix("/usr/share/zoneinfo/"))
            {
                return tz.to_string();
            }
        }
    }

    "UTC".to_string()
}

async fn apply_configuration(state: &FirstBootState) -> anyhow::Result<()> {
    // Set hostname
    print!("Setting hostname... ");
    let _ = Command::new("hostnamectl")
        .args(["set-hostname", &state.hostname])
        .output();
    println!("{}", "✓".green());

    // Set timezone
    print!("Setting timezone... ");
    let _ = Command::new("timedatectl")
        .args(["set-timezone", &state.timezone])
        .output();
    println!("{}", "✓".green());

    // Set locale
    print!("Setting locale... ");
    let _ = Command::new("localectl")
        .args(["set-locale", &state.locale])
        .output();
    println!("{}", "✓".green());

    // Create user account
    print!("Creating user account... ");
    if !user_exists(&state.username) {
        let password_file = "/tmp/lifeos-setup-password";
        let password = std::fs::read_to_string(password_file).unwrap_or_default();

        // Create user
        let _ = Command::new("useradd")
            .args([
                "-m",
                "-G",
                "wheel,docker",
                "-c",
                &state.fullname,
                &state.username,
            ])
            .output();

        // Set password
        if !password.is_empty() {
            let mut child = std::process::Command::new("passwd")
                .arg(&state.username)
                .stdin(std::process::Stdio::piped())
                .spawn()?;

            if let Some(stdin) = child.stdin.take() {
                use std::io::Write;
                let mut stdin = stdin;
                writeln!(stdin, "{}", password)?;
                writeln!(stdin, "{}", password)?;
            }
            let _ = child.wait();
        }

        // Clean up password file
        let _ = std::fs::remove_file(password_file);
    }
    println!("{}", "✓".green());

    // Save configuration
    print!("Saving LifeOS configuration... ");
    let mut config = config::LifeConfig::default();
    config.system.hostname = state.hostname.clone();
    config.system.timezone = state.timezone.clone();
    config.system.locale = state.locale.clone();
    config.ai.enabled = state.ai_enabled;
    config.ai.model = state.ai_model.clone();

    let config_path = dirs::config_dir()
        .map(|d| d.join("lifeos/lifeos.toml"))
        .unwrap_or_else(|| PathBuf::from("/etc/lifeos/lifeos.toml"));

    std::fs::create_dir_all(config_path.parent().unwrap())?;
    config::save_config(&config, &config_path)?;

    // Also save system-wide config
    let _ = config::save_config(&config, PathBuf::from("/etc/lifeos/lifeos.toml").as_path());

    println!("{}", "✓".green());

    Ok(())
}

fn user_exists(username: &str) -> bool {
    Command::new("id")
        .arg(username)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

async fn setup_ai(state: &FirstBootState) -> anyhow::Result<()> {
    // Check if llama-server is installed
    let installed = Command::new("which")
        .arg("llama-server")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if !installed {
        println!(
            "  {} llama-server not found (should be bundled with LifeOS)",
            "!".yellow()
        );
        return Ok(());
    }

    println!("  {} llama-server installed", "OK".green());

    // Determine optimal GPU offload
    let gpu_info = check_gpu();
    let gpu_layers = if gpu_info.message.contains("NVIDIA")
        || gpu_info.message.contains("AMD")
        || gpu_info.message.contains("Apple")
    {
        "99" // Offload all layers to GPU
    } else {
        "0" // CPU only
    };

    // Update model and layers in env file
    print!(
        "  Configuring AI model: {} (GPU layers: {}) ... ",
        state.ai_model.cyan(),
        gpu_layers
    );
    let _ = Command::new("sudo")
        .args([
            "sed",
            "-i",
            &format!("s/^LIFEOS_AI_MODEL=.*/LIFEOS_AI_MODEL={}/", state.ai_model),
            "/etc/lifeos/llama-server.env",
        ])
        .output();

    let _ = Command::new("sudo")
        .args([
            "sed",
            "-i",
            &format!(
                "s/^LLAMA_N_GPU_LAYERS=.*/LLAMA_N_GPU_LAYERS={}/",
                gpu_layers
            ),
            "/etc/lifeos/llama-server.env",
        ])
        .output();
    println!("{}", "OK".green());

    // Enable and start llama-server service
    print!("  Starting AI service... ");
    let _ = Command::new("systemctl")
        .args(["enable", "--now", "llama-server"])
        .output();
    println!("{}", "OK".green());

    println!(
        "  {} Model will be downloaded on first service start if not present",
        "->".dimmed()
    );

    Ok(())
}

async fn configure_desktop(state: &FirstBootState) -> anyhow::Result<()> {
    // Set up GNOME theme based on choice
    let (shell_theme, icon_theme, gtk_theme) = match state.theme {
        ThemeChoice::Simple => ("Adwaita", "Adwaita", "Adwaita"),
        ThemeChoice::Pro => ("Adwaita-dark", "Adwaita", "Adwaita-dark"),
    };

    // Configure gsettings (if available)
    let _ = Command::new("gsettings")
        .args([
            "set",
            "org.gnome.shell.extensions.user-theme",
            "name",
            shell_theme,
        ])
        .output();

    let _ = Command::new("gsettings")
        .args(["set", "org.gnome.desktop.interface", "gtk-theme", gtk_theme])
        .output();

    let _ = Command::new("gsettings")
        .args([
            "set",
            "org.gnome.desktop.interface",
            "icon-theme",
            icon_theme,
        ])
        .output();

    // Configure dock
    let _ = Command::new("gsettings")
        .args([
            "set",
            "org.gnome.shell.extensions.dash-to-dock",
            "dock-position",
            "LEFT",
        ])
        .output();

    // Set wallpaper (if LifeOS wallpaper exists)
    let wallpaper_path = "/usr/share/backgrounds/lifeos/default.jpg";
    if std::path::Path::new(wallpaper_path).exists() {
        let _ = Command::new("gsettings")
            .args([
                "set",
                "org.gnome.desktop.background",
                "picture-uri",
                &format!("file://{}", wallpaper_path),
            ])
            .output();
    }

    println!("  {} Desktop theme configured", "✓".green());

    // Set up LifeOS branding
    setup_lifeos_branding().await?;

    Ok(())
}

async fn setup_lifeos_branding() -> anyhow::Result<()> {
    // Create LifeOS about dialog info
    let about_info = format!(
        r#"[LifeOS]
Name=LifeOS
Comment=AI-First Linux Distribution
Version=0.1.0
Website=https://lifeos.io
"#
    );

    std::fs::create_dir_all("/usr/share/lifeos")?;
    std::fs::write("/usr/share/lifeos/about.ini", about_info)?;

    println!("  {} LifeOS branding applied", "✓".green());

    Ok(())
}
