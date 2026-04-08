use clap::{Parser, Subcommand};
use colored::Colorize;

mod ascii;
mod commands;
mod config;
mod daemon_client;
mod system;

#[cfg(test)]
mod main_tests;

use commands::{
    audit::AuditArgs, doctor::DoctorArgs, first_boot::FirstBootArgs, init::InitArgs,
    status::StatusArgs, update::UpdateArgs,
};

#[derive(Parser)]
#[command(name = "life")]
#[command(about = "LifeOS - First-IA System CLI")]
#[command(version = env!("CARGO_PKG_VERSION"))]
struct Cli {
    /// Show Axi the Axolotl ASCII art with a motivational message
    #[clap(long = "axi", global = true)]
    axi: bool,

    /// Show fun facts about axolotls and LifeOS
    #[clap(long = "axi-facts", global = true)]
    axi_facts: bool,

    #[clap(subcommand)]
    command: Option<Commands>,
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
    /// Run system health diagnostics
    Doctor(DoctorArgs),
    /// Query audit trail and reliability metrics
    Audit(AuditArgs),
    /// Safe mode controls
    #[clap(subcommand)]
    SafeMode(commands::safe_mode::SafeModeCommands),
    /// Rollback to previous state
    Rollback,
    /// Recover from failures
    Recover,
    /// Run full system verification
    Check,
    /// Manage system configuration
    #[clap(subcommand)]
    Config(commands::config::ConfigCommands),
    /// Export/restore system state
    #[clap(subcommand)]
    Capsule(commands::capsule::CapsuleCommands),
    /// AI assistant commands
    #[clap(subcommand)]
    Ai(commands::ai::AiCommands),
    /// Unified assistant access (launcher, terminal, shortcut)
    #[clap(subcommand)]
    Assistant(commands::assistant::AssistantCommands),
    /// AI adapters by app/domain (email, image, search)
    #[clap(subcommand)]
    Adapters(commands::adapters::AdaptersCommands),
    /// Voice/STT daemon controls (whisper.cpp)
    #[clap(subcommand)]
    Voice(commands::voice::VoiceCommands),
    /// AI Overlay commands
    #[clap(subcommand)]
    Overlay(commands::overlay::OverlayCommands),
    /// Experience mode commands
    #[clap(subcommand)]
    Mode(commands::mode::ModeCommands),
    /// Activate Flow context preset
    Focus,
    /// Activate Meeting context preset
    Meeting,
    /// FollowAlong contextual assistant
    #[clap(subcommand)]
    FollowAlong(commands::followalong::FollowAlongCommands),
    /// Context policies (workplace profiles)
    #[clap(subcommand)]
    Context(commands::context::ContextCommands),
    /// Manage intents
    #[clap(subcommand)]
    Intents(commands::intents::IntentsCommands),
    /// Identity and delegation
    #[clap(subcommand)]
    Id(commands::id::IdCommands),
    /// Isolated workspace execution
    #[clap(subcommand)]
    Workspace(commands::workspace::WorkspaceCommands),
    /// Onboarding and managed deployment controls
    #[clap(subcommand)]
    Onboarding(commands::onboarding::OnboardingCommands),
    /// Encrypted local memory-plane operations
    #[clap(subcommand)]
    Memory(commands::memory::MemoryCommands),
    /// Permissions policy and audit controls
    #[clap(subcommand)]
    Permissions(commands::permissions::PermissionsCommands),
    /// Local synchronization controls
    #[clap(subcommand)]
    Sync(commands::sync::SyncCommands),
    /// Skills registry and sandboxed execution
    #[clap(subcommand)]
    Skills(commands::skills::SkillsCommands),
    /// Agent Plane registry, capabilities and governance controls
    #[clap(subcommand)]
    Agents(commands::agents::AgentsCommands),
    /// Soul Plane profiles (global/user/workplace merge)
    #[clap(subcommand)]
    Soul(commands::soul::SoulCommands),
    /// Device mesh coordination and delegation
    #[clap(subcommand)]
    Mesh(commands::mesh::MeshCommands),
    /// Secure browser operator with policy + audit
    #[clap(subcommand)]
    Browser(commands::browser::BrowserCommands),
    /// Computer Use actions (mouse/keyboard automation)
    #[clap(subcommand)]
    ComputerUse(commands::computer_use::ComputerUseCommands),
    /// No-code workflow builder and runner
    #[clap(subcommand)]
    Workflow(commands::workflow::WorkflowCommands),
    /// App Store - browse and install applications
    #[clap(subcommand)]
    Store(commands::store::StoreCommands),
    /// Local telemetry (privacy-first, no external data)
    #[clap(subcommand)]
    Telemetry(commands::telemetry::TelemetryCommands),
    /// Theme system - customize appearance
    #[clap(subcommand)]
    Theme(commands::theme::ThemeCommands),
    /// Visual comfort settings (color temperature, font scale, animations)
    #[clap(subcommand)]
    VisualComfort(commands::visual_comfort::VisualComfortCommands),
    /// Accessibility settings and WCAG audit
    #[clap(subcommand)]
    Accessibility(commands::accessibility::AccessibilityCommands),
    /// xdg-desktop-portal integration for app sandboxing
    #[clap(subcommand)]
    Portal(commands::portal::PortalCommands),
    /// Legacy compatibility shim for the pre-release channel flow
    #[clap(subcommand, hide = true)]
    Beta(BetaCommands),
    /// Submit user feedback
    #[clap(subcommand)]
    Feedback(FeedbackCommands),
    /// LifeOS Lab - autonomous improvement pipeline
    Lab(commands::lab::LabArgs),
}

