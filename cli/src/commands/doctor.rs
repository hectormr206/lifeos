use crate::daemon_client;
use clap::Args;
use colored::Colorize;

#[derive(Args)]
pub struct DoctorArgs {
    /// Attempt to automatically repair detected issues
    #[arg(long)]
    pub repair: bool,

    /// Output in JSON format
    #[arg(long)]
    pub json: bool,
}

pub async fn execute(args: DoctorArgs) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let base = daemon_client::daemon_url();

    if !args.json {
        println!("{}", "LifeOS Doctor - System Health Check".bold().blue());
        println!();
    }

    // Deep health check via daemon API
    let url = format!("{}/api/v1/health", base);
    let resp = client.get(&url).send().await;

    match resp {
        Ok(r) if r.status().is_success() => {
            let health: serde_json::Value = r
                .json()
                .await
                .unwrap_or_else(|_| serde_json::json!({"status": "unknown"}));

            if args.json {
                println!("{}", serde_json::to_string_pretty(&health)?);
            } else {
                print_health_report(&health);
            }
        }
        Ok(r) => {
            let status = r.status();
            if args.json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "status": "error",
                        "daemon_reachable": true,
                        "http_status": status.as_u16(),
                        "message": format!("Daemon returned {}", status)
                    }))?
                );
            } else {
                println!(
                    "  {} Daemon reachable but returned HTTP {}",
                    "!".yellow().bold(),
                    status
                );
                if status.as_u16() == 401 {
                    println!(
                        "    {} Bootstrap token may be missing or invalid",
                        "Hint:".dimmed()
                    );
                }
            }
        }
        Err(e) => {
            if args.json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "status": "unreachable",
                        "daemon_reachable": false,
                        "message": format!("Cannot reach lifeosd: {}", e)
                    }))?
                );
            } else {
                println!(
                    "  {} Cannot reach lifeosd at {}",
                    "X".red().bold(),
                    base.dimmed()
                );
                println!("    Error: {}", format!("{e}").dimmed());
                println!();
                println!("  {} Is the daemon running?", "Hint:".dimmed());
                println!(
                    "    {}",
                    "sudo systemctl status lifeos-lifeosd.service".cyan()
                );
            }
        }
    }

    if args.repair {
        println!();
        run_repair(&base, args.json).await?;
    }

    Ok(())
}

/// Result of a single repair step.
#[derive(Clone)]
struct StepResult {
    label: String,
    status: StepStatus,
    detail: Option<String>,
}

#[derive(Clone, PartialEq)]
enum StepStatus {
    Ok,
    Skip,
    Fail,
}

impl StepResult {
    fn ok(label: &str) -> Self {
        Self {
            label: label.to_string(),
            status: StepStatus::Ok,
            detail: None,
        }
    }
    fn skip(label: &str, reason: &str) -> Self {
        Self {
            label: label.to_string(),
            status: StepStatus::Skip,
            detail: Some(reason.to_string()),
        }
    }
    fn fail(label: &str, reason: &str) -> Self {
        Self {
            label: label.to_string(),
            status: StepStatus::Fail,
            detail: Some(reason.to_string()),
        }
    }
}

/// Run a systemctl command in the system scope, returning Ok(true) on success.
///
/// Phase 3 of the architecture pivot moved lifeosd from a user-scope service
/// (`systemctl --user lifeosd`) to a system Quadlet (`lifeos-lifeosd.service`).
/// Repair operations now run against the system scope and require root;
/// `life doctor --repair` is invoked via sudo or via the polkit rule that
/// allowlists `lifeos-lifeosd.service` for wheel users.
async fn systemctl_system(args: &[&str]) -> anyhow::Result<bool> {
    let output = tokio::process::Command::new("systemctl")
        .args(args)
        .output()
        .await?;
    Ok(output.status.success())
}

/// Check whether the daemon health endpoint returns a success status.
async fn check_health(client: &reqwest::Client, base: &str) -> bool {
    let url = format!("{}/api/v1/health", base);
    match client.get(&url).send().await {
        Ok(r) => r.status().is_success(),
        Err(_) => false,
    }
}

