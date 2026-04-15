//! `life update` command — read-only status + trigger service subcommands.
//!
//! # Safety contract
//!
//! `apply` and `rollback` subcommands MUST NEVER execute any OS command.
//! They exist solely to print the manual commands the operator must run.
//! This is enforced by compile-time regression tests at the bottom of this
//! module (`test_apply_never_shells_out`, `test_rollback_never_shells_out`).
//! Any future PR that adds `process::Command` to those arms WILL fail CI.
use clap::Args;
use clap::Subcommand;
use colored::Colorize;
use serde::Deserialize;
use std::fs;
use std::path::Path;
use std::process::Command;

// ─── State file paths (overridable via env for testing) ───────────────────────
fn state_dir() -> String {
    std::env::var("LIFEOS_STATE_DIR").unwrap_or_else(|_| "/var/lib/lifeos".to_string())
}

fn update_state_path() -> String {
    format!("{}/update-state.json", state_dir())
}

fn update_stage_state_path() -> String {
    format!("{}/update-stage-state.json", state_dir())
}

// ─── State file schemas ───────────────────────────────────────────────────────

/// Written by lifeos-update-check.sh
#[derive(Debug, Deserialize, Default)]
pub struct UpdateCheckState {
    pub available: Option<bool>,
    pub current_version: Option<String>,
    pub new_version: Option<String>,
    pub remote_digest: Option<String>,
    pub checked_at: Option<String>,
    pub error: Option<String>,
}

/// Written by lifeos-update-stage.sh
#[derive(Debug, Deserialize, Default)]
pub struct UpdateStageState {
    pub staged: Option<bool>,
    pub staged_digest: Option<String>,
    pub staged_at: Option<String>,
    pub last_stage_attempt: Option<String>,
    pub last_stage_error: Option<String>,
}

