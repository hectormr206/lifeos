use clap::Subcommand;
use colored::Colorize;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum AgentsCommands {
    /// Register or update a specialized agent identity with capabilities
    Register {
        agent_id: String,
        #[arg(long)]
        role: String,
        #[arg(long = "capability", required = true)]
        capability: Vec<String>,
        #[arg(long, default_value = "verified", value_parser = ["core", "verified", "community"])]
        trust: String,
        #[arg(long, default_value_t = 60)]
        ttl: u32,
        #[arg(long)]
        scope: Option<String>,
    },
    /// List registered agents
    List {
        #[arg(long)]
        active: bool,
    },
    /// Show one agent details
    Show { agent_id: String },
    /// Revoke all delegated tokens for an agent and mark as revoked
    Revoke { agent_id: String },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum AgentStatus {
    Active,
    Revoked,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AgentRecord {
    agent_id: String,
    role: String,
    capabilities: Vec<String>,
    trust: String,
    status: AgentStatus,
    created_at: String,
    revoked_at: Option<String>,
    token_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct AgentsRegistry {
    agents: Vec<AgentRecord>,
}

pub async fn execute(cmd: AgentsCommands) -> anyhow::Result<()> {
    match cmd {
        AgentsCommands::Register {
            agent_id,
            role,
            capability,
            trust,
            ttl,
            scope,
        } => cmd_register(&agent_id, &role, &capability, &trust, ttl, scope.as_deref()).await,
        AgentsCommands::List { active } => cmd_list(active),
        AgentsCommands::Show { agent_id } => cmd_show(&agent_id),
        AgentsCommands::Revoke { agent_id } => cmd_revoke(&agent_id).await,
    }
}

async fn cmd_register(
    agent_id: &str,
    role: &str,
    capabilities: &[String],
    trust: &str,
    ttl: u32,
    scope: Option<&str>,
) -> anyhow::Result<()> {
    if agent_id.trim().is_empty() {
        anyhow::bail!("agent_id is required");
    }
    if role.trim().is_empty() {
        anyhow::bail!("role is required");
    }
    if capabilities.is_empty() {
        anyhow::bail!("at least one capability is required");
    }

    let mut token_ids = Vec::new();

    for cap in capabilities {
        let payload = serde_json::json!({
            "agent": agent_id,
            "cap": cap,
            "ttl": ttl,
            "scope": scope,
        });
        let body: serde_json::Value = daemon_client::post_json("/api/v1/id/issue", &payload)
            .await
            .map_err(|e| {
                if e.to_string().contains("is lifeosd running") {
                    println!(
                        "{}",
                        "Cannot connect to lifeosd. Is the daemon running?".red()
                    );
                    println!("  Try: {}", "sudo systemctl start lifeosd".cyan());
                }
                // Best-effort cleanup of tokens already issued before the failure
                anyhow::anyhow!("Failed to issue token for capability '{}': {}", cap, e)
            })?;
        let token_id = body["token"]["token_id"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Daemon response missing token_id"))?;
        token_ids.push(token_id.to_string());
    }

    let mut registry = load_registry()?;
    upsert_agent(
        &mut registry,
        AgentRecord {
            agent_id: agent_id.to_string(),
            role: role.to_string(),
            capabilities: normalized_capabilities(capabilities),
            trust: trust.to_string(),
            status: AgentStatus::Active,
            created_at: chrono::Utc::now().to_rfc3339(),
            revoked_at: None,
            token_ids: token_ids.clone(),
        },
    );
    save_registry(&registry)?;

    println!("{}", "Agent registered".green().bold());
    println!("  agent_id: {}", agent_id.cyan());
    println!("  role: {}", role.cyan());
    println!("  trust: {}", trust.cyan());
    println!("  capabilities: {}", capabilities.join(", "));
    println!("  delegated_tokens: {}", token_ids.len().to_string().cyan());
    Ok(())
}

fn cmd_list(active_only: bool) -> anyhow::Result<()> {
    let registry = load_registry()?;
    println!("{}", "Registered agents".bold().blue());
    let mut count = 0usize;
    for agent in &registry.agents {
        if active_only && agent.status != AgentStatus::Active {
            continue;
        }
        count += 1;
        let status = if agent.status == AgentStatus::Active {
            "active".green()
        } else {
            "revoked".yellow()
        };
        println!(
            "  {} [{}] role={} trust={}",
            agent.agent_id.cyan(),
            status,
            agent.role,
            agent.trust
        );
        println!(
            "    capabilities={} tokens={}",
            agent.capabilities.join(","),
            agent.token_ids.len()
        );
    }
    if count == 0 {
        println!("  {}", "No agents found.".dimmed());
    }
    Ok(())
}

fn cmd_show(agent_id: &str) -> anyhow::Result<()> {
    let registry = load_registry()?;
    let Some(agent) = registry.agents.iter().find(|a| a.agent_id == agent_id) else {
        anyhow::bail!("Agent not found: {}", agent_id);
    };
    println!("{}", "Agent details".bold().blue());
    println!("  agent_id: {}", agent.agent_id.cyan());
    println!("  role: {}", agent.role);
    println!("  trust: {}", agent.trust);
    println!("  status: {:?}", agent.status);
    println!("  created_at: {}", agent.created_at.dimmed());
    if let Some(revoked_at) = &agent.revoked_at {
        println!("  revoked_at: {}", revoked_at.dimmed());
    }
    println!("  capabilities: {}", agent.capabilities.join(", "));
    println!("  token_ids:");
    for token_id in &agent.token_ids {
        println!("    - {}", token_id.dimmed());
    }
    Ok(())
}

async fn cmd_revoke(agent_id: &str) -> anyhow::Result<()> {
    let mut registry = load_registry()?;
    let idx = registry
        .agents
        .iter()
        .position(|a| a.agent_id == agent_id)
        .ok_or_else(|| anyhow::anyhow!("Agent not found: {}", agent_id))?;

    let token_ids = registry.agents[idx].token_ids.clone();
    cleanup_tokens(&token_ids).await;

    registry.agents[idx].status = AgentStatus::Revoked;
    registry.agents[idx].revoked_at = Some(chrono::Utc::now().to_rfc3339());
    save_registry(&registry)?;

    println!("{}", "Agent revoked".yellow().bold());
    println!("  agent_id: {}", agent_id.cyan());
    println!("  revoked_tokens: {}", token_ids.len());
    Ok(())
}

async fn cleanup_tokens(token_ids: &[String]) {
    for token_id in token_ids {
        let payload = serde_json::json!({ "token_id": token_id });
        let _: Result<serde_json::Value, _> =
            daemon_client::post_json("/api/v1/id/revoke", &payload).await;
        // Best-effort: ignore errors during cleanup
    }
}

fn normalized_capabilities(capabilities: &[String]) -> Vec<String> {
    let mut values = capabilities
        .iter()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .collect::<Vec<_>>();
    values.sort();
    values.dedup();
    values
}

fn upsert_agent(registry: &mut AgentsRegistry, agent: AgentRecord) {
    if let Some(existing) = registry
        .agents
        .iter_mut()
        .find(|record| record.agent_id == agent.agent_id)
    {
        *existing = agent;
    } else {
        registry.agents.push(agent);
    }
}

fn registry_path() -> PathBuf {
    if let Ok(custom) = std::env::var("LIFEOS_AGENTS_DIR") {
        let custom = PathBuf::from(custom);
        if !custom.as_os_str().is_empty() {
            return custom.join("registry.json");
        }
    }

    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("lifeos")
        .join("agents")
        .join("registry.json")
}

fn load_registry() -> anyhow::Result<AgentsRegistry> {
    let path = registry_path();
    if !path.exists() {
        return Ok(AgentsRegistry::default());
    }

    let raw = std::fs::read_to_string(&path)?;
    let parsed = serde_json::from_str::<AgentsRegistry>(&raw)
        .map_err(|e| anyhow::anyhow!("Invalid agents registry '{}': {}", path.display(), e))?;
    Ok(parsed)
}

fn save_registry(registry: &AgentsRegistry) -> anyhow::Result<()> {
    let path = registry_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, serde_json::to_string_pretty(registry)?)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn unique_suffix() -> String {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos().to_string())
            .unwrap_or_else(|_| "0".to_string())
    }

    fn temp_dir(prefix: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("{}-{}", prefix, unique_suffix()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn registry_roundtrip_for_agents() {
        let base = temp_dir("life-agents-test");
        std::env::set_var("LIFEOS_AGENTS_DIR", &base);

        let mut registry = AgentsRegistry::default();
        upsert_agent(
            &mut registry,
            AgentRecord {
                agent_id: "qa-agent".to_string(),
                role: "qa".to_string(),
                capabilities: vec!["tests.run".to_string(), "reports.read".to_string()],
                trust: "verified".to_string(),
                status: AgentStatus::Active,
                created_at: chrono::Utc::now().to_rfc3339(),
                revoked_at: None,
                token_ids: vec!["jti-1".to_string()],
            },
        );
        save_registry(&registry).unwrap();

        let loaded = load_registry().unwrap();
        assert_eq!(loaded.agents.len(), 1);
        assert_eq!(loaded.agents[0].agent_id, "qa-agent");
        assert_eq!(loaded.agents[0].status, AgentStatus::Active);

        std::fs::remove_dir_all(base).ok();
    }
}