#[derive(Subcommand)]
enum BetaCommands {
    /// Switch guidance to the candidate channel
    Join,
    /// Show where release artifacts live now
    Download,
    /// Show canonical pre-release update guidance
    Update,
    /// Show stable rollback guidance
    Rollback,
    /// Switch guidance back to stable
    Leave,
    /// Explain how beta maps to canonical channels
    Status,
    /// View pre-release known issues
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

    // Handle easter egg flags first
    if cli.axi {
        print_axi_easter_egg();
        return Ok(());
    }

    if cli.axi_facts {
        print_axi_facts();
        return Ok(());
    }

    // Handle regular commands
    match cli.command {
        Some(Commands::Init(args)) => commands::init::execute(args).await,
        Some(Commands::FirstBoot(args)) => commands::first_boot::execute(args).await,
        Some(Commands::Status(args)) => commands::status::execute(args).await,
        Some(Commands::Update(args)) => commands::update::execute(args).await,
        Some(Commands::Doctor(args)) => commands::doctor::execute(args).await,
        Some(Commands::Audit(args)) => commands::audit::execute(args).await,
        Some(Commands::SafeMode(cmd)) => commands::safe_mode::execute(cmd).await,
        Some(Commands::Rollback) => commands::rollback::execute().await,
        Some(Commands::Recover) => commands::recover::execute().await,
        Some(Commands::Check) => {
            let status = std::process::Command::new("lifeos-check")
                .status()
                .map_err(|e| anyhow::anyhow!("Failed to run lifeos-check: {}", e))?;
            std::process::exit(status.code().unwrap_or(1));
        }
        Some(Commands::Config(args)) => commands::config::execute(args).await,
        Some(Commands::Capsule(args)) => commands::capsule::execute(args).await,
        Some(Commands::Ai(args)) => commands::ai::execute(args).await,
        Some(Commands::Assistant(args)) => commands::assistant::execute(args).await,
        Some(Commands::Adapters(args)) => commands::adapters::execute(args).await,
        Some(Commands::Voice(args)) => commands::voice::execute(args).await,
        Some(Commands::Overlay(args)) => commands::overlay::execute(args).await,
        Some(Commands::Mode(args)) => commands::mode::execute(args).await,
        Some(Commands::Focus) => commands::focus::execute_focus().await,
        Some(Commands::Meeting) => commands::focus::execute_meeting().await,
        Some(Commands::FollowAlong(args)) => {
            commands::followalong::execute_followalong_command(args).await
        }
        Some(Commands::Context(args)) => commands::context::execute(args).await,
        Some(Commands::Intents(args)) => commands::intents::execute(args).await,
        Some(Commands::Id(args)) => commands::id::execute(args).await,
        Some(Commands::Workspace(args)) => commands::workspace::execute(args).await,
        Some(Commands::Onboarding(args)) => commands::onboarding::execute(args).await,
        Some(Commands::Memory(args)) => commands::memory::execute(args).await,
        Some(Commands::Permissions(args)) => commands::permissions::execute(args).await,
        Some(Commands::Sync(args)) => commands::sync::execute(args).await,
        Some(Commands::Skills(args)) => commands::skills::execute(args).await,
        Some(Commands::Agents(args)) => commands::agents::execute(args).await,
        Some(Commands::Soul(args)) => commands::soul::execute(args).await,
        Some(Commands::Mesh(args)) => commands::mesh::execute(args).await,
        Some(Commands::Browser(args)) => commands::browser::execute(args).await,
        Some(Commands::ComputerUse(args)) => commands::computer_use::execute(args).await,
        Some(Commands::Workflow(args)) => commands::workflow::execute(args).await,
        Some(Commands::Store(args)) => commands::store::execute(args).await,
        Some(Commands::Telemetry(args)) => commands::telemetry::execute(args).await,
        Some(Commands::Theme(args)) => commands::theme::execute(args).await,
        Some(Commands::VisualComfort(args)) => commands::visual_comfort::execute(args).await,
        Some(Commands::Accessibility(args)) => commands::accessibility::execute(args).await,
        Some(Commands::Portal(args)) => commands::portal::execute(args).await,
        Some(Commands::Beta(cmd)) => handle_beta_command(cmd).await,
        Some(Commands::Feedback(cmd)) => handle_feedback_command(cmd).await,
        Some(Commands::Lab(args)) => commands::lab::execute(args).await,
        None => {
            // No command provided, show help
            println!("{}", "LifeOS - First-IA System CLI".bold().blue());
            println!();
            println!("Use {} to see available commands.", "life --help".cyan());
            println!();
            println!("Try {} for a surprise! 🦎", "life --axi".cyan());
            Ok(())
        }
    }
}