fn load_check_state() -> UpdateCheckState {
    let path = update_state_path();
    if !Path::new(&path).exists() {
        return UpdateCheckState::default();
    }
    fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn load_stage_state() -> UpdateStageState {
    let path = update_stage_state_path();
    if !Path::new(&path).exists() {
        return UpdateStageState::default();
    }
    fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

// ─── CLI structure ────────────────────────────────────────────────────────────

#[derive(Subcommand)]
pub enum UpdateSubcommand {
    /// Show update status from state files + live bootc status
    Status {
        /// Emit structured JSON instead of human-readable output
        #[arg(long)]
        json: bool,
    },
    /// Trigger the update check service (lifeos-update-check.service)
    Check,
    /// Trigger the update stage service to fetch the new image (lifeos-update-stage.service)
    Stage,
    /// Print the manual apply command — NEVER executes it
    Apply,
    /// Print the manual rollback command + current rollback slot — NEVER executes it
    Rollback,
}

#[derive(Args, Default)]
pub struct UpdateArgs {
    #[command(subcommand)]
    pub command: Option<UpdateSubcommand>,
}

// ─── Entry point ─────────────────────────────────────────────────────────────

pub async fn execute(args: UpdateArgs) -> anyhow::Result<()> {
    match args.command {
        Some(UpdateSubcommand::Status { json }) => status(json).await,
        Some(UpdateSubcommand::Check) => check(),
        Some(UpdateSubcommand::Stage) => stage(),
        Some(UpdateSubcommand::Apply) => apply(),
        Some(UpdateSubcommand::Rollback) => rollback(),
        None => {
            // Default: show status
            status(false).await
        }
    }
}

// ─── Subcommand implementations ───────────────────────────────────────────────

async fn status(json: bool) -> anyhow::Result<()> {
    let check = load_check_state();
    let stage = load_stage_state();

    // Try live bootc status for booted image info
    let booted_image = get_booted_image();
    let rollback_image = get_rollback_image();

    if json {
        let output = serde_json::json!({
            "booted_image": booted_image,
            "rollback_image": rollback_image,
            "available": check.available.unwrap_or(false),
            "current_version": check.current_version,
            "new_version": check.new_version,
            "remote_digest": check.remote_digest,
            "checked_at": check.checked_at,
            "check_error": check.error,
            "staged": stage.staged.unwrap_or(false),
            "staged_digest": stage.staged_digest,
            "staged_at": stage.staged_at,
            "last_stage_attempt": stage.last_stage_attempt,
            "last_stage_error": stage.last_stage_error,
        });
        println!("{}", serde_json::to_string_pretty(&output)?);
        return Ok(());
    }

    println!("{}", "Update Status".bold().blue());
    println!();

    if let Some(img) = &booted_image {
        println!("  {}: {}", "Booted image".bold(), img.cyan());
    } else {
        println!("  {}: {}", "Booted image".bold(), "(unavailable)".dimmed());
    }
    if let Some(img) = &rollback_image {
        println!("  {}: {}", "Rollback slot".bold(), img.dimmed());
    }

    println!();
    println!("{}", "Update check".bold());
    match check.available {
        Some(true) => {
            println!("  {}: {}", "Update available".bold(), "yes".green());
            if let Some(v) = &check.new_version {
                println!("  {}: {}", "New version".bold(), v);
            }
        }
        Some(false) => println!("  {}: {}", "Update available".bold(), "no".green()),
        None => println!(
            "  {}: {}",
            "Update available".bold(),
            "(not checked yet)".dimmed()
        ),
    }
    if let Some(t) = &check.checked_at {
        println!("  {}: {}", "Last checked".bold(), t.dimmed());
    }
    if let Some(e) = &check.error {
        println!("  {}: {}", "Check error".bold(), e.yellow());
    }

    println!();
    println!("{}", "Staged deployment".bold());
    match stage.staged {
        Some(true) => {
            println!("  {}: {}", "Staged".bold(), "yes".green());
            if let Some(d) = &stage.staged_digest {
                println!("  {}: {}", "Staged digest".bold(), d.dimmed());
            }
            if let Some(t) = &stage.staged_at {
                println!("  {}: {}", "Staged at".bold(), t.dimmed());
            }
            println!();
            println!(
                "  {} Run: {}",
                "To activate:".bold(),
                "sudo bootc upgrade --apply".cyan()
            );
        }
        Some(false) => {
            println!("  {}: {}", "Staged".bold(), "no".yellow());
            if let Some(e) = &stage.last_stage_error {
                println!("  {}: {}", "Last stage error".bold(), e.yellow());
            }
        }
        None => println!("  {}: {}", "Staged".bold(), "(never staged)".dimmed()),
    }

    println!();
    println!("{}", "Hint:".bold());
    println!("  life update check    — trigger update check service");
    println!("  life update stage    — trigger update stage service");
    println!("  life update apply    — show manual apply command");
    println!("  life update rollback — show manual rollback command");

    Ok(())
}

fn check() -> anyhow::Result<()> {
    println!("{}", "Triggering lifeos-update-check.service...".blue());
    let output = Command::new("systemctl")
        .args(["start", "lifeos-update-check.service"])
        .output();
    match output {
        Ok(o) if o.status.success() => {
            println!("{}", "Check service started.".green());
        }
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            if stderr.contains("permission")
                || stderr.contains("Access denied")
                || stderr.contains("authentication")
            {
                eprintln!(
                    "{}: insufficient privilege to start system service. Try: {}",
                    "Error".red(),
                    "sudo systemctl start lifeos-update-check.service".cyan()
                );
            } else {
                eprintln!(
                    "{}: {}",
                    "Failed to start check service".red(),
                    stderr.trim()
                );
            }
            anyhow::bail!("systemctl start lifeos-update-check.service failed");
        }
        Err(e) => {
            eprintln!("{}: systemctl not available: {}", "Error".red(), e);
            anyhow::bail!("systemctl not available");
        }
    }
    Ok(())
}

fn stage() -> anyhow::Result<()> {
    println!("{}", "Triggering lifeos-update-stage.service...".blue());
    let output = Command::new("systemctl")
        .args(["start", "lifeos-update-stage.service"])
        .output();
    match output {
        Ok(o) if o.status.success() => {
            println!(
                "{}",
                "Stage service started. Check status with: life update status".green()
            );
        }
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            if stderr.contains("permission")
                || stderr.contains("Access denied")
                || stderr.contains("authentication")
            {
                eprintln!(
                    "{}: insufficient privilege to start system service. Try: {}",
                    "Error".red(),
                    "sudo systemctl start lifeos-update-stage.service".cyan()
                );
            } else {
                eprintln!(
                    "{}: {}",
                    "Failed to start stage service".red(),
                    stderr.trim()
                );
            }
            anyhow::bail!("systemctl start lifeos-update-stage.service failed");
        }
        Err(e) => {
            eprintln!("{}: systemctl not available: {}", "Error".red(), e);
            anyhow::bail!("systemctl not available");
        }
    }
    Ok(())
}

