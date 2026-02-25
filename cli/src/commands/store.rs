use clap::Subcommand;
use colored::Colorize;
use std::process::Command;

#[derive(Subcommand)]
pub enum StoreCommands {
    /// Search for applications
    Search {
        /// Search query
        query: String,
        /// Filter by category
        #[arg(short, long)]
        category: Option<String>,
        /// Show all results (not just top 20)
        #[arg(short, long)]
        all: bool,
    },
    /// Browse applications by category
    Categories,
    /// Show featured/recommended apps
    Featured,
    /// Install an application
    Install {
        /// Application ID or flathub: prefix
        app: String,
        /// Install without confirmation
        #[arg(short, long)]
        yes: bool,
        /// Install system-wide (requires sudo)
        #[arg(short, long)]
        system: bool,
    },
    /// Remove an application
    Remove {
        /// Application ID
        app: String,
        /// Remove without confirmation
        #[arg(short, long)]
        yes: bool,
        /// Remove user data
        #[arg(long)]
        purge: bool,
    },
    /// Update installed applications
    Update {
        /// Update specific app (if omitted, updates all)
        app: Option<String>,
        /// Update without confirmation
        #[arg(short, long)]
        yes: bool,
    },
    /// List installed applications
    List {
        /// Show more details
        #[arg(short, long)]
        detailed: bool,
        /// Filter by category
        #[arg(short, long)]
        category: Option<String>,
    },
    /// Show app details
    Info {
        /// Application ID
        app: String,
    },
    /// Browse LifeOS curated apps
    Curated,
    /// Check for available updates
    Check,
    /// Manage app sources/repositories
    #[command(subcommand)]
    Sources(SourcesCommands),
}

#[derive(Subcommand)]
pub enum SourcesCommands {
    /// List configured sources
    List,
    /// Add a source
    Add {
        /// Source name
        name: String,
        /// Source URL
        url: String,
    },
    /// Remove a source
    Remove {
        /// Source name
        name: String,
    },
    /// Update source metadata
    Update,
}

pub async fn execute(args: StoreCommands) -> anyhow::Result<()> {
    // Check if flatpak is installed
    if !is_flatpak_installed() {
        println!("{}", "❌ Flatpak is not installed".red());
        println!();
        println!("LifeOS Store requires Flatpak. Install it with:");
        println!("  {}", "sudo dnf install flatpak".cyan());
        anyhow::bail!("Flatpak not found");
    }

    // Check if flathub is configured
    if !is_flathub_configured().await {
        println!("{}", "⚠️  Flathub repository not configured".yellow());
        println!();
        println!("Setting up Flathub...");
        setup_flathub().await?;
    }

    match args {
        StoreCommands::Search { query, category, all } => search_apps(&query, category.as_deref(), all).await,
        StoreCommands::Categories => list_categories().await,
        StoreCommands::Featured => show_featured().await,
        StoreCommands::Install { app, yes, system } => install_app(&app, yes, system).await,
        StoreCommands::Remove { app, yes, purge } => remove_app(&app, yes, purge).await,
        StoreCommands::Update { app, yes } => update_apps(app.as_deref(), yes).await,
        StoreCommands::List { detailed, category } => list_installed(detailed, category.as_deref()).await,
        StoreCommands::Info { app } => show_app_info(&app).await,
        StoreCommands::Curated => show_curated().await,
        StoreCommands::Check => check_updates().await,
        StoreCommands::Sources(cmd) => manage_sources(cmd).await,
    }
}

// ==================== COMMAND IMPLEMENTATIONS ====================

