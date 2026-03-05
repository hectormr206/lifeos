use clap::{Subcommand, ValueEnum};
use colored::Colorize;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

#[derive(Subcommand)]
pub enum ThemeCommands {
    /// Show current theme status
    Status,
    /// Switch theme mode
    #[command(subcommand)]
    Mode(ModeCommands),
    /// Switch theme variant (Simple/Pro)
    #[command(subcommand)]
    Variant(VariantCommands),
    /// Manage wallpapers
    #[command(subcommand)]
    Wallpaper(WallpaperCommands),
    /// Set accent color
    Accent {
        /// Color name or hex code
        color: Option<String>,
        /// List available colors
        #[arg(short, long)]
        list: bool,
    },
    /// Configure dark/light mode
    Appearance {
        /// Set dark mode
        #[arg(short, long)]
        dark: bool,
        /// Set light mode
        #[arg(short, long)]
        light: bool,
        /// Follow system preference
        #[arg(short, long)]
        auto: bool,
    },
    /// List available themes
    List,
    /// Preview theme combinations
    Preview {
        /// Theme variant to preview
        #[arg(value_enum)]
        variant: Option<ThemeVariant>,
    },
    /// Import/export theme configuration
    #[command(subcommand)]
    Config(ConfigCommands),
}

#[derive(Subcommand)]
pub enum ModeCommands {
    /// Set dark mode
    Dark,
    /// Set light mode
    Light,
    /// Follow system preference
    Auto,
}

#[derive(Subcommand)]
pub enum VariantCommands {
    /// Use Simple theme (minimal, clean)
    Simple,
    /// Use Pro theme (feature-rich, advanced)
    Pro,
}

#[derive(Subcommand)]
pub enum WallpaperCommands {
    /// Set wallpaper from file or URL
    Set {
        /// Path to image file or URL
        path: String,
        /// Set for lock screen
        #[arg(short, long)]
        lock: bool,
        /// Set for both desktop and lock
        #[arg(short, long)]
        both: bool,
    },
    /// Get current wallpaper
    Get,
    /// List available wallpapers
    List {
        /// Show all system wallpapers
        #[arg(short, long)]
        all: bool,
    },
    /// Download wallpaper from URL
    Download {
        /// URL to download
        url: String,
        /// Save as name
        #[arg(short, long)]
        name: Option<String>,
    },
    /// Cycle through wallpapers
    Cycle {
        /// Interval in seconds
        #[arg(short, long, default_value = "300")]
        interval: u64,
        /// Directory to cycle from
        #[arg(short, long)]
        directory: Option<PathBuf>,
    },
}

