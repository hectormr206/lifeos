use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum OnboardingCommands {
    /// Managed deployment trust mode
    #[command(subcommand)]
    TrustMode(TrustModeCommands),
}

#[derive(Subcommand)]
pub enum TrustModeCommands {
    /// Show trust mode status
    Status,
    /// Enable trust mode using signed consent bundle
    Enable {
        /// Actor principal that enables trust mode
        #[arg(long, default_value = "user://local/admin")]
        actor: String,
        /// Path to consent bundle file
        #[arg(long, default_value = "/etc/lifeos/consent-bundle.toml")]
        bundle: String,
        /// Path to detached signature file
        #[arg(long, default_value = "/etc/lifeos/consent-bundle.toml.sig")]
        sig: String,
    },
    /// Disable trust mode
    Disable {
        /// Actor principal that disables trust mode
        #[arg(long, default_value = "user://local/admin")]
        actor: String,
    },
}

pub async fn execute(args: OnboardingCommands) -> anyhow::Result<()> {
    match args {
        OnboardingCommands::TrustMode(cmd) => execute_trust_mode(cmd).await,
    }
}

async fn execute_trust_mode(cmd: TrustModeCommands) -> anyhow::Result<()> {
    match cmd {
        TrustModeCommands::Status => trust_mode_status().await,
        TrustModeCommands::Enable { actor, bundle, sig } => {
            trust_mode_enable(&actor, &bundle, &sig).await
        }
        TrustModeCommands::Disable { actor } => trust_mode_disable(&actor).await,
    }
}

async fn trust_mode_status() -> anyhow::Result<()> {
    let body: serde_json::Value = daemon_client::get_json("/api/v1/runtime/trust-mode").await?;
    println!("{}", "Trust Mode".bold().blue());
    println!(
        "  enabled: {}",
        if body["enabled"].as_bool().unwrap_or(false) {
            "true".green()
        } else {
            "false".yellow()
        }
    );
    println!(
        "  activated_by: {}",
        body["activated_by"].as_str().unwrap_or("n/a").cyan()
    );
    println!(
        "  consent_bundle_sha256: {}",
        body["consent_bundle_sha256"]
            .as_str()
            .unwrap_or("n/a")
            .dimmed()
    );
    Ok(())
}

async fn trust_mode_enable(actor: &str, bundle_path: &str, sig_path: &str) -> anyhow::Result<()> {
    let bundle = std::fs::read_to_string(bundle_path)
        .map_err(|e| anyhow::anyhow!("Failed to read consent bundle '{}': {}", bundle_path, e))?;
    let signature = std::fs::read_to_string(sig_path)
        .map_err(|e| anyhow::anyhow!("Failed to read signature '{}': {}", sig_path, e))?;

    let payload = serde_json::json!({
        "enabled": true,
        "actor": actor,
        "consent_bundle": bundle,
        "signature": signature,
    });
    let _: serde_json::Value =
        daemon_client::post_json("/api/v1/runtime/trust-mode", &payload).await?;

    println!("{}", "Trust mode enabled".green().bold());
    println!("  actor: {}", actor.cyan());
    println!("  bundle: {}", bundle_path.cyan());
    println!("  signature: {}", sig_path.cyan());
    Ok(())
}

async fn trust_mode_disable(actor: &str) -> anyhow::Result<()> {
    let payload = serde_json::json!({
        "enabled": false,
        "actor": actor,
    });
    let _: serde_json::Value =
        daemon_client::post_json("/api/v1/runtime/trust-mode", &payload).await?;

    println!("{}", "Trust mode disabled".yellow().bold());
    println!("  actor: {}", actor.cyan());
    Ok(())
}