async fn search_apps(query: &str, category: Option<&str>, all: bool) -> anyhow::Result<()> {
    println!("{}", format!("🔍 Searching for: {}", query).bold().blue());
    
    if let Some(cat) = category {
        println!("   Category: {}", cat.cyan());
    }
    println!();

    // Search in flathub
    let mut cmd = Command::new("flatpak");
    cmd.args(["search", "--columns=name,application,version,description", query]);
    
    let output = cmd.output()?;
    
    if output.status.success() {
        let results = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = results.lines().collect();
        
        if lines.is_empty() {
            println!("{}", "No applications found.".dimmed());
            println!();
            println!("Try:");
            println!("  • Using different keywords");
            println!("  • Browsing categories: {}", "life store categories".cyan());
            println!("  • Viewing featured: {}", "life store featured".cyan());
        } else {
            println!("{}", "Results from Flathub:".bold());
            println!("{}", "─".repeat(70).dimmed());
            
            let limit = if all { lines.len() } else { lines.len().min(20) };
            
            for line in lines.iter().take(limit) {
                let parts: Vec<&str> = line.split('\t').collect();
                if parts.len() >= 3 {
                    let name = parts[0];
                    let app_id = parts[1];
                    let version = parts.get(2).unwrap_or(&"");
                    let desc = parts.get(3).unwrap_or(&"");
                    
                    println!("\n{}", name.bold());
                    println!("  {} {}", "ID:".dimmed(), app_id.cyan());
                    if !version.is_empty() {
                        println!("  {} {}", "Version:".dimmed(), version);
                    }
                    if !desc.is_empty() {
                        let short_desc = if desc.len() > 60 {
                            format!("{}...", &desc[..57])
                        } else {
                            desc.to_string()
                        };
                        println!("  {}", short_desc.dimmed());
                    }
                }
            }
            
            if lines.len() > limit {
                println!("\n{} and {} more results. Use --all to see all.", 
                    "...".dimmed(), 
                    lines.len() - limit
                );
            }
        }
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("Search failed: {}", stderr);
    }

    println!();
    println!("Install an app: {}", format!("life store install <app-id>",).cyan());
    
    Ok(())
}

async fn list_categories() -> anyhow::Result<()> {
    println!("{}", "📂 App Categories".bold().blue());
    println!();

    let categories = vec![
        ("🌐", "Network", "Browsers, email, chat"),
        ("🎨", "Graphics", "Image editing, drawing"),
        ("🎵", "Audio", "Music players, editors"),
        ("🎬", "Video", "Players, editors, streaming"),
        ("🎮", "Games", "Games and emulators"),
        ("📝", "Office", "Documents, spreadsheets"),
        ("💻", "Development", "IDEs, tools, utilities"),
        ("🔬", "Science", "Scientific applications"),
        ("🎓", "Education", "Learning tools"),
        ("🔒", "System", "System utilities"),
        ("🛒", "Utility", "Productivity tools"),
    ];

    for (icon, name, desc) in categories {
        println!("{} {:<15} {}", icon, name.cyan(), desc.dimmed());
    }

    println!();
    println!("Browse a category: {}", "life store search <query> --category <name>".cyan());
    
    Ok(())
}

async fn show_featured() -> anyhow::Result<()> {
    println!("{}", "⭐ Featured Applications".bold().blue());
    println!();

    let featured = vec![
        ("org.mozilla.firefox", "Firefox", "Web browser", "🌐"),
        ("com.spotify.Client", "Spotify", "Music streaming", "🎵"),
        ("com.visualstudio.code", "VS Code", "Code editor", "💻"),
        ("org.videolan.VLC", "VLC", "Media player", "🎬"),
        ("com.discordapp.Discord", "Discord", "Chat for communities", "💬"),
        ("org.blender.Blender", "Blender", "3D creation suite", "🎨"),
        ("com.obsproject.Studio", "OBS Studio", "Streaming/recording", "📺"),
        ("com.valvesoftware.Steam", "Steam", "Gaming platform", "🎮"),
        ("org.libreoffice.LibreOffice", "LibreOffice", "Office suite", "📝"),
        ("org.gimp.GIMP", "GIMP", "Image editor", "🖼️"),
    ];

    for (app_id, name, desc, icon) in featured {
        let installed = is_app_installed(app_id).await;
        let status = if installed {
            "✓".green()
        } else {
            " ".into()
        };
        
        println!("{} {} {:<25} {}", 
            status,
            icon,
            name.cyan(),
            desc.dimmed()
        );
        println!("   {}", app_id.dimmed());
    }

    println!();
    println!("Install: {}", "life store install <app-id>".cyan());
    
    Ok(())
}