/// Attempt a best-effort POST to a daemon endpoint. Returns true if the
/// endpoint responded with 2xx, false on any error (including 404).
async fn try_post(client: &reqwest::Client, base: &str, path: &str) -> bool {
    let url = format!("{}{}", base, path);
    match client.post(&url).send().await {
        Ok(r) => r.status().is_success(),
        Err(_) => false,
    }
}

async fn run_repair(base: &str, json_mode: bool) -> anyhow::Result<()> {
    let total_steps = 6;
    let mut results: Vec<StepResult> = Vec::with_capacity(total_steps);

    if !json_mode {
        println!("  {} Running automatic repair...", "*".cyan().bold());
        println!();
    }

    // --- Step 1: Reset failed services ---
    let step1 = match systemctl_system(&["reset-failed", "lifeos-lifeosd.service"]).await {
        Ok(true) => StepResult::ok("Resetting failed services"),
        Ok(false) => StepResult::fail("Resetting failed services", "reset-failed exited non-zero"),
        Err(e) => StepResult::fail("Resetting failed services", &format!("{e}")),
    };
    if !json_mode {
        print_step(1, total_steps, &step1);
    }
    results.push(step1);

    // --- Step 2: Restart the daemon ---
    let step2 = match systemctl_system(&["restart", "lifeos-lifeosd.service"]).await {
        Ok(true) => StepResult::ok("Restarting lifeosd"),
        Ok(false) => StepResult::fail("Restarting lifeosd", "restart exited non-zero"),
        Err(e) => StepResult::fail("Restarting lifeosd", &format!("{e}")),
    };
    if !json_mode {
        print_step(2, total_steps, &step2);
    }
    results.push(step2);

    // --- Step 3: Wait for daemon startup ---
    if !json_mode {
        print!(
            "  [{}/{}] {:<42}",
            3, total_steps, "Waiting for daemon startup..."
        );
    }
    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    results.push(StepResult::ok("Waiting for daemon startup"));
    if !json_mode {
        println!("{}", "OK".green().bold());
    }

    // --- Step 4: Check health ---
    // Rebuild the client AFTER the restart: lifeosd regenerates its
    // bootstrap token on every start, so the `client` we were given at
    // the top of execute() is stamped with the PRE-restart token and
    // would always see HTTP 401 against the freshly-started daemon —
    // causing step 4 to report "daemon not healthy after restart" even
    // when the daemon is perfectly healthy and just answering with a
    // new token.
    let client_after_restart = crate::daemon_client::authenticated_client();
    let healthy_after_restart = check_health(&client_after_restart, base).await;
    let step4 = if healthy_after_restart {
        StepResult::ok("Checking health")
    } else {
        StepResult::fail("Checking health", "daemon not healthy after restart")
    };
    if !json_mode {
        print_step(4, total_steps, &step4);
    }
    results.push(step4);

    // --- Step 5: Deeper repairs (only if still unhealthy) ---
    if healthy_after_restart {
        let step5 = StepResult::skip("Deeper repairs", "daemon healthy");
        if !json_mode {
            print_step(5, total_steps, &step5);
        }
        results.push(step5);
    } else {
        if !json_mode {
            print!(
                "  [{}/{}] {:<42}",
                5, total_steps, "Attempting deeper repairs..."
            );
        }
        let mut sub_results: Vec<String> = Vec::new();

        // Reset LLM router — use the post-restart client so the
        // bootstrap token matches the daemon that's running now.
        if try_post(&client_after_restart, base, "/api/v1/ai/reset").await {
            sub_results.push("llm-router: reset".into());
        }
        // Clear stuck tasks
        if try_post(&client_after_restart, base, "/api/v1/tasks/clear-stuck").await {
            sub_results.push("stuck-tasks: cleared".into());
        }
        // Disable safe mode
        if try_post(&client_after_restart, base, "/api/v1/safe-mode/exit").await {
            sub_results.push("safe-mode: disabled".into());
        }

        let step5 = if sub_results.is_empty() {
            StepResult::fail("Deeper repairs", "no repair endpoints responded")
        } else {
            StepResult {
                label: "Deeper repairs".into(),
                status: StepStatus::Ok,
                detail: Some(sub_results.join(", ")),
            }
        };
        if !json_mode {
            match &step5.status {
                StepStatus::Ok => println!("{}", "OK".green().bold()),
                StepStatus::Fail => println!("{}", "FAIL".red().bold()),
                StepStatus::Skip => println!("{}", "SKIP".yellow()),
            }
            if let Some(ref detail) = step5.detail {
                println!("         {}", detail.dimmed());
            }
        }
        results.push(step5);
    }

    // --- Step 6: Verify final state ---
    // If deeper repairs were attempted, give the daemon a moment
    if !healthy_after_restart {
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
    let final_healthy = check_health(&client_after_restart, base).await;
    let step6 = if final_healthy {
        StepResult::ok("Verifying final state")
    } else {
        StepResult::fail("Verifying final state", "daemon still unhealthy")
    };
    if !json_mode {
        print_step(6, total_steps, &step6);
    }
    results.push(step6);

    // --- Summary ---
    let any_failed = results.iter().any(|r| r.status == StepStatus::Fail);

    if json_mode {
        let steps_json: Vec<serde_json::Value> = results
            .iter()
            .map(|r| {
                serde_json::json!({
                    "step": r.label,
                    "status": match r.status {
                        StepStatus::Ok => "ok",
                        StepStatus::Skip => "skip",
                        StepStatus::Fail => "fail",
                    },
                    "detail": r.detail,
                })
            })
            .collect();
        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({
                "repair": if any_failed { "partial" } else { "success" },
                "daemon_healthy": final_healthy,
                "steps": steps_json,
            }))?
        );
    } else {
        println!();
        if any_failed {
            println!(
                "  {} Repair completed with errors. Manual intervention may be needed.",
                "!".yellow().bold()
            );
            if !final_healthy {
                println!(
                    "    {} Check daemon logs: {}",
                    "Hint:".dimmed(),
                    "sudo journalctl -u lifeos-lifeosd.service -n 50".cyan()
                );
            }
        } else {
            println!("  {} Repair completed successfully.", "+".green().bold());
        }
    }

    Ok(())
}

