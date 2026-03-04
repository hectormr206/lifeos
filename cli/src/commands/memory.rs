use clap::Subcommand;
use colored::Colorize;

use crate::daemon_client;

#[derive(Subcommand)]
pub enum MemoryCommands {
    /// Add an encrypted memory entry
    Add {
        /// Inline content (alternative to --file)
        content: Option<String>,
        /// Read content from file path
        #[arg(long)]
        file: Option<String>,
        /// Memory kind (note, event, task, decision)
        #[arg(long, default_value = "note")]
        kind: String,
        /// Memory scope (user, workspace, system)
        #[arg(long, default_value = "user")]
        scope: String,
        /// Tags associated with this memory entry (repeatable)
        #[arg(long)]
        tag: Vec<String>,
        /// Source descriptor for auditing
        #[arg(long)]
        source: Option<String>,
        /// Importance from 0 to 100
        #[arg(long, default_value_t = 50)]
        importance: u8,
    },
    /// List recent memory entries
    List {
        /// Maximum entries
        #[arg(short, long, default_value_t = 20)]
        limit: usize,
        /// Optional scope filter
        #[arg(long)]
        scope: Option<String>,
        /// Optional tag filter
        #[arg(long)]
        tag: Option<String>,
    },
    /// Search memory entries (lexical)
    Search {
        query: String,
        /// Maximum results
        #[arg(short, long, default_value_t = 10)]
        limit: usize,
        /// Optional scope filter
        #[arg(long)]
        scope: Option<String>,
        /// Search mode (lexical, semantic, hybrid)
        #[arg(long, default_value = "hybrid", value_parser = ["lexical", "semantic", "hybrid"])]
        mode: String,
    },
    /// Delete an entry by ID
    Delete { entry_id: String },
    /// Show memory store statistics
    Stats,
    /// Build contextual correlation graph (cross-source/tags/scopes)
    Graph {
        /// Maximum entries to sample
        #[arg(short, long, default_value_t = 200)]
        limit: usize,
        /// Optional output path
        #[arg(long)]
        output: Option<String>,
    },
    /// Export MCP-compatible context block from memory
    Mcp {
        query: String,
        /// Maximum resources in output
        #[arg(short, long, default_value_t = 5)]
        limit: usize,
    },
}

pub async fn execute(cmd: MemoryCommands) -> anyhow::Result<()> {
    match cmd {
        MemoryCommands::Add {
            content,
            file,
            kind,
            scope,
            tag,
            source,
            importance,
        } => {
            cmd_add(
                content.as_deref(),
                file.as_deref(),
                &kind,
                &scope,
                &tag,
                source.as_deref(),
                importance,
            )
            .await
        }
        MemoryCommands::List { limit, scope, tag } => {
            cmd_list(limit, scope.as_deref(), tag.as_deref()).await
        }
        MemoryCommands::Search {
            query,
            limit,
            scope,
            mode,
        } => cmd_search(&query, limit, scope.as_deref(), &mode).await,
        MemoryCommands::Delete { entry_id } => cmd_delete(&entry_id).await,
        MemoryCommands::Stats => cmd_stats().await,
        MemoryCommands::Graph { limit, output } => cmd_graph(limit, output.as_deref()).await,
        MemoryCommands::Mcp { query, limit } => cmd_mcp(&query, limit).await,
    }
}

fn daemon_url() -> String {
    daemon_client::daemon_url()
}

async fn cmd_add(
    content: Option<&str>,
    file: Option<&str>,
    kind: &str,
    scope: &str,
    tags: &[String],
    source: Option<&str>,
    importance: u8,
) -> anyhow::Result<()> {
    let content = if let Some(path) = file {
        std::fs::read_to_string(path)
            .map_err(|e| anyhow::anyhow!("Failed to read file '{}': {}", path, e))?
    } else {
        content.unwrap_or("").to_string()
    };
    if content.trim().is_empty() {
        anyhow::bail!("Provide content inline or with --file");
    }

    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/memory/entries", daemon_url()))
        .json(&serde_json::json!({
            "kind": kind,
            "scope": scope,
            "tags": tags,
            "source": source,
            "importance": importance,
            "content": content,
        }))
        .send()
        .await?;

    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to add memory entry: {}", body);
    }

    let body: serde_json::Value = resp.json().await?;
    let entry = &body["entry"];
    println!("{}", "Memory entry saved".green().bold());
    println!("  id: {}", entry["entry_id"].as_str().unwrap_or("?").cyan());
    println!("  kind: {}", entry["kind"].as_str().unwrap_or("?"));
    println!("  scope: {}", entry["scope"].as_str().unwrap_or("?"));
    Ok(())
}