async fn install_app(app: &str, yes: bool, system: bool) -> anyhow::Result<()> {
    // Normalize app ID
    let app_id = if app.contains(':') {
        // Handle flathub: prefix
        app.split(':').nth(1).unwrap_or(app).to_string()
    } else {
        app.to_string()
    };

    println!("{}", format!("📦 Installing: {}", app_id).bold().blue());
    println!();

    // Check if already installed
    if is_app_installed(&app_id).await {
        println!("{} {} is already installed", "ℹ️".blue(), app_id);
        return Ok(());
    }

    // Show app info first
    if let Ok(info) = get_app_info(&app_id).await {
        println!("{}", info.name.bold());
        println!("{}", info.description.dimmed());
        println!();
        println!("Size: {}", info.size.dimmed());
        println!("Version: {}", info.version.dimmed());
        println!();
    }

    // Confirm unless --yes
    if !yes {
        print!("Install {}? [Y/n] ", app_id);
        std::io::Write::flush(&mut std::io::stdout())?;
        
        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;
        
        if !input.trim().is_empty() && !input.trim().eq_ignore_ascii_case("y") {
            println!("Cancelled.");
            return Ok(());
        }
    }

    // Install
    let mut cmd = Command::new("flatpak");
    cmd.arg("install");
    
    if yes {
        cmd.arg("-y");
    }
    
    if system {
        cmd.arg("--system");
    } else {
        cmd.arg("--user");
    }
    
    cmd.args(["flathub", &app_id]);

    println!("Installing... (this may take a few minutes)");
    
    let status = cmd.status()?;
    
    if status.success() {
        println!();
        println!("{}", format!("✅ {} installed successfully!", app_id).green());
        println!();
        println!("Launch with: {}", format!("flatpak run {}", app_id).cyan());
        println!("Or find it in the application menu.");
    } else {
        anyhow::bail!("Installation failed");
    }

    Ok(())
}

async fn remove_app(app: &str, yes: bool, purge: bool) -> anyhow::Result<()> {
    println!("{}", format!("🗑️  Removing: {}", app).bold().yellow());

    // Check if installed
    if !is_app_installed(app).await {
        println!("{} {} is not installed", "⚠️".yellow(), app);
        return Ok(());
    }

    // Confirm unless --yes
    if !yes {
        print!("\nAre you sure? [y/N] ");
        std::io::Write::flush(&mut std::io::stdout())?;
        
        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;
        
        if !input.trim().eq_ignore_ascii_case("y") {
            println!("Cancelled.");
            return Ok(());
        }
    }

    let mut cmd = Command::new("flatpak");
    cmd.arg("uninstall");
    
    if yes {
        cmd.arg("-y");
    }
    
    if purge {
        cmd.arg("--delete-data");
    }
    
    cmd.arg(app);

    let status = cmd.status()?;
    
    if status.success() {
        println!("{}", format!("✅ {} removed", app).green());
    } else {
        anyhow::bail!("Removal failed");
    }

    Ok(())
}

async fn update_apps(app: Option<&str>, yes: bool) -> anyhow::Result<()> {
    if let Some(app_id) = app {
        println!("{}", format!("🔄 Updating: {}", app_id).bold().blue());
        
        let mut cmd = Command::new("flatpak");
        cmd.args(["update", app_id]);
        
        if yes {
            cmd.arg("-y");
        }
        
        let status = cmd.status()?;
        
        if status.success() {
            println!("{}", format!("✅ {} updated", app_id).green());
        }
    } else {
        println!("{}", "🔄 Checking for updates...".bold().blue());
        println!();

        // List available updates
        let output = Command::new("flatpak")
            .args(["update", "--app"])
            .output()?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        
        if stdout.contains("Nothing to do") || stdout.trim().is_empty() {
            println!("{}", "✅ All apps are up to date!".green());
        } else {
            println!("{}", stdout);
            println!();
            
            // Apply updates
            if !yes {
                print!("Apply these updates? [Y/n] ");
                std::io::Write::flush(&mut std::io::stdout())?;
                
                let mut input = String::new();
                std::io::stdin().read_line(&mut input)?;
                
                if input.trim().is_empty() || input.trim().eq_ignore_ascii_case("y") {
                    let status = Command::new("flatpak")
                        .args(["update", "-y"])
                        .status()?;
                    
                    if status.success() {
                        println!("{}", "✅ Updates applied".green());
                    }
                }
            } else {
                let status = Command::new("flatpak")
                    .args(["update", "-y"])
                    .status()?;
                
                if status.success() {
                    println!("{}", "✅ Updates applied".green());
                }
            }
        }
    }

    Ok(())
}