/// Print Axi the Axolotl ASCII art with a motivational message
fn print_axi_easter_egg() {
    println!();
    println!("{}", "🦎 Axi says:".bold().magenta());
    println!();
    println!("{}", ascii::AXI_ASCII.bright_magenta());
    println!();
    println!("  \"{}\"", ascii::get_random_quote().italic());
    println!();
    println!(
        "  {}",
        "— Axi, your friendly neighborhood axolotl 🦎".dimmed()
    );
    println!();
}

/// Print fun facts about axolotls
fn print_axi_facts() {
    println!();
    println!("{}", "🦎 Axi's Fun Facts About Axolotls".bold().magenta());
    println!("{}", "================================".magenta());
    println!();
    println!("{}", ascii::get_random_fact());
    println!();
    println!("{}", ascii::AXI_MINI.bright_magenta());
    println!();
    println!("  {}", "Want more facts? Run me again!".dimmed());
    println!();
}

async fn handle_beta_command(cmd: BetaCommands) -> anyhow::Result<()> {
    println!(
        "{}",
        "`life beta` is deprecated. Use canonical update channels instead."
            .yellow()
            .bold()
    );
    println!(
        "{}",
        "Canonical channels: stable (production), candidate (pre-release), edge (bleeding edge)."
            .dimmed()
    );
    println!();

    match cmd {
        BetaCommands::Join => {
            println!(
                "{}",
                "Use `candidate` for pre-release testing.".bold().blue()
            );
            println!("Switch the host image explicitly with:");
            println!(
                "  {}",
                "sudo bootc switch ghcr.io/hectormr206/lifeos:candidate".cyan()
            );
            println!("Then keep local preference aligned in `/etc/lifeos/lifeos.toml`:");
            println!("  {}", "[updates]".cyan());
            println!("  {}", "channel = \"candidate\"".cyan());
            println!();
            println!("Check current state with: {}", "life update status".cyan());
            Ok(())
        }
        BetaCommands::Download => {
            println!(
                "{}",
                "LifeOS updates no longer revolve around beta downloads."
                    .bold()
                    .blue()
            );
            println!("Normal host updates come from signed GHCR images staged by `bootc`.");
            println!(
                "Release page: {}",
                "https://github.com/hectormr/lifeos/releases".cyan()
            );
            println!("Canonical status path: {}", "life update status".cyan());
            Ok(())
        }
        BetaCommands::Update => {
            println!(
                "{}",
                "Pre-release updates map to the `candidate` channel."
                    .bold()
                    .blue()
            );
            println!("If you are already on `candidate`, use:");
            println!("  {}", "life update".cyan());
            println!("If you are still on another track, switch first with:");
            println!(
                "  {}",
                "sudo bootc switch ghcr.io/hectormr206/lifeos:candidate".cyan()
            );
            println!("Then verify with: {}", "life update status".cyan());
            Ok(())
        }
        BetaCommands::Rollback => {
            println!("{}", "Rollback stays canonical too.".bold().yellow());
            println!(
                "To return to the previous deployment, run: {}",
                "life rollback".cyan()
            );
            println!(
                "To pin the stable track explicitly, run: {}",
                "sudo bootc switch ghcr.io/hectormr206/lifeos:stable".cyan()
            );
            Ok(())
        }
        BetaCommands::Leave => {
            println!(
                "{}",
                "Leaving beta means moving back to `stable`."
                    .bold()
                    .yellow()
            );
            println!(
                "Switch the host image with: {}",
                "sudo bootc switch ghcr.io/hectormr206/lifeos:stable".cyan()
            );
            println!("Then keep local preference aligned in `/etc/lifeos/lifeos.toml`.");
            println!(
                "Check resulting state with: {}",
                "life update status".cyan()
            );
            Ok(())
        }
        BetaCommands::Status => {
            println!("{}", "`beta` is not a canonical channel.".bold().blue());
            println!("Use the real channels instead:");
            println!("  {}", "stable     production/default track".cyan());
            println!("  {}", "candidate  pre-release validation track".cyan());
            println!("  {}", "edge       latest development track".cyan());
            println!();
            println!(
                "Inspect current state with: {}",
                "life update status".cyan()
            );
            Ok(())
        }
        BetaCommands::KnownIssues => {
            println!(
                "{}",
                "Known issues live in the normal tracker.".bold().blue()
            );
            println!(
                "{}",
                "For pre-release validation, review candidate-related issues:".dimmed()
            );
            println!(
                "  {}",
                "https://github.com/hectormr/lifeos/issues?q=is:issue+label:beta".cyan()
            );
            Ok(())
        }
    }
}

async fn handle_feedback_command(cmd: FeedbackCommands) -> anyhow::Result<()> {
    // Call the legacy feedback helper if it exists.
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
        println!(
            "{}",
            format!("📝 Submitting {} feedback...", subcommand)
                .bold()
                .blue()
        );
        println!();
        println!("Please submit your feedback via GitHub:");

        let url = match cmd {
            FeedbackCommands::Bug => {
                "https://github.com/hectormr/lifeos/issues/new?template=bug_report.md"
            }
            FeedbackCommands::Feature => {
                "https://github.com/hectormr/lifeos/issues/new?template=feature_request.md"
            }
            FeedbackCommands::General => "https://github.com/hectormr/lifeos/discussions",
        };

        println!("  {}", url.cyan().underline());
    }

    Ok(())
}
