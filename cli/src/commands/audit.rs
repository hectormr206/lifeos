use crate::daemon_client;
use clap::Args;
use colored::Colorize;

#[derive(Args)]
pub struct AuditArgs {
    /// Time period to query (e.g. 1h, 6h, 24h, 7d)
    #[arg(long, default_value = "24h")]
    pub since: String,

    /// Filter by event type (e.g. llm_call, tool, supervisor)
    #[arg(long, rename_all = "snake_case")]
    pub r#type: Option<String>,

    /// Output in JSON format
    #[arg(long)]
    pub json: bool,
}

pub async fn execute(args: AuditArgs) -> anyhow::Result<()> {
    if !args.json {
        println!("{}", "LifeOS Audit - Reliability Report".bold().blue());
        println!();
    }

    let mut report = serde_json::json!({});

    // Query the health endpoint for reliability stats
    match daemon_client::get_json::<serde_json::Value>("/api/v1/health").await {
        Ok(health) => {
            report["health"] = health;
        }
        Err(e) if e.to_string().contains("is lifeosd running") => {
            if args.json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "error": format!("Cannot reach lifeosd: {}", e),
                    }))?
                );
            } else {
                println!("  {} Cannot reach lifeosd", "X".red().bold());
                println!("    Error: {}", format!("{e}").dimmed());
            }
            return Ok(());
        }
        Err(e) => {
            if !args.json {
                println!(
                    "  {} Health endpoint returned an error: {}",
                    "!".yellow().bold(),
                    e
                );
            }
        }
    }

    // Query supervisor metrics for task-level audit data (best-effort)
    if let Ok(metrics) =
        daemon_client::get_json::<serde_json::Value>("/api/v1/supervisor/metrics").await
    {
        report["supervisor"] = metrics;
    }

    // Query skills diagnostics (best-effort)
    if let Ok(diag) =
        daemon_client::get_json::<serde_json::Value>("/api/v1/skills/diagnostics").await
    {
        report["skills"] = diag;
    }

    report["query"] = serde_json::json!({
        "since": args.since,
        "type": args.r#type,
    });

    if args.json {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("  Period: {}", args.since.cyan());
        if let Some(t) = &args.r#type {
            println!("  Filter: {}", t.cyan());
        }
        println!();

        // Health summary
        if let Some(health) = report.get("health") {
            if let Some(status) = health.get("status").and_then(|v| v.as_str()) {
                let colored_status = match status {
                    "ok" | "healthy" => status.green().bold(),
                    "degraded" => status.yellow().bold(),
                    _ => status.red().bold(),
                };
                println!("  {}: {}", "System Status".bold(), colored_status);
            }
            if let Some(score) = health.get("score").and_then(|v| v.as_u64()) {
                println!("  {}: {}%", "Health Score".bold(), score);
            }
        }

        // Supervisor stats
        if let Some(sup) = report.get("supervisor") {
            println!();
            println!("  {}", "Supervisor Metrics:".bold());
            if let Some(obj) = sup.as_object() {
                for (key, value) in obj {
                    let label = key.replace('_', " ");
                    println!("    {}: {}", label, value);
                }
            }
        }

        println!();
        println!(
            "  {}",
            "Tip: use --json for machine-readable output.".dimmed()
        );
        println!("  {}", "Tip: use --since 7d for longer history.".dimmed());
    }

    Ok(())
}