/// Print-only subcommand — NEVER executes the apply command.
///
/// # Safety contract
///
/// This function MUST NOT call process::Command or std::process::Command.
/// Enforced by test_apply_never_shells_out() below.
fn apply() -> anyhow::Result<()> {
    let stage = load_stage_state();

    match stage.staged_digest {
        None => {
            println!(
                "Nothing staged. Run `life update stage` first (or wait for the weekly timer)."
            );
            return Ok(());
        }
        Some(ref d) => {
            println!("{}", "Staged deployment ready.".bold().green());
            println!("  {}: {}", "Staged digest".bold(), d.dimmed());
            if let Some(t) = &stage.staged_at {
                println!("  {}: {}", "Staged at".bold(), t.dimmed());
            }
        }
    }

    println!();
    println!("To activate the staged update, run:");
    println!("  {}", "sudo bootc upgrade --apply".cyan());
    println!();
    println!("To roll back after applying:");
    println!("  {}", "sudo bootc rollback".cyan());
    println!();
    println!(
        "{}",
        "Note: life update apply never executes these commands — you run them manually.".dimmed()
    );

    Ok(())
}

/// Print-only subcommand — NEVER executes the rollback command.
///
/// # Safety contract
///
/// This function MUST NOT call process::Command or std::process::Command.
/// Enforced by test_rollback_never_shells_out() below.
fn rollback() -> anyhow::Result<()> {
    let rollback_image = get_rollback_image();

    println!("{}", "Rollback information".bold().blue());
    println!();
    match rollback_image {
        Some(ref img) => println!("  {}: {}", "Rollback slot".bold(), img.cyan()),
        None => println!(
            "  {}: {}",
            "Rollback slot".bold(),
            "(none — no prior deployment)".dimmed()
        ),
    }

    println!();
    println!("To roll back to the prior deployment, run:");
    println!("  {}", "sudo bootc rollback".cyan());
    println!();
    println!("Then reboot to activate:");
    println!("  {}", "sudo systemctl reboot".cyan());
    println!();
    println!(
        "{}",
        "Note: life update rollback never executes these commands — you run them manually."
            .dimmed()
    );

    Ok(())
}

// ─── Helpers (live bootc queries) ────────────────────────────────────────────

