use clap::Subcommand;
use colored::Colorize;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Write;
use std::process::{Command, Stdio};

const PORTAL_POLICY_FILE: &str = "/var/lib/lifeos/portal-permissions.json";
const AUDIT_LOG_FILE: &str = "/var/log/lifeos/portal-audit.log";

#[derive(Subcommand)]
pub enum PortalCommands {
    /// Show portal service status
    Status,
    /// List permissions for an app
    Permissions { app_id: String },
    /// Grant a permission to an app
    Grant { app_id: String, permission: String },
    /// Revoke a permission from an app
    Revoke { app_id: String, permission: String },
    /// Show all permission grants across all apps
    Audit {
        /// Number of recent audit entries to show
        #[arg(short, long, default_value_t = 50)]
        lines: usize,
    },
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct PortalPermission {
    resource: String,
    granted_at: String,
    reason: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct PortalPermissionStore {
    granted: HashMap<String, Vec<PortalPermission>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AuditEntry {
    timestamp: String,
    app_id: String,
    permission: String,
    action: String,
    reason: Option<String>,
}

pub async fn execute(cmd: PortalCommands) -> anyhow::Result<()> {
    match cmd {
        PortalCommands::Status => cmd_status(),
        PortalCommands::Permissions { app_id } => cmd_permissions(&app_id),
        PortalCommands::Grant { app_id, permission } => cmd_grant(&app_id, &permission),
        PortalCommands::Revoke { app_id, permission } => cmd_revoke(&app_id, &permission),
        PortalCommands::Audit { lines } => cmd_audit(lines),
    }
}

fn cmd_status() -> anyhow::Result<()> {
    println!("{}", "LifeOS Portal Status".bold().blue());
    println!();

    let dbus_check = Command::new("busctl")
        .args(["--user", "list", "--no-pager"])
        .output();

    let dbus_active = match dbus_check {
        Ok(output) if output.status.success() => String::from_utf8_lossy(&output.stdout)
            .lines()
            .any(|line| line.contains("org.lifeos.Portal")),
        _ => false,
    };

    if dbus_active {
        println!("  D-Bus Service: {}", "active".green());
    } else {
        println!("  D-Bus Service: {}", "inactive".yellow());
    }

    let policy_exists = std::path::Path::new(PORTAL_POLICY_FILE).exists();
    println!(
        "  Policy File: {}",
        if policy_exists {
            PORTAL_POLICY_FILE.cyan()
        } else {
            "not found".yellow()
        }
    );

    let audit_exists = std::path::Path::new(AUDIT_LOG_FILE).exists();
    println!(
        "  Audit Log: {}",
        if audit_exists {
            AUDIT_LOG_FILE.cyan()
        } else {
            "not found".dimmed()
        }
    );

    if let Ok(store) = load_store() {
        let total_apps = store.granted.len();
        let total_perms: usize = store.granted.values().map(|v| v.len()).sum();
        println!("  Registered Apps: {}", total_apps.to_string().cyan());
        println!("  Total Permissions: {}", total_perms.to_string().cyan());
    }

    Ok(())
}

fn cmd_permissions(app_id: &str) -> anyhow::Result<()> {
    let store = load_store()?;

    println!(
        "{}",
        format!("Portal Permissions for {}", app_id).bold().blue()
    );

    match store.granted.get(app_id) {
        Some(perms) if !perms.is_empty() => {
            for perm in perms {
                println!();
                println!("  Resource: {}", perm.resource.cyan());
                println!("  Granted: {}", perm.granted_at.dimmed());
                if let Some(ref reason) = perm.reason {
                    println!("  Reason: {}", reason.dimmed());
                }
            }
        }
        _ => {
            println!();
            println!("  {}", "No permissions granted".dimmed());
        }
    }

    Ok(())
}

fn cmd_grant(app_id: &str, permission: &str) -> anyhow::Result<()> {
    let mut store = load_store()?;

    let new_perm = PortalPermission {
        resource: permission.to_string(),
        granted_at: chrono::Local::now().to_rfc3339(),
        reason: Some("manual grant via CLI".to_string()),
    };

    let app_perms = store
        .granted
        .entry(app_id.to_string())
        .or_insert_with(Vec::new);

    if app_perms.iter().any(|p| p.resource == permission) {
        println!("{}", "Permission already exists".yellow());
        println!("  app: {}", app_id.cyan());
        println!("  permission: {}", permission.cyan());
        return Ok(());
    }

    app_perms.push(new_perm);
    persist_store(&store)?;

    println!("{}", "Permission granted".green());
    println!("  app: {}", app_id.cyan());
    println!("  permission: {}", permission.cyan());

    log_audit_manual(app_id, permission, "granted")?;

    Ok(())
}

fn cmd_revoke(app_id: &str, permission: &str) -> anyhow::Result<()> {
    let mut store = load_store()?;

    let Some(app_perms) = store.granted.get_mut(app_id) else {
        println!("{}", "No permissions found for app".yellow());
        println!("  app: {}", app_id.cyan());
        return Ok(());
    };

    let is_empty = {
        let before = app_perms.len();
        app_perms.retain(|p| p.resource != permission);
        let changed = app_perms.len() != before;
        if !changed {
            println!("{}", "Permission not found for app".yellow());
            println!("  app: {}", app_id.cyan());
            println!("  permission: {}", permission.cyan());
            return Ok(());
        }
        app_perms.is_empty()
    };

    if is_empty {
        store.granted.remove(app_id);
    }

    persist_store(&store)?;

    println!("{}", "Permission revoked".green());
    println!("  app: {}", app_id.cyan());
    println!("  permission: {}", permission.cyan());

    log_audit_manual(app_id, permission, "revoked")?;

    Ok(())
}

fn cmd_audit(lines: usize) -> anyhow::Result<()> {
    println!("{}", "Portal Permission Audit Log".bold().blue());
    println!();

    if !std::path::Path::new(AUDIT_LOG_FILE).exists() {
        println!("  {}", "No audit log found".dimmed());
        return Ok(());
    }

    let content = std::fs::read_to_string(AUDIT_LOG_FILE)
        .or_else(|_| {
            Command::new("sudo")
                .args(["-n", "cat", AUDIT_LOG_FILE])
                .output()
                .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        })
        .unwrap_or_default();

    let entries: Vec<AuditEntry> = content
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .rev()
        .take(lines)
        .collect();

    if entries.is_empty() {
        println!("  {}", "No audit entries found".dimmed());
        return Ok(());
    }

    for entry in entries {
        let action_color = match entry.action.as_str() {
            "granted" => "granted".green(),
            "denied" => "denied".red(),
            "revoked" => "revoked".yellow(),
            _ => entry.action.as_str().normal(),
        };

        println!(
            "  [{}] {} -> {}",
            entry.timestamp.dimmed(),
            entry.app_id.cyan(),
            entry.permission
        );
        println!("    Action: {}", action_color);
        if let Some(reason) = entry.reason {
            println!("    Reason: {}", reason.dimmed());
        }
        println!();
    }

    Ok(())
}

fn load_store() -> anyhow::Result<PortalPermissionStore> {
    if let Ok(content) = std::fs::read_to_string(PORTAL_POLICY_FILE) {
        return serde_json::from_str(&content)
            .map_err(|e| anyhow::anyhow!("Invalid policy JSON: {}", e));
    }

    let sudo_output = Command::new("sudo")
        .args(["-n", "cat", PORTAL_POLICY_FILE])
        .output();

    match sudo_output {
        Ok(out) if out.status.success() => {
            let content = String::from_utf8_lossy(&out.stdout);
            serde_json::from_str(&content)
                .map_err(|e| anyhow::anyhow!("Invalid policy JSON: {}", e))
        }
        _ => Ok(PortalPermissionStore::default()),
    }
}

fn persist_store(store: &PortalPermissionStore) -> anyhow::Result<()> {
    let content = serde_json::to_string_pretty(store)?;

    if std::fs::create_dir_all("/var/lib/lifeos").is_ok()
        && std::fs::write(PORTAL_POLICY_FILE, &content).is_ok()
    {
        return Ok(());
    }

    let _ = Command::new("sudo")
        .args(["mkdir", "-p", "/var/lib/lifeos"])
        .status();

    let mut child = Command::new("sudo")
        .args(["tee", PORTAL_POLICY_FILE])
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
        anyhow::bail!("Failed to persist portal permissions (need elevated privileges)");
    }
}

fn log_audit_manual(app_id: &str, permission: &str, action: &str) -> anyhow::Result<()> {
    let entry = AuditEntry {
        timestamp: chrono::Local::now().to_rfc3339(),
        app_id: app_id.to_string(),
        permission: permission.to_string(),
        action: action.to_string(),
        reason: Some("manual CLI operation".to_string()),
    };

    let log_line = serde_json::to_string(&entry)?;

    let log_dir = std::path::Path::new(AUDIT_LOG_FILE)
        .parent()
        .ok_or_else(|| anyhow::anyhow!("Invalid audit log path"))?;

    if std::fs::create_dir_all(log_dir).is_ok() {
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(AUDIT_LOG_FILE)
        {
            writeln!(file, "{}", log_line)?;
            return Ok(());
        }
    }

    let mut child = Command::new("sudo")
        .args([
            "sh",
            "-c",
            &format!(
                "mkdir -p {} && tee -a {}",
                log_dir.display(),
                AUDIT_LOG_FILE
            ),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    if let Some(stdin) = child.stdin.as_mut() {
        writeln!(stdin, "{}", log_line)?;
    }

    child.wait()?;
    Ok(())
}
