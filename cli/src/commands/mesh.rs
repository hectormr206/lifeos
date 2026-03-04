use clap::Subcommand;
use colored::Colorize;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::daemon_client;

#[derive(Subcommand)]
pub enum MeshCommands {
    /// Initialize local node identity for device-mesh
    Init {
        #[arg(long)]
        alias: String,
        #[arg(long, default_value = "127.0.0.1")]
        endpoint: String,
    },
    /// Register or update a remote node
    Add {
        node_id: String,
        #[arg(long)]
        alias: String,
        #[arg(long)]
        endpoint: String,
        #[arg(long, default_value = "verified", value_parser = ["core", "verified", "community"])]
        trust: String,
    },
    /// Delegate capability token to a node
    Delegate {
        node_id: String,
        #[arg(long, default_value = "mesh.sync")]
        capability: String,
        #[arg(long, default_value_t = 60)]
        ttl: u32,
    },
    /// Revoke node access and delegation token
    Revoke { node_id: String },
    /// List mesh nodes
    List {
        #[arg(long)]
        active: bool,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct MeshNode {
    node_id: String,
    alias: String,
    endpoint: String,
    trust: String,
    status: String,
    added_at: String,
    revoked_at: Option<String>,
    token_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct MeshRegistry {
    local_node_id: Option<String>,
    nodes: Vec<MeshNode>,
}

pub async fn execute(cmd: MeshCommands) -> anyhow::Result<()> {
    match cmd {
        MeshCommands::Init { alias, endpoint } => cmd_init(&alias, &endpoint),
        MeshCommands::Add {
            node_id,
            alias,
            endpoint,
            trust,
        } => cmd_add(&node_id, &alias, &endpoint, &trust),
        MeshCommands::Delegate {
            node_id,
            capability,
            ttl,
        } => cmd_delegate(&node_id, &capability, ttl).await,
        MeshCommands::Revoke { node_id } => cmd_revoke(&node_id).await,
        MeshCommands::List { active } => cmd_list(active),
    }
}

fn cmd_init(alias: &str, endpoint: &str) -> anyhow::Result<()> {
    let mut registry = load_registry()?;
    let node_id = format!("node-{}", unique_suffix());
    registry.local_node_id = Some(node_id.clone());
    upsert_node(
        &mut registry,
        MeshNode {
            node_id: node_id.clone(),
            alias: alias.to_string(),
            endpoint: endpoint.to_string(),
            trust: "core".to_string(),
            status: "active".to_string(),
            added_at: chrono::Utc::now().to_rfc3339(),
            revoked_at: None,
            token_id: None,
        },
    );
    save_registry(&registry)?;

    println!("{}", "Device-mesh local node initialized".green().bold());
    println!("  node_id: {}", node_id.cyan());
    println!("  alias: {}", alias.cyan());
    println!("  endpoint: {}", endpoint.cyan());
    Ok(())
}

fn cmd_add(node_id: &str, alias: &str, endpoint: &str, trust: &str) -> anyhow::Result<()> {
    let mut registry = load_registry()?;
    upsert_node(
        &mut registry,
        MeshNode {
            node_id: node_id.to_string(),
            alias: alias.to_string(),
            endpoint: endpoint.to_string(),
            trust: trust.to_string(),
            status: "active".to_string(),
            added_at: chrono::Utc::now().to_rfc3339(),
            revoked_at: None,
            token_id: None,
        },
    );
    save_registry(&registry)?;

    println!("{}", "Mesh node registered".green().bold());
    println!("  node_id: {}", node_id.cyan());
    println!("  trust: {}", trust.cyan());
    Ok(())
}

async fn cmd_delegate(node_id: &str, capability: &str, ttl: u32) -> anyhow::Result<()> {
    let mut registry = load_registry()?;
    let node_idx = registry
        .nodes
        .iter()
        .position(|n| n.node_id == node_id)
        .ok_or_else(|| anyhow::anyhow!("Node not found: {}", node_id))?;
    if registry.nodes[node_idx].status != "active" {
        anyhow::bail!("Node is not active: {}", node_id);
    }

    let client = daemon_client::authenticated_client();
    let response = client
        .post(format!("{}/api/v1/id/issue", daemon_client::daemon_url()))
        .json(&serde_json::json!({
            "agent": format!("mesh-{}", node_id),
            "capability": capability,
            "ttl_minutes": ttl,
            "scope": format!("scope://mesh/{}", node_id),
        }))
        .send()
        .await?;

    if !response.status().is_success() {
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!("Failed to delegate token: {}", body);
    }
    let body: serde_json::Value = response.json().await?;
    let token_id = body["token"]["token_id"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("Daemon response missing token_id"))?;

    registry.nodes[node_idx].token_id = Some(token_id.to_string());
    save_registry(&registry)?;

    println!("{}", "Delegation issued".green().bold());
    println!("  node_id: {}", node_id.cyan());
    println!("  capability: {}", capability.cyan());
    println!("  token_id: {}", token_id.cyan());
    Ok(())
}

async fn cmd_revoke(node_id: &str) -> anyhow::Result<()> {
    let mut registry = load_registry()?;
    let node_idx = registry
        .nodes
        .iter()
        .position(|n| n.node_id == node_id)
        .ok_or_else(|| anyhow::anyhow!("Node not found: {}", node_id))?;
    let token_id = registry.nodes[node_idx].token_id.clone();

    if let Some(token_id) = token_id {
        let client = daemon_client::authenticated_client();
        let _ = client
            .post(format!("{}/api/v1/id/revoke", daemon_client::daemon_url()))
            .json(&serde_json::json!({ "token_id": token_id }))
            .send()
            .await;
    }

    registry.nodes[node_idx].status = "revoked".to_string();
    registry.nodes[node_idx].revoked_at = Some(chrono::Utc::now().to_rfc3339());
    save_registry(&registry)?;

    println!("{}", "Mesh node revoked".yellow().bold());
    println!("  node_id: {}", node_id.cyan());
    Ok(())
}

fn cmd_list(active_only: bool) -> anyhow::Result<()> {
    let registry = load_registry()?;
    println!("{}", "Device mesh nodes".bold().blue());
    if let Some(local) = &registry.local_node_id {
        println!("  local_node_id: {}", local.cyan());
    }

    let mut count = 0usize;
    for node in &registry.nodes {
        if active_only && node.status != "active" {
            continue;
        }
        count += 1;
        println!(
            "  {} [{}] {} {}",
            node.node_id.cyan(),
            node.status,
            node.alias,
            node.endpoint.dimmed()
        );
        if let Some(token_id) = &node.token_id {
            println!("    token_id: {}", token_id.dimmed());
        }
    }
    if count == 0 {
        println!("  {}", "No nodes found.".dimmed());
    }
    Ok(())
}

fn upsert_node(registry: &mut MeshRegistry, node: MeshNode) {
    if let Some(existing) = registry
        .nodes
        .iter_mut()
        .find(|n| n.node_id == node.node_id)
    {
        *existing = node;
    } else {
        registry.nodes.push(node);
    }
}

fn mesh_registry_path() -> PathBuf {
    if let Ok(custom) = std::env::var("LIFEOS_MESH_DIR") {
        let custom = PathBuf::from(custom);
        if !custom.as_os_str().is_empty() {
            return custom.join("registry.json");
        }
    }

    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("lifeos")
        .join("device-mesh")
        .join("registry.json")
}

fn load_registry() -> anyhow::Result<MeshRegistry> {
    let path = mesh_registry_path();
    if !path.exists() {
        return Ok(MeshRegistry::default());
    }
    let raw = std::fs::read_to_string(&path)?;
    let registry = serde_json::from_str::<MeshRegistry>(&raw)
        .map_err(|e| anyhow::anyhow!("Invalid mesh registry '{}': {}", path.display(), e))?;
    Ok(registry)
}

fn save_registry(registry: &MeshRegistry) -> anyhow::Result<()> {
    let path = mesh_registry_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, serde_json::to_string_pretty(registry)?)?;
    Ok(())
}

fn unique_suffix() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos().to_string())
        .unwrap_or_else(|_| "0".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(prefix: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("{}-{}", prefix, unique_suffix()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn mesh_registry_roundtrip() {
        let base = temp_dir("life-mesh-test");
        std::env::set_var("LIFEOS_MESH_DIR", &base);

        let mut registry = MeshRegistry::default();
        upsert_node(
            &mut registry,
            MeshNode {
                node_id: "node-1".to_string(),
                alias: "workstation".to_string(),
                endpoint: "10.0.0.10".to_string(),
                trust: "verified".to_string(),
                status: "active".to_string(),
                added_at: chrono::Utc::now().to_rfc3339(),
                revoked_at: None,
                token_id: None,
            },
        );
        save_registry(&registry).unwrap();

        let loaded = load_registry().unwrap();
        assert_eq!(loaded.nodes.len(), 1);
        assert_eq!(loaded.nodes[0].alias, "workstation");

        std::fs::remove_dir_all(base).ok();
    }
}
