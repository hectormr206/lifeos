use clap::Subcommand;
use colored::Colorize;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Write;
use std::process::{Command, Stdio};

const POLICY_FILE: &str = "/var/lib/lifeos/permissions-policy.json";

#[derive(Subcommand)]
pub enum PermissionsCommands {
    /// Show granted permissions by app
    Show,
    /// Revoke permissions for an app (single resource or all)
    Revoke {
        app_id: String,
        /// Optional specific resource to revoke (omit to remove all app permissions)
        #[arg(long)]
        resource: Option<String>,
    },
    /// Show recent permission activity logs
    Log {
        /// Number of log lines to inspect
        #[arg(short, long, default_value_t = 100)]
        lines: usize,
    },
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct PermissionStore {
    granted: HashMap<String, Vec<String>>,
}

pub async fn execute(cmd: PermissionsCommands) -> anyhow::Result<()> {
    match cmd {
        PermissionsCommands::Show => cmd_show(),
        PermissionsCommands::Revoke { app_id, resource } => {
            cmd_revoke(&app_id, resource.as_deref())
        }
        PermissionsCommands::Log { lines } => cmd_log(lines),
    }
}

fn cmd_show() -> anyhow::Result<()> {
    let store = load_store()?;
    println!("{}", "Permissions policy".bold().blue());
    println!("  file: {}", POLICY_FILE.cyan());

    if store.granted.is_empty() {
        println!("  {}", "No grants stored.".dimmed());
        return Ok(());
    }

    let mut apps = store.granted.keys().cloned().collect::<Vec<_>>();
    apps.sort();
    for app in apps {
        println!();
        println!("  {}", app.cyan().bold());
        let perms = store.granted.get(&app).cloned().unwrap_or_default();
        if perms.is_empty() {
            println!("    {}", "(no resources)".dimmed());
        } else {
            for resource in perms {
                println!("    - {}", resource);
            }
        }
    }
    Ok(())
}

fn cmd_revoke(app_id: &str, resource: Option<&str>) -> anyhow::Result<()> {
    let mut store = load_store()?;
    let Some(existing) = store.granted.get_mut(app_id) else {
        println!("{}", "No permissions found for app".yellow().bold());
        println!("  app: {}", app_id.cyan());
        return Ok(());
    };

    let changed = if let Some(resource) = resource {
        let before = existing.len();
        existing.retain(|r| r != resource);
        before != existing.len()
    } else {
        existing.clear();
        true
    };

    if existing.is_empty() {
        store.granted.remove(app_id);
    }

    if !changed {
        println!("{}", "Resource not found for app".yellow().bold());
        println!("  app: {}", app_id.cyan());
        if let Some(resource) = resource {
            println!("  resource: {}", resource.cyan());
        }
        return Ok(());
    }

    persist_store(&store)?;
    println!("{}", "Permissions revoked".green().bold());
    println!("  app: {}", app_id.cyan());
    if let Some(resource) = resource {
        println!("  resource: {}", resource.cyan());
    } else {
        println!("  resource: {}", "all".cyan());
    }
    Ok(())
}

fn cmd_log(lines: usize) -> anyhow::Result<()> {
    let lines = lines.clamp(10, 1000).to_string();
    let output = Command::new("journalctl")
        .args([
            "-u",
            "lifeos-lifeosd.service",
            "-n",
            &lines,
            "--no-pager",
            "--output",
            "cat",
        ])
        .output()
        .or_else(|_| {
            Command::new("sudo")
                .args([
                    "-n",
                    "journalctl",
                    "-u",
                    "lifeos-lifeosd.service",
                    "-n",
                    &lines,
                    "--no-pager",
                    "--output",
                    "cat",
                ])
                .output()
        })
        .or_else(|_| {
            Command::new("sudo")
                .args([
                    "journalctl",
                    "-u",
                    "lifeos-lifeosd.service",
                    "-n",
                    &lines,
                    "--no-pager",
                    "--output",
                    "cat",
                ])
                .output()
        })?;

    if !output.status.success() {
        anyhow::bail!("Failed to read journalctl logs for lifeos-lifeosd.service");
    }

    let raw = String::from_utf8_lossy(&output.stdout);
    let filtered = raw
        .lines()
        .filter(|line| {
            let lc = line.to_lowercase();
            lc.contains("permission requested")
                || lc.contains("access granted")
                || lc.contains("access denied")
                || lc.contains("permissions policy")
        })
        .collect::<Vec<_>>();

    println!("{}", "Permission activity".bold().blue());
    if filtered.is_empty() {
        println!("  {}", "No recent permission log lines found.".dimmed());
    } else {
        for line in filtered {
            println!("  {}", line);
        }
    }
    Ok(())
}

fn load_store() -> anyhow::Result<PermissionStore> {
    if let Ok(content) = std::fs::read_to_string(POLICY_FILE) {
        return serde_json::from_str(&content)
            .map_err(|e| anyhow::anyhow!("Invalid policy JSON in {}: {}", POLICY_FILE, e));
    }

    let sudo_output = Command::new("sudo")
        .args(["-n", "cat", POLICY_FILE])
        .output()
        .or_else(|_| Command::new("sudo").args(["cat", POLICY_FILE]).output());

    match sudo_output {
        Ok(out) if out.status.success() => {
            let content = String::from_utf8_lossy(&out.stdout);
            serde_json::from_str(&content).map_err(|e| {
                anyhow::anyhow!("Invalid policy JSON in {} via sudo cat: {}", POLICY_FILE, e)
            })
        }
        _ => Ok(PermissionStore::default()),
    }
}

fn persist_store(store: &PermissionStore) -> anyhow::Result<()> {
    let content = serde_json::to_string_pretty(store)?;

    if std::fs::create_dir_all("/var/lib/lifeos").is_ok()
        && std::fs::write(POLICY_FILE, &content).is_ok()
    {
        return Ok(());
    }

    let _ = Command::new("sudo")
        .args(["mkdir", "-p", "/var/lib/lifeos"])
        .status();

    let mut child = Command::new("sudo")
        .args(["tee", POLICY_FILE])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    if let Some(stdin) = child.stdin.as_mut() {
        stdin.write_all(content.as_bytes())?;
    }
    let status = child.wait()?;
    if status.success() {
        Ok(())
    } else {
        anyhow::bail!("Failed to persist permissions policy (need elevated privileges)");
    }
}