async fn list_installed(detailed: bool, _category: Option<&str>) -> anyhow::Result<()> {
    println!("{}", "📋 Installed Applications".bold().blue());
    println!();

    let mut cmd = Command::new("flatpak");
    cmd.args(["list", "--app", "--columns=name,application,version,size"]);
    
    let output = cmd.output()?;
    
    if output.status.success() {
        let apps = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = apps.lines().collect();
        
        if lines.is_empty() || (lines.len() == 1 && lines[0].trim().is_empty()) {
            println!("{}", "No applications installed.".dimmed());
            println!();
            println!("Install apps with: {}", "life store install <app>".cyan());
            println!("Browse featured: {}", "life store featured".cyan());
        } else {
            for line in lines {
                let parts: Vec<&str> = line.split('\t').collect();
                if parts.len() >= 2 {
                    let name = parts[0];
                    let app_id = parts[1];
                    let version = parts.get(2).map(|s| *s).unwrap_or("");
                    let size = parts.get(3).map(|s| *s).unwrap_or("");
                    
                    if detailed {
                        println!("{}", name.bold());
                        println!("  {} {}", "ID:".dimmed(), app_id.cyan());
                        if !version.is_empty() {
                            println!("  {} {}", "Version:".dimmed(), version);
                        }
                        if !size.is_empty() {
                            println!("  {} {}", "Size:".dimmed(), size);
                        }
                        println!();
                    } else {
                        println!("{:<30} {}", 
                            name.cyan(),
                            if !version.is_empty() { version.dimmed() } else { "".dimmed() }
                        );
                    }
                }
            }
            
            println!();
            println!("Total: {} applications", apps.lines().count());
        }
    }

    Ok(())
}

async fn show_app_info(app: &str) -> anyhow::Result<()> {
    let info = get_app_info(app).await?;
    
    println!("{}", info.name.bold().blue());
    println!("{}", "═".repeat(info.name.len()).blue());
    println!();
    println!("{}", info.description);
    println!();
    println!("{} {}", "ID:".dimmed(), app.cyan());
    println!("{} {}", "Version:".dimmed(), info.version);
    println!("{} {}", "Size:".dimmed(), info.size);
    
    if let Some(license) = info.license {
        println!("{} {}", "License:".dimmed(), license);
    }
    
    if let Some(url) = info.homepage {
        println!("{} {}", "Homepage:".dimmed(), url.underline());
    }
    
    let installed = is_app_installed(app).await;
    println!();
    if installed {
        println!("{}", "✓ Installed".green());
        println!("  Remove: {}", format!("life store remove {}", app).cyan());
    } else {
        println!("{}", "Not installed".dimmed());
        println!("  Install: {}", format!("life store install {}", app).cyan());
    }

    Ok(())
}

async fn show_curated() -> anyhow::Result<()> {
    println!("{}", "🎯 LifeOS Curated Apps".bold().blue());
    println!();
    println!("These apps are recommended and tested for LifeOS:");
    println!();

    let curated = vec![
        ("Essential", vec![
            ("org.mozilla.firefox", "Firefox", "Privacy-focused browser"),
            ("com.transmissionbt.Transmission", "Transmission", "BitTorrent client"),
            ("org.videolan.VLC", "VLC", "Universal media player"),
        ]),
        ("Productivity", vec![
            ("org.libreoffice.LibreOffice", "LibreOffice", "Full office suite"),
            ("md.obsidian.Obsidian", "Obsidian", "Knowledge management"),
            ("com.jgraph.drawio.desktop", "draw.io", "Diagrams and flowcharts"),
        ]),
        ("Development", vec![
            ("com.visualstudio.code", "VS Code", "Popular code editor"),
            ("org.gnome.Builder", "GNOME Builder", "Native GNOME IDE"),
            ("com.github.git-cola.git-cola", "Git Cola", "Git GUI client"),
        ]),
        ("Creative", vec![
            ("org.gimp.GIMP", "GIMP", "Professional image editor"),
            ("org.blender.Blender", "Blender", "3D creation suite"),
            ("org.inkscape.Inkscape", "Inkscape", "Vector graphics"),
        ]),
        ("Communication", vec![
            ("com.discordapp.Discord", "Discord", "Community chat"),
            ("org.signal.Signal", "Signal", "Private messaging"),
            ("us.zoom.Zoom", "Zoom", "Video conferencing"),
        ]),
    ];

    for (category, apps) in curated {
        println!("{}", category.bold());
        for (app_id, name, desc) in apps {
            let installed = if is_app_installed(app_id).await { " ✓" } else { "" };
            println!("  {} {:<25} {}{}", 
                "•".dimmed(),
                name.cyan(),
                desc.dimmed(),
                installed.green()
            );
        }
        println!();
    }

    Ok(())
}

