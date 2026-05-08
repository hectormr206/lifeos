use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum IdCommands {
    /// Issue a capability token
    Issue {
        #[arg(long)]
        agent: String,
        #[arg(long)]
        cap: String,
        #[arg(long, default_value = "60")]
        ttl: u32,
        #[arg(long)]
        scope: Option<String>,
    },
    /// List issued identity tokens
    List {
        /// Show only active (not revoked and not expired) tokens
        #[arg(long)]
        active: bool,
    },
    /// Revoke a token
    Revoke { token_id: String },
}

pub async fn execute(args: IdCommands) -> anyhow::Result<()> {
    match args {
        IdCommands::Issue {
            agent,
            cap,
            ttl,
            scope,
        } => cmd_issue(&agent, &cap, ttl, scope.as_deref()).await?,
        IdCommands::List { active } => cmd_list(active).await?,
        IdCommands::Revoke { token_id } => cmd_revoke(&token_id).await?,
    }
    Ok(())
}

async fn cmd_issue(agent: &str, cap: &str, ttl: u32, scope: Option<&str>) -> anyhow::Result<()> {
    let payload = serde_json::json!({
        "agent": agent,
        "cap": cap,
        "ttl": ttl,
        "scope": scope,
    });
    let body: serde_json::Value = daemon_client::post_json("/api/v1/id/issue", &payload)
        .await
        .inspect_err(|e| {
            if e.to_string().contains("is lifeosd running") {
                println!(
                    "{}",
                    "Cannot connect to lifeosd. Is the daemon running?".red()
                );
            }
        })?;
    let token = &body["token"];
    println!("{}", "Capability token issued".green().bold());
    println!(
        "  Token ID: {}",
        token["token_id"].as_str().unwrap_or("?").cyan()
    );
    println!("  Subject:  {}", token["subject"].as_str().unwrap_or("?"));
    println!(
        "  Expires:  {}",
        token["expires_at"].as_str().unwrap_or("?").dimmed()
    );
    println!(
        "  Token:    {}",
        token["token"].as_str().unwrap_or("?").yellow()
    );
    Ok(())
}

async fn cmd_list(active: bool) -> anyhow::Result<()> {
    let path = format!(
        "/api/v1/id/list?active={}",
        if active { "true" } else { "false" }
    );
    let body: serde_json::Value = daemon_client::get_json(&path).await.inspect_err(|e| {
        if e.to_string().contains("is lifeosd running") {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
        }
    })?;
    println!("{}", "Identity tokens".bold().blue());
    println!();
    if let Some(tokens) = body["tokens"].as_array() {
        if tokens.is_empty() {
            println!("  {}", "No tokens found.".dimmed());
        } else {
            for token in tokens {
                let revoked = token["revoked"].as_bool().unwrap_or(false);
                let status = if revoked {
                    "revoked".red()
                } else {
                    "active".green()
                };
                println!(
                    "  {} [{}] {}",
                    token["token_id"].as_str().unwrap_or("?").cyan(),
                    status,
                    token["subject"].as_str().unwrap_or("?")
                );
                println!(
                    "    cap={} exp={}",
                    token["capabilities"]
                        .as_array()
                        .map(|caps| caps
                            .iter()
                            .filter_map(|c| c.as_str())
                            .collect::<Vec<_>>()
                            .join(","))
                        .unwrap_or_else(|| "?".to_string()),
                    token["expires_at"].as_str().unwrap_or("?").dimmed()
                );
            }
        }
    }
    Ok(())
}

async fn cmd_revoke(token_id: &str) -> anyhow::Result<()> {
    let payload = serde_json::json!({ "token_id": token_id });
    let _: serde_json::Value = daemon_client::post_json("/api/v1/id/revoke", &payload)
        .await
        .inspect_err(|e| {
            if e.to_string().contains("is lifeosd running") {
                println!(
                    "{}",
                    "Cannot connect to lifeosd. Is the daemon running?".red()
                );
            }
        })?;
    println!("{}", "Token revoked".green().bold());
    println!("  Token ID: {}", token_id.cyan());
    Ok(())
}
