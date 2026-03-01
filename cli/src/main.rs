use clap::{Parser, Subcommand};
use colored::Colorize;

mod commands;
mod config;
mod system;

#[cfg(test)]
mod main_tests;

use commands::{
    first_boot::FirstBootArgs,
    init::InitArgs,
    status::StatusArgs,
    update::UpdateArgs,
};

#[derive(Parser)]
#[command(name = "life")]
#[command(about = "LifeOS - First-IA System CLI")]
#[command(version = "0.1.0")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Initialize LifeOS configuration and directories
    Init(InitArgs),
    /// Run first-boot wizard
    FirstBoot(FirstBootArgs),
    /// Show system status
    Status(StatusArgs),
    /// Update system
    Update(UpdateArgs),
    /// Rollback to previous state
    Rollback,
    /// Recover from failures
    Recover,
    /// Run full system verification
    Check,
    /// Manage system configuration
    #[command(subcommand)]
    Config(commands::config::ConfigCommands),
    /// Export/restore system state
    #[command(subcommand)]
    Capsule(commands::capsule::CapsuleCommands),
    /// AI assistant commands
    #[command(subcommand)]
    Ai(commands::ai::AiCommands),
    /// Manage intents
    #[command(subcommand)]
    Intents(commands::intents::IntentsCommands),
    /// Identity and delegation
    #[command(subcommand)]
    Id(commands::id::IdCommands),
    /// App Store - browse and install applications
    #[command(subcommand)]
    Store(commands::store::StoreCommands),
    /// Theme system - customize appearance
    #[command(subcommand)]
    Theme(commands::theme::ThemeCommands),
    /// Beta testing commands
    #[command(subcommand)]
    Beta(BetaCommands),
    /// Submit feedback for beta testing
    #[command(subcommand)]
    Feedback(FeedbackCommands),
    /// System lab for testing
    #[command(subcommand)]
    Lab(LabCommands),
}

#[derive(Subcommand)]
enum LabCommands {
    /// Start lab environment
    Start,
    /// Run tests in lab
    Test,
    /// Generate lab report
    Report,
}

#[derive(Subcommand)]
enum BetaCommands {
    /// Join the beta testing program
    Join,
    /// Download latest beta build
    Download,
    /// Check for beta updates
    Update,
    /// Rollback to stable
    Rollback,
    /// Leave the beta program
    Leave,
    /// Check beta status
    Status,
    /// View known issues
    KnownIssues,
}

#[derive(Subcommand)]
enum FeedbackCommands {
    /// Report a bug
    Bug,
    /// Suggest a feature
    Feature,
    /// Submit general feedback
    General,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Init(args) => commands::init::execute(args).await,
        Commands::FirstBoot(args) => commands::first_boot::execute(args).await,
        Commands::Status(args) => commands::status::execute(args).await,
        Commands::Update(args) => commands::update::execute(args).await,
        Commands::Rollback => commands::rollback::execute().await,
        Commands::Recover => commands::recover::execute().await,
        Commands::Check => {
            let status = std::process::Command::new("lifeos-check")
                .status()
                .map_err(|e| anyhow::anyhow!("Failed to run lifeos-check: {}", e))?;
            std::process::exit(status.code().unwrap_or(1));
        }
        Commands::Config(args) => commands::config::execute(args).await,
        Commands::Capsule(args) => commands::capsule::execute(args).await,
        Commands::Ai(args) => commands::ai::execute(args).await,
        Commands::Intents(args) => commands::intents::execute(args).await,
        Commands::Id(args) => commands::id::execute(args).await,
        Commands::Store(args) => commands::store::execute(args).await,
        Commands::Theme(args) => commands::theme::execute(args).await,
        Commands::Beta(cmd) => handle_beta_command(cmd).await,
        Commands::Feedback(cmd) => handle_feedback_command(cmd).await,
        Commands::Lab(cmd) => match cmd {
            LabCommands::Start => {
                println!("{}", "Starting lab environment...".blue());
                Ok(())
            }
            LabCommands::Test => {
                println!("{}", "Running lab tests...".blue());
                Ok(())
            }
            LabCommands::Report => {
                println!("{}", "Generating lab report...".blue());
                Ok(())
            }
        },
    }
}

async fn handle_beta_command(cmd: BetaCommands) -> anyhow::Result<()> {
    match cmd {
        BetaCommands::Join => {
            println!("{}", "🚀 Joining LifeOS Beta Program...".bold().blue());
            println!();
            println!("Opening beta registration...");
            println!("Visit: {}", "https://lifeos.io/beta".cyan().underline());
            println!();
            println!("Or use the web form to apply.");
            Ok(())
        }
        BetaCommands::Download => {
            println!("{}", "⬇️  Downloading latest beta...".bold().blue());
            println!();
            println!("Latest beta available at:");
            println!("  {}", "https://github.com/hectormr/lifeos/releases".cyan());
            Ok(())
        }
        BetaCommands::Update => {
            println!("{}", "🔄 Checking for beta updates...".bold().blue());
            println!();
            println!("To update to the latest beta:");
            println!("  {}", "life update apply --channel beta".cyan());
            Ok(())
        }
        BetaCommands::Rollback => {
            println!("{}", "⏮️  Rolling back to stable...".bold().yellow());
            println!();
            println!("This will revert to the last stable version.");
            println!("Run: {}", "life rollback".cyan());
            Ok(())
        }
        BetaCommands::Leave => {
            println!("{}", "👋 Leaving beta program...".bold().yellow());
            println!();
            println!("You will no longer receive beta updates.");
            println!("To rejoin later, run: {}", "life beta join".cyan());
            Ok(())
        }
        BetaCommands::Status => {
            println!("{}", "📊 Beta Program Status".bold().blue());
            println!();
            println!("Channel:     {}", "beta".cyan());
            println!("Version:     {}", "0.2.0-beta.1".cyan());
            println!("Build:       {}", "2026-02-24".dimmed());
            println!();
            println!("Run {} for available updates.", "life beta update".cyan());
            Ok(())
        }
        BetaCommands::KnownIssues => {
            println!("{}", "🐛 Known Issues in Beta".bold().blue());
            println!();
            println!("{}", "View all known issues:".dimmed());
            println!("  {}", "https://github.com/hectormr/lifeos/issues?q=is:issue+label:beta".cyan());
            Ok(())
        }
    }
}

async fn handle_feedback_command(cmd: FeedbackCommands) -> anyhow::Result<()> {
    // Call the beta-feedback script
    let script_path = std::path::PathBuf::from("/usr/local/share/lifeos/scripts/beta-feedback.sh");
    
    let subcommand = match cmd {
        FeedbackCommands::Bug => "bug",
        FeedbackCommands::Feature => "feature",
        FeedbackCommands::General => "general",
    };
    
    // If the script exists, run it
    if script_path.exists() {
        std::process::Command::new("bash")
            .arg(&script_path)
            .arg(subcommand)
            .status()?;
    } else {
        // Fallback: show instructions
        println!("{}", format!("📝 Submitting {} feedback...", subcommand).bold().blue());
        println!();
        println!("Please submit your feedback via GitHub:");
        
        let url = match cmd {
            FeedbackCommands::Bug => "https://github.com/hectormr/lifeos/issues/new?template=bug_report.md",
            FeedbackCommands::Feature => "https://github.com/hectormr/lifeos/issues/new?template=feature_request.md",
            FeedbackCommands::General => "https://github.com/hectormr/lifeos/discussions",
        };
        
        println!("  {}", url.cyan().underline());
    }
    
    Ok(())
}