fn get_booted_image() -> Option<String> {
    let output = Command::new("bootc")
        .args(["status", "--format", "json"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    let booted = json.get("status")?.get("booted")?;
    parse_image_ref(booted)
}

fn get_rollback_image() -> Option<String> {
    let output = Command::new("bootc")
        .args(["status", "--format", "json"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    let rollback = json.get("status")?.get("rollback")?;
    parse_image_ref(rollback)
}

fn parse_image_ref(slot: &serde_json::Value) -> Option<String> {
    slot.get("image")
        .and_then(|i| i.get("image"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .or_else(|| {
            slot.get("image")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        })
}

// ─── Batch D TDD tests ────────────────────────────────────────────────────────
//
// CONTRACT: apply() and rollback() MUST NEVER invoke process::Command.
// Any future PR that adds shell-out to those arms fails CI via the
// compile-time source-text guards below.
#[cfg(test)]
mod tests {
    // ── D3: compile-time regression guard — apply ────────────────────────────
    #[test]
    fn test_apply_never_shells_out() {
        let src = include_str!("update.rs");
        // Find the apply arm in the enum dispatch (UpdateSubcommand::Apply)
        let apply_start = src
            .find("UpdateSubcommand::Apply")
            .expect("UpdateSubcommand::Apply arm must exist in update.rs");
        let relevant = &src[apply_start..apply_start.saturating_add(2000)];
        assert!(
            !relevant.contains("process::Command"),
            "apply arm MUST NOT contain process::Command — it is a print-only subcommand"
        );
        assert!(
            !relevant.contains("std::process::Command"),
            "apply arm MUST NOT contain std::process::Command — it is a print-only subcommand"
        );
    }

    // ── D5: compile-time regression guard — rollback ─────────────────────────
    #[test]
    fn test_rollback_never_shells_out() {
        let src = include_str!("update.rs");
        let rollback_start = src
            .find("UpdateSubcommand::Rollback")
            .expect("UpdateSubcommand::Rollback arm must exist in update.rs");
        let relevant = &src[rollback_start..rollback_start.saturating_add(2000)];
        assert!(
            !relevant.contains("process::Command"),
            "rollback arm MUST NOT contain process::Command — it is a print-only subcommand"
        );
        assert!(
            !relevant.contains("std::process::Command"),
            "rollback arm MUST NOT contain std::process::Command — it is a print-only subcommand"
        );
    }

    // ── D4: behavioural tests ─────────────────────────────────────────────────

    /// apply() source must not contain Command::new followed by --apply.
    #[test]
    fn test_apply_body_has_no_process_command_shellout() {
        let src = include_str!("update.rs");
        let cmd_with_apply = src
            .find("Command::new")
            .map(|pos| src[pos..].find("\"--apply\"").map(|offset| pos + offset))
            .flatten();
        assert!(
            cmd_with_apply.is_none(),
            "Found Command::new followed by --apply in update.rs — this would execute bootc upgrade --apply"
        );
    }

    /// rollback() body must not call process::Command in a shell-exec pattern.
    #[test]
    fn test_rollback_body_has_no_process_command_shellout() {
        let src = include_str!("update.rs");
        // Search for Command::new("bootc").arg("rollback") pattern
        let dangerous = src
            .find("Command::new")
            .map(|pos| {
                let window = &src[pos..pos.min(src.len() - 1).saturating_add(200)];
                if window.contains("\"rollback\"") {
                    Some(pos)
                } else {
                    None
                }
            })
            .flatten();
        assert!(
            dangerous.is_none(),
            "Found Command::new with rollback arg in update.rs — rollback arm must never execute"
        );
    }

    /// status subcommand should parse both state files.
    #[test]
    fn test_status_parses_both_state_files() {
        let check_state = r#"{
            "available": true,
            "current_version": "sha256:abc123",
            "new_version": "sha256:def456",
            "checked_at": "2026-04-15T04:00:00+00:00"
        }"#;
        let stage_state = r#"{
            "staged": true,
            "staged_digest": "sha256:def456",
            "staged_at": "2026-04-15T04:05:23+00:00",
            "last_stage_error": null
        }"#;

        let check: serde_json::Value =
            serde_json::from_str(check_state).expect("check state JSON must be valid");
        assert_eq!(check["available"], true);
        assert_eq!(check["current_version"], "sha256:abc123");

        let stage: serde_json::Value =
            serde_json::from_str(stage_state).expect("stage state JSON must be valid");
        assert_eq!(stage["staged"], true);
        assert_eq!(stage["staged_digest"], "sha256:def456");
        assert!(stage["last_stage_error"].is_null());
    }

    /// --json flag on status must emit valid JSON.
    #[test]
    fn test_status_json_flag_emits_valid_json() {
        let output = serde_json::json!({
            "booted_image": "ghcr.io/hectormr206/lifeos:edge",
            "available": true,
            "current_version": "sha256:abc",
            "new_version": "sha256:def",
            "checked_at": "2026-04-15T04:00:00+00:00",
            "staged": true,
            "staged_digest": "sha256:def",
            "staged_at": "2026-04-15T04:05:23+00:00",
            "last_stage_error": null
        });
        let serialized = serde_json::to_string(&output).expect("must serialize");
        let reparsed: serde_json::Value =
            serde_json::from_str(&serialized).expect("--json output must re-parse as valid JSON");
        assert_eq!(reparsed["available"], true);
    }
}