async fn check_updates() -> anyhow::Result<()> {
    println!("{}", "🔍 Checking for updates...".bold().blue());
    println!();

    let output = Command::new("flatpak")
        .args(["update", "--app", "--dry-run"])
        .output()?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    
    if stdout.contains("Nothing to do") || stdout.trim().is_empty() {
        println!("{}", "✅ All applications are up to date!".green());
    } else {
        println!("{}", stdout);
        println!();
        println!("Update with: {}", "life store update".cyan());
    }

    Ok(())
}

async fn manage_sources(cmd: SourcesCommands) -> anyhow::Result<()> {
    match cmd {
        SourcesCommands::List => {
            println!("{}", "📦 Configured Sources".bold().blue());
            println!();

            let output = Command::new("flatpak")
                .args(["remotes", "--columns=name,url,options"])
                .output()?;

            if output.status.success() {
                let remotes = String::from_utf8_lossy(&output.stdout);
                println!("{}", remotes);
            }
        }
        SourcesCommands::Add { name, url } => {
            println!("Adding source: {} -> {}", name.cyan(), url);
            
            let status = Command::new("flatpak")
                .args(["remote-add", "--if-not-exists", &name, &url])
                .status()?;
            
            if status.success() {
                println!("{}", "✅ Source added".green());
            }
        }
        SourcesCommands::Remove { name } => {
            println!("Removing source: {}", name.yellow());
            
            let status = Command::new("flatpak")
                .args(["remote-delete", &name])
                .status()?;
            
            if status.success() {
                println!("{}", "✅ Source removed".green());
            }
        }
        SourcesCommands::Update => {
            println!("{}", "🔄 Updating source metadata...".bold().blue());
            
            let status = Command::new("flatpak")
                .arg("update")
                .arg("--appstream")
                .status()?;
            
            if status.success() {
                println!("{}", "✅ Sources updated".green());
            }
        }
    }

    Ok(())
}

// ==================== HELPER FUNCTIONS ====================

fn is_flatpak_installed() -> bool {
    Command::new("which")
        .arg("flatpak")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

async fn is_flathub_configured() -> bool {
    let output = Command::new("flatpak")
        .args(["remotes", "--columns=name"])
        .output();

    match output {
        Ok(o) if o.status.success() => {
            let remotes = String::from_utf8_lossy(&o.stdout);
            remotes.lines().any(|line| line.trim() == "flathub")
        }
        _ => false,
    }
}

async fn setup_flathub() -> anyhow::Result<()> {
    println!("Adding Flathub repository...");
    
    let status = Command::new("flatpak")
        .args([
            "remote-add",
            "--if-not-exists",
            "--user",
            "flathub",
            "https://flathub.org/repo/flathub.flatpakrepo",
        ])
        .status()?;

    if status.success() {
        println!("{}", "✅ Flathub configured".green());
        println!();
        println!("Updating app data...");
        
        Command::new("flatpak")
            .args(["update", "--appstream"])
            .spawn()?;
    } else {
        anyhow::bail!("Failed to configure Flathub");
    }

    Ok(())
}

async fn is_app_installed(app_id: &str) -> bool {
    let output = Command::new("flatpak")
        .args(["list", "--app", "--columns=application"])
        .output();

    match output {
        Ok(o) if o.status.success() => {
            let apps = String::from_utf8_lossy(&o.stdout);
            apps.lines().any(|line| line.trim() == app_id)
        }
        _ => false,
    }
}

struct AppInfo {
    name: String,
    description: String,
    version: String,
    size: String,
    license: Option<String>,
    homepage: Option<String>,
}

async fn get_app_info(app_id: &str) -> anyhow::Result<AppInfo> {
    // Try to get info from flatpak
    let output = Command::new("flatpak")
        .args(["info", app_id])
        .output();

    let mut name = app_id.to_string();
    let description = String::new();
    let mut version = "unknown".to_string();
    let mut size = "unknown".to_string();
    let license: Option<String> = None;
    let homepage: Option<String> = None;

    if let Ok(o) = output {
        if o.status.success() {
            let info = String::from_utf8_lossy(&o.stdout);
            
            for line in info.lines() {
                if line.starts_with("Name:") {
                    name = line.splitn(2, ':').nth(1).unwrap_or(&name).trim().to_string();
                } else if line.starts_with("Version:") {
                    version = line.splitn(2, ':').nth(1).unwrap_or("unknown").trim().to_string();
                } else if line.starts_with("Installed:") {
                    size = line.splitn(2, ':').nth(1).unwrap_or("unknown").trim().to_string();
                }
            }
        }
    }

    Ok(AppInfo {
        name,
        description,
        version,
        size,
        license,
        homepage,
    })
}
