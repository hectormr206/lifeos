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

fn daemon_url() -> String {
    daemon_client::daemon_url()
}

async fn cmd_issue(agent: &str, cap: &str, ttl: u32, scope: Option<&str>) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/id/issue", daemon_url()))
        .json(&serde_json::json!({
            "agent": agent,
            "cap": cap,
            "ttl": ttl,
            "scope": scope,
        }))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
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
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to issue token: {}", body);
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

async fn cmd_list(active: bool) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!(
            "{}/api/v1/id/list?active={}",
            daemon_url(),
            if active { "true" } else { "false" }
        ))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r.json().await?;
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
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to list tokens: {}", body);
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

async fn cmd_revoke(token_id: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/id/revoke", daemon_url()))
        .json(&serde_json::json!({ "token_id": token_id }))
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            println!("{}", "Token revoked".green().bold());
            println!("  Token ID: {}", token_id.cyan());
            Ok(())
        }
        Ok(r) => {
            let body = r.text().await.unwrap_or_default();
            anyhow::bail!("Failed to revoke token: {}", body);
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