async fn cmd_list(limit: usize, scope: Option<&str>, tag: Option<&str>) -> anyhow::Result<()> {
    let mut url = format!(
        "{}/api/v1/memory/entries?limit={}",
        daemon_url(),
        limit.max(1)
    );
    if let Some(scope) = scope {
        url.push_str("&scope=");
        url.push_str(scope);
    }
    if let Some(tag) = tag {
        url.push_str("&tag=");
        url.push_str(tag);
    }

    let client = daemon_client::authenticated_client();
    let resp = client.get(url).send().await?;
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to list memory entries: {}", body);
    }

    let body: serde_json::Value = resp.json().await?;
    println!("{}", "Memory entries".bold().blue());
    if let Some(entries) = body["entries"].as_array() {
        if entries.is_empty() {
            println!("  {}", "No memory entries.".dimmed());
            return Ok(());
        }
        for entry in entries {
            let entry_id = entry["entry_id"].as_str().unwrap_or("?");
            let kind = entry["kind"].as_str().unwrap_or("?");
            let scope = entry["scope"].as_str().unwrap_or("?");
            let content = entry["content"].as_str().unwrap_or("");
            let preview = if content.chars().count() > 90 {
                let mut truncated = content.chars().take(90).collect::<String>();
                truncated.push_str("...");
                truncated
            } else {
                content.to_string()
            };
            println!("  {} [{}:{}] {}", entry_id.cyan(), kind, scope, preview);
        }
    }
    Ok(())
}

async fn cmd_search(
    query: &str,
    limit: usize,
    scope: Option<&str>,
    mode: &str,
) -> anyhow::Result<()> {
    let mut url = format!(
        "{}/api/v1/memory/search?q={}&limit={}&mode={}",
        daemon_url(),
        query,
        limit.max(1),
        mode
    );
    if let Some(scope) = scope {
        url.push_str("&scope=");
        url.push_str(scope);
    }

    let client = daemon_client::authenticated_client();
    let resp = client.get(url).send().await?;
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to search memory entries: {}", body);
    }

    let body: serde_json::Value = resp.json().await?;
    println!("{}", "Memory search".bold().blue());
    if let Some(results) = body["results"].as_array() {
        if results.is_empty() {
            println!("  {}", "No matching memories.".dimmed());
            return Ok(());
        }
        for result in results {
            let score = result["score"].as_f64().unwrap_or(0.0);
            let entry = &result["entry"];
            let id = entry["entry_id"].as_str().unwrap_or("?");
            let content = entry["content"].as_str().unwrap_or("");
            println!("  {:.2} {} {}", score, id.cyan(), content);
        }
    }
    Ok(())
}

async fn cmd_delete(entry_id: &str) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .delete(format!(
            "{}/api/v1/memory/entries/{}",
            daemon_url(),
            entry_id
        ))
        .send()
        .await?;
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to delete memory entry: {}", body);
    }

    let body: serde_json::Value = resp.json().await?;
    if body["deleted"].as_bool().unwrap_or(false) {
        println!("{}", "Memory entry deleted".green().bold());
    } else {
        println!("{}", "Memory entry not found".yellow().bold());
    }
    println!("  id: {}", entry_id.cyan());
    Ok(())
}

async fn cmd_stats() -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!("{}/api/v1/memory/stats", daemon_url()))
        .send()
        .await?;
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to fetch memory stats: {}", body);
    }

    let body: serde_json::Value = resp.json().await?;
    println!("{}", "Memory stats".bold().blue());
    println!(
        "  total_entries: {}",
        body["total_entries"].as_u64().unwrap_or(0)
    );
    if let Some(kinds) = body["by_kind"].as_object() {
        if !kinds.is_empty() {
            println!("  by_kind:");
            for (kind, count) in kinds {
                println!("    {}: {}", kind.cyan(), count);
            }
        }
    }
    if let Some(scopes) = body["by_scope"].as_object() {
        if !scopes.is_empty() {
            println!("  by_scope:");
            for (scope, count) in scopes {
                println!("    {}: {}", scope.cyan(), count);
            }
        }
    }
    Ok(())
}

async fn cmd_mcp(query: &str, limit: usize) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .post(format!("{}/api/v1/memory/mcp/context", daemon_url()))
        .json(&serde_json::json!({
            "query": query,
            "limit": limit.max(1),
        }))
        .send()
        .await?;
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to build MCP memory context: {}", body);
    }
    let body: serde_json::Value = resp.json().await?;
    println!("{}", serde_json::to_string_pretty(&body)?);
    Ok(())
}

async fn cmd_graph(limit: usize, output: Option<&str>) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let resp = client
        .get(format!(
            "{}/api/v1/memory/graph?limit={}",
            daemon_url(),
            limit.max(1)
        ))
        .send()
        .await?;

    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to build memory graph: {}", body);
    }
    let body: serde_json::Value = resp.json().await?;
    let rendered = serde_json::to_string_pretty(&body)?;

    if let Some(path) = output {
        std::fs::write(path, &rendered)?;
        println!("{}", "Memory graph exported".green().bold());
        println!("  path: {}", path.cyan());
    } else {
        println!("{}", rendered);
    }
    Ok(())
}