fn print_step(num: usize, total: usize, result: &StepResult) {
    let status_str = match result.status {
        StepStatus::Ok => "OK".green().bold(),
        StepStatus::Skip => {
            let reason = result.detail.as_deref().unwrap_or("");
            return println!(
                "  [{}/{}] {:<42}{} ({})",
                num,
                total,
                result.label,
                "SKIP".yellow(),
                reason.dimmed()
            );
        }
        StepStatus::Fail => "FAIL".red().bold(),
    };
    println!("  [{}/{}] {:<42}{}", num, total, result.label, status_str);
    if result.status == StepStatus::Fail {
        if let Some(ref detail) = result.detail {
            println!("         {}", detail.dimmed());
        }
    }
}

fn print_health_report(health: &serde_json::Value) {
    // Overall status
    if let Some(status) = health.get("status").and_then(|v| v.as_str()) {
        let colored_status = match status {
            "ok" | "healthy" => status.green().bold(),
            "degraded" => status.yellow().bold(),
            _ => status.red().bold(),
        };
        println!("  Overall: {}", colored_status);
    }

    // Print each component if present
    if let Some(components) = health.get("components").and_then(|v| v.as_object()) {
        println!();
        println!("  {}", "Components:".bold());
        for (name, value) in components {
            let indicator = if value
                .get("healthy")
                .and_then(|v| v.as_bool())
                .unwrap_or(false)
            {
                "OK".green()
            } else {
                "FAIL".red()
            };
            println!("    {} {}", indicator, name);
            if let Some(msg) = value.get("message").and_then(|v| v.as_str()) {
                println!("      {}", msg.dimmed());
            }
        }
    }

    // If the response is flat (no components key), just pretty-print
    if health.get("components").is_none() && health.get("status").is_some() {
        if let Some(obj) = health.as_object() {
            for (key, value) in obj {
                if key == "status" {
                    continue;
                }
                println!("  {}: {}", key.bold(), value);
            }
        }
    }

    println!();
}