#[derive(Subcommand)]
pub enum ConfigCommands {
    /// Export theme configuration
    Export {
        /// Output file path
        #[arg(default_value = "lifeos-theme.json")]
        path: PathBuf,
    },
    /// Import theme configuration
    Import {
        /// Input file path
        path: PathBuf,
    },
    /// Reset to defaults
    Reset,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
pub enum ThemeVariant {
    Simple,
    Pro,
}

#[derive(Debug, Serialize, Deserialize)]
struct ThemeConfig {
    variant: String,
    mode: String,
    accent_color: String,
    wallpaper: WallpaperConfig,
    appearance: AppearanceConfig,
}

#[derive(Debug, Serialize, Deserialize)]
struct WallpaperConfig {
    desktop: String,
    lock: String,
    mode: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct AppearanceConfig {
    dark_mode: bool,
    follow_system: bool,
    contrast: String,
}

impl Default for ThemeConfig {
    fn default() -> Self {
        Self {
            variant: "simple".to_string(),
            mode: "auto".to_string(),
            accent_color: "blue".to_string(),
            wallpaper: WallpaperConfig {
                desktop: "/usr/share/backgrounds/lifeos/default.jpg".to_string(),
                lock: "/usr/share/backgrounds/lifeos/lock-default.jpg".to_string(),
                mode: "zoom".to_string(),
            },
            appearance: AppearanceConfig {
                dark_mode: true,
                follow_system: true,
                contrast: "default".to_string(),
            },
        }
    }
}

pub async fn execute(args: ThemeCommands) -> anyhow::Result<()> {
    match args {
        ThemeCommands::Status => show_status().await,
        ThemeCommands::Mode(mode) => set_mode(mode).await,
        ThemeCommands::Variant(variant) => set_variant(variant).await,
        ThemeCommands::Wallpaper(cmd) => manage_wallpaper(cmd).await,
        ThemeCommands::Accent { color, list } => set_accent(color.as_deref(), list).await,
        ThemeCommands::Appearance { dark, light, auto } => set_appearance(dark, light, auto).await,
        ThemeCommands::List => list_themes().await,
        ThemeCommands::Preview { variant } => preview_theme(variant).await,
        ThemeCommands::Config(cmd) => manage_config(cmd).await,
    }
}

// ==================== COMMAND IMPLEMENTATIONS ====================

async fn show_status() -> anyhow::Result<()> {
    println!("{}", "🎨 LifeOS Theme Status".bold().blue());
    println!();

    let config = load_config().unwrap_or_default();

    // Current variant
    let variant_icon = match config.variant.as_str() {
        "simple" => "✨",
        "pro" => "🚀",
        _ => "🎨",
    };
    println!(
        "{} {} {}",
        variant_icon,
        "Variant:".bold(),
        config.variant.to_uppercase().cyan()
    );

    // Current mode
    let mode_icon = if config.appearance.dark_mode {
        "🌙"
    } else {
        "☀️"
    };
    let mode_text = if config.appearance.follow_system {
        "Auto (follows system)"
    } else if config.appearance.dark_mode {
        "Dark"
    } else {
        "Light"
    };
    println!("{} {} {}", mode_icon, "Mode:".bold(), mode_text.cyan());

    // Accent color
    let accent_emoji = accent_emoji(&config.accent_color);
    println!(
        "{} {} {}",
        accent_emoji,
        "Accent:".bold(),
        config.accent_color.cyan()
    );

    // Wallpaper
    println!(
        "🖼️ {} {}",
        "Wallpaper:".bold(),
        shorten_path(&config.wallpaper.desktop).cyan()
    );

    println!();
    println!("Quick commands:");
    println!(
        "  Switch variant:  {}",
        "life theme variant simple|pro".cyan()
    );
    println!(
        "  Change mode:     {}",
        "life theme mode dark|light|auto".cyan()
    );
    println!("  Set accent:      {}", "life theme accent blue".cyan());
    println!(
        "  Set wallpaper:   {}",
        "life theme wallpaper set ~/image.jpg".cyan()
    );

    Ok(())
}

async fn set_mode(mode: ModeCommands) -> anyhow::Result<()> {
    let (mode_str, dark, follow_system) = match mode {
        ModeCommands::Dark => ("dark", true, false),
        ModeCommands::Light => ("light", false, false),
        ModeCommands::Auto => ("auto", false, true),
    };

    println!(
        "{}",
        format!("🌓 Setting {} mode...", mode_str).bold().blue()
    );

    // Update config
    let mut config = load_config().unwrap_or_default();
    config.mode = mode_str.to_string();
    config.appearance.dark_mode = dark;
    config.appearance.follow_system = follow_system;
    save_config(&config)?;

    // Apply to system
    apply_mode(dark, follow_system).await?;

    println!("{}", format!("✅ {} mode applied", mode_str).green());

    Ok(())
}

async fn set_variant(variant: VariantCommands) -> anyhow::Result<()> {
    let variant_str = match variant {
        VariantCommands::Simple => "simple",
        VariantCommands::Pro => "pro",
    };

    let icon = if variant_str == "simple" {
        "✨"
    } else {
        "🚀"
    };
    println!(
        "{}",
        format!(
            "{} Switching to {} theme...",
            icon,
            variant_str.to_uppercase()
        )
        .bold()
        .blue()
    );

    // Update config
    let mut config = load_config().unwrap_or_default();
    config.variant = variant_str.to_string();
    save_config(&config)?;

    // Apply variant
    apply_variant(variant_str).await?;

    let description = if variant_str == "simple" {
        "Clean, minimal interface optimized for focus"
    } else {
        "Feature-rich interface with advanced tools and panels"
    };

    println!("{}", format!("✅ {} theme applied", variant_str).green());
    println!();
    println!("{}", description.dimmed());

    Ok(())
}

async fn manage_wallpaper(cmd: WallpaperCommands) -> anyhow::Result<()> {
    match cmd {
        WallpaperCommands::Set { path, lock, both } => {
            println!("{}", "🖼️  Setting wallpaper...".to_string().bold().blue());

            let path_expanded = shellexpand::tilde(&path).to_string();
            let path_for_config = path_expanded.clone();

            // Validate file exists (if local path)
            if !path.starts_with("http") && !std::path::Path::new(&path_expanded).exists() {
                anyhow::bail!("Wallpaper file not found: {}", path);
            }

            let mut config = load_config().unwrap_or_default();

            if both {
                config.wallpaper.desktop = path_for_config.clone();
                config.wallpaper.lock = path_for_config;
                set_wallpaper_gnome(&path_expanded, true).await?;
                set_wallpaper_gnome(&path_expanded, false).await?;
                println!("✅ Wallpaper set for desktop and lock screen");
            } else if lock {
                config.wallpaper.lock = path_for_config.clone();
                set_wallpaper_gnome(&path_expanded, false).await?;
                println!("✅ Lock screen wallpaper set");
            } else {
                config.wallpaper.desktop = path_for_config;
                set_wallpaper_gnome(&path_expanded, true).await?;
                println!("✅ Desktop wallpaper set");
            }

            save_config(&config)?;
        }
        WallpaperCommands::Get => {
            let config = load_config().unwrap_or_default();
            println!("{}", "🖼️  Current Wallpaper".bold().blue());
            println!();
            println!("{} {}", "Desktop:".bold(), config.wallpaper.desktop.cyan());
            println!("{} {}", "Lock:".bold(), config.wallpaper.lock.cyan());
        }
        WallpaperCommands::List { all } => {
            println!("{}", "🖼️  Available Wallpapers".bold().blue());
            println!();

            let dirs = if all {
                vec![
                    "/usr/share/backgrounds",
                    "/usr/share/backgrounds/gnome",
                    "/usr/share/backgrounds/lifeos",
                ]
            } else {
                vec!["/usr/share/backgrounds/lifeos"]
            };

            for dir in dirs {
                if std::path::Path::new(dir).exists() {
                    println!("{}/:", dir.dimmed());

                    if let Ok(entries) = fs::read_dir(dir) {
                        for entry in entries.flatten() {
                            if let Some(name) = entry.file_name().to_str() {
                                if name.ends_with(".jpg") || name.ends_with(".png") {
                                    println!("  • {}", name.cyan());
                                }
                            }
                        }
                    }
                    println!();
                }
            }

            println!(
                "Set wallpaper: {}",
                "life theme wallpaper set /path/to/image.jpg".cyan()
            );
        }
        WallpaperCommands::Download { url, name } => {
            println!(
                "{}",
                "⬇️  Downloading wallpaper...".to_string().bold().blue()
            );

            let filename = name.unwrap_or_else(|| {
                url.split('/')
                    .next_back()
                    .unwrap_or("wallpaper.jpg")
                    .to_string()
            });

            let wallpaper_dir = dirs::home_dir()
                .map(|h| h.join("Pictures/Wallpapers"))
                .unwrap_or_else(|| PathBuf::from("~/Pictures/Wallpapers"));

            fs::create_dir_all(&wallpaper_dir)?;

            let output_path = wallpaper_dir.join(&filename);

            // Download
            let status = std::process::Command::new("curl")
                .args(["-L", &url, "-o", output_path.to_str().unwrap()])
                .status()?;

            if status.success() {
                println!(
                    "{}",
                    format!("✅ Downloaded to: {}", output_path.display()).green()
                );
                println!(
                    "Set with: {}",
                    format!("life theme wallpaper set {}", output_path.display()).cyan()
                );
            } else {
                anyhow::bail!("Download failed");
            }
        }
        WallpaperCommands::Cycle {
            interval,
            directory,
        } => {
            println!(
                "{}",
                format!("🔄 Wallpaper cycling every {} seconds", interval)
                    .bold()
                    .blue()
            );
            println!();
            if let Some(dir) = directory {
                println!("Directory: {}", dir.display().to_string().cyan());
                println!();
            }
            println!("To set up automatic cycling, add this to your crontab:");
            println!("  {} {}", 
                format!("*/{} * * * *", interval / 60).cyan(),
                "export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id - u)/bus; life theme wallpaper cycle".dimmed()
            );
            println!();
            println!("Or set up a systemd timer.");
        }
    }

    Ok(())
}

async fn set_accent(color: Option<&str>, list: bool) -> anyhow::Result<()> {
    let colors = vec![
        ("blue", "🔵", "Classic LifeOS blue"),
        ("purple", "🟣", "Creative purple"),
        ("pink", "🩷", "Playful pink"),
        ("red", "🔴", "Energetic red"),
        ("orange", "🟠", "Warm orange"),
        ("yellow", "🟡", "Sunny yellow"),
        ("green", "🟢", "Natural green"),
        ("teal", "🩵", "Calm teal"),
        ("gray", "⚪", "Neutral gray"),
    ];

    if list {
        println!("{}", "🎨 Available Accent Colors".bold().blue());
        println!();

        for (name, emoji, desc) in colors {
            println!("{} {:<10} {}", emoji, name.cyan(), desc.dimmed());
        }

        println!();
        println!("Set with: {}", "life theme accent <color>".cyan());
        return Ok(());
    }

    let color_name = match color {
        Some(c) => c.to_lowercase(),
        None => {
            println!("{}", "🎨 Current accent color:".bold().blue());
            let config = load_config().unwrap_or_default();
            println!("  {}", config.accent_color.cyan());
            println!();
            println!("List all colors: {}", "life theme accent --list".cyan());
            return Ok(());
        }
    };

    // Validate color
    let valid_colors: Vec<&str> = colors.iter().map(|(n, _, _)| *n).collect();
    if !valid_colors.contains(&color_name.as_str()) {
        println!("{}", format!("❌ Unknown color: {}", color_name).red());
        println!();
        println!("Available colors: {}", valid_colors.join(", ").cyan());
        anyhow::bail!("Invalid color");
    }

    println!(
        "{}",
        format!("🎨 Setting accent color to {}...", color_name)
            .bold()
            .blue()
    );

    // Update config
    let mut config = load_config().unwrap_or_default();
    config.accent_color = color_name.clone();
    save_config(&config)?;

    // Apply accent
    apply_accent(&color_name).await?;

    let emoji = accent_emoji(&color_name);
    println!(
        "{}",
        format!("{} Accent color set to {}", emoji, color_name).green()
    );

    Ok(())
}

async fn set_appearance(dark: bool, light: bool, auto: bool) -> anyhow::Result<()> {
    let (dark_mode, follow_system) = if auto {
        (false, true)
    } else if dark {
        (true, false)
    } else if light {
        (false, false)
    } else {
        // Show current status
        let config = load_config().unwrap_or_default();
        println!("{}", "🌓 Appearance Settings".bold().blue());
        println!();
        println!(
            "Dark mode:      {}",
            if config.appearance.dark_mode {
                "✓ On".green()
            } else {
                "✗ Off".dimmed()
            }
        );
        println!(
            "Follow system:  {}",
            if config.appearance.follow_system {
                "✓ On".green()
            } else {
                "✗ Off".dimmed()
            }
        );
        println!();
        println!("Change with:");
        println!("  {}", "life theme appearance --dark".cyan());
        println!("  {}", "life theme appearance --light".cyan());
        println!("  {}", "life theme appearance --auto".cyan());
        return Ok(());
    };

    set_mode(if follow_system {
        ModeCommands::Auto
    } else if dark_mode {
        ModeCommands::Dark
    } else {
        ModeCommands::Light
    })
    .await
}

async fn list_themes() -> anyhow::Result<()> {
    println!("{}", "🎨 Available Themes".bold().blue());
    println!();

    println!("{}", "Variants:".bold());
    println!("  ✨ {} - Clean, minimal interface", "Simple".cyan());
    println!("     Optimized for focus and simplicity");
    println!();
    println!("  🚀 {} - Feature-rich interface", "Pro".cyan());
    println!("     Advanced tools, panels, and customization");
    println!();

    println!("{}", "Modes:".bold());
    println!("  🌙 {}", "Dark".cyan());
    println!("  ☀️ {}", "Light".cyan());
    println!("  🌓 {} (follows system setting)", "Auto".cyan());
    println!();

    println!("{}", "Accent Colors:".bold());
    println!("  🔵 Blue  🟣 Purple  🩷 Pink  🔴 Red");
    println!("  🟠 Orange  🟡 Yellow  🟢 Green  🩵 Teal  ⚪ Gray");

    Ok(())
}

async fn preview_theme(variant: Option<ThemeVariant>) -> anyhow::Result<()> {
    let variant_str = match variant {
        Some(ThemeVariant::Simple) => "simple",
        Some(ThemeVariant::Pro) => "pro",
        None => {
            println!("{}", "🎨 Theme Preview".bold().blue());
            println!();
            println!("Preview a specific theme:");
            println!("  {}", "life theme preview simple".cyan());
            println!("  {}", "life theme preview pro".cyan());
            return Ok(());
        }
    };

    println!(
        "{}",
        format!("🎨 Previewing {} theme:", variant_str.to_uppercase())
            .bold()
            .blue()
    );
    println!();

    if variant_str == "simple" {
        println!("┌─────────────────────────────────────────┐");
        println!("│  ✨ Simple Theme                        │");
        println!("│                                         │");
        println!("│  ┌──────┐                              │");
        println!("│  │ Clean│  Minimal interface           │");
        println!("│  │Focus │                              │");
        println!("│  └──────┘                              │");
        println!("│                                         │");
        println!("│  Features:                              │");
        println!("│  • Distraction-free workspace           │");
        println!("│  • Essential tools only                 │");
        println!("│  • Fast and lightweight                 │");
        println!("└─────────────────────────────────────────┘");
    } else {
        println!("┌─────────────────────────────────────────┐");
        println!("│  🚀 Pro Theme                           │");
        println!("│  ┌────────┬──────────┬────────────────┐ │");
        println!("│  │Sidebar │ Workspace│  AI Panel      │ │");
        println!("│  │        │          │  ┌──────────┐  │ │");
        println!("│  │ Tools  │  Main    │  │ Chat     │  │ │");
        println!("│  │ Panels │  Area    │  │ Actions  │  │ │");
        println!("│  │        │          │  └──────────┘  │ │");
        println!("│  └────────┴──────────┴────────────────┘ │");
        println!("│                                         │");
        println!("│  Features:                              │");
        println!("│  • Advanced panels and sidebars         │");
        println!("│  • Integrated AI assistant              │");
        println!("│  • Power user tools                     │");
        println!("└─────────────────────────────────────────┘");
    }

    println!();
    println!(
        "Apply this theme: {}",
        format!("life theme variant {}", variant_str).cyan()
    );

    Ok(())
}

async fn manage_config(cmd: ConfigCommands) -> anyhow::Result<()> {
    match cmd {
        ConfigCommands::Export { path } => {
            let config = load_config().unwrap_or_default();
            let json = serde_json::to_string_pretty(&config)?;
            fs::write(&path, json)?;
            println!(
                "{}",
                format!("✅ Theme config exported to: {}", path.display()).green()
            );
        }
        ConfigCommands::Import { path } => {
            let json = fs::read_to_string(&path)?;
            let config: ThemeConfig = serde_json::from_str(&json)?;
            save_config(&config)?;
            apply_config(&config).await?;
            println!(
                "{}",
                format!("✅ Theme config imported from: {}", path.display()).green()
            );
        }
        ConfigCommands::Reset => {
            print!("Reset theme configuration to defaults? [y/N] ");
            std::io::Write::flush(&mut std::io::stdout())?;

            let mut input = String::new();
            std::io::stdin().read_line(&mut input)?;

            if input.trim().eq_ignore_ascii_case("y") {
                let config = ThemeConfig::default();
                save_config(&config)?;
                apply_config(&config).await?;
                println!("{}", "✅ Theme configuration reset".green());
            } else {
                println!("Cancelled.");
            }
        }
    }

    Ok(())
}

// ==================== HELPER FUNCTIONS ====================

fn config_path() -> PathBuf {
    dirs::config_dir()
        .map(|d| d.join("lifeos/theme.json"))
        .unwrap_or_else(|| PathBuf::from("~/.config/lifeos/theme.json"))
}

fn load_config() -> anyhow::Result<ThemeConfig> {
    let path = config_path();
    if path.exists() {
        let json = fs::read_to_string(path)?;
        let config: ThemeConfig = serde_json::from_str(&json)?;
        Ok(config)
    } else {
        Ok(ThemeConfig::default())
    }
}

fn save_config(config: &ThemeConfig) -> anyhow::Result<()> {
    let path = config_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(config)?;
    fs::write(path, json)?;
    Ok(())
}

async fn apply_mode(dark: bool, follow_system: bool) -> anyhow::Result<()> {
    let color_scheme = if follow_system {
        "default"
    } else if dark {
        "prefer-dark"
    } else {
        "prefer-light"
    };

    // Apply to GNOME
    let _ = std::process::Command::new("gsettings")
        .args([
            "set",
            "org.gnome.desktop.interface",
            "color-scheme",
            color_scheme,
        ])
        .output();

    let gtk_theme = if dark { "Adwaita-dark" } else { "Adwaita" };
    let _ = std::process::Command::new("gsettings")
        .args(["set", "org.gnome.desktop.interface", "gtk-theme", gtk_theme])
        .output();

    Ok(())
}

async fn apply_variant(_variant: &str) -> anyhow::Result<()> {
    // Apply variant-specific settings
    // This would integrate with the desktop environment

    let icon_theme = "Adwaita";
    let _ = std::process::Command::new("gsettings")
        .args([
            "set",
            "org.gnome.desktop.interface",
            "icon-theme",
            icon_theme,
        ])
        .output();

    Ok(())
}

async fn apply_accent(color: &str) -> anyhow::Result<()> {
    // Apply accent color
    // This would integrate with the desktop environment's accent system

    let accent = match color {
        "blue" => "#3584e4",
        "purple" => "#9141ac",
        "pink" => "#ff79c6",
        "red" => "#e01b24",
        "orange" => "#ff7800",
        "yellow" => "#f6d32d",
        "green" => "#33d17a",
        "teal" => "#00b4b4",
        "gray" => "#9a9996",
        _ => "#3584e4",
    };

    // This would apply to the system accent color
    // Implementation depends on the specific desktop environment
    let _ = accent;

    Ok(())
}

async fn apply_config(config: &ThemeConfig) -> anyhow::Result<()> {
    apply_mode(config.appearance.dark_mode, config.appearance.follow_system).await?;
    apply_variant(&config.variant).await?;
    apply_accent(&config.accent_color).await?;
    Ok(())
}

async fn set_wallpaper_gnome(path: &str, desktop: bool) -> anyhow::Result<()> {
    let schema = if desktop {
        "org.gnome.desktop.background"
    } else {
        "org.gnome.desktop.screensaver"
    };

    let key = "picture-uri";
    let uri = if path.starts_with("http") {
        path.to_string()
    } else {
        format!("file://{}", std::fs::canonicalize(path)?.display())
    };

    let _ = std::process::Command::new("gsettings")
        .args(["set", schema, key, &uri])
        .output();

    // Also set dark variant
    let dark_key = if desktop { "picture-uri-dark" } else { key };
    let _ = std::process::Command::new("gsettings")
        .args(["set", schema, dark_key, &uri])
        .output();

    Ok(())
}

fn accent_emoji(color: &str) -> &'static str {
    match color {
        "blue" => "🔵",
        "purple" => "🟣",
        "pink" => "🩷",
        "red" => "🔴",
        "orange" => "🟠",
        "yellow" => "🟡",
        "green" => "🟢",
        "teal" => "🩵",
        "gray" => "⚪",
        _ => "🎨",
    }
}

fn shorten_path(path: &str) -> String {
    if path.len() > 50 {
        format!("...{}", &path[path.len() - 47..])
    } else {
        path.to_string()
    }
}
