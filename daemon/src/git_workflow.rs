//! Git Workflow — Autonomous git operations for the supervisor.
//!
//! Provides branch creation, auto-commit with semantic messages,
//! PR creation via `gh`, and diff summary generation.

use anyhow::{Context, Result};
use log::info;
use std::path::Path;
use tokio::process::Command;

/// Create a feature branch for a task.
pub async fn create_task_branch(work_dir: &Path, task_id: &str, slug: &str) -> Result<String> {
    let branch_name = format!("axi/{}-{}", &task_id[..8.min(task_id.len())], slug);
    info!("[git] Creating branch: {}", branch_name);

    let output = Command::new("git")
        .args(["checkout", "-b", &branch_name])
        .current_dir(work_dir)
        .output()
        .await
        .context("git checkout -b failed")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        // Branch might already exist — try switching to it
        if stderr.contains("already exists") {
            Command::new("git")
                .args(["checkout", &branch_name])
                .current_dir(work_dir)
                .output()
                .await?;
        } else {
            anyhow::bail!("git checkout -b failed: {}", stderr);
        }
    }

    Ok(branch_name)
}

/// Auto-commit all changes with a semantic message generated from the objective.
pub async fn auto_commit(work_dir: &Path, objective: &str) -> Result<String> {
    // Stage all changes
    Command::new("git")
        .args(["add", "-A"])
        .current_dir(work_dir)
        .output()
        .await
        .context("git add failed")?;

    // Check if there's anything to commit
    let status = Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(work_dir)
        .output()
        .await?;

    let status_text = String::from_utf8_lossy(&status.stdout);
    if status_text.trim().is_empty() {
        return Ok("No changes to commit".into());
    }

    // Generate commit message from objective
    let msg = generate_commit_message(objective);

    let output = Command::new("git")
        .args(["commit", "-m", &msg])
        .current_dir(work_dir)
        .output()
        .await
        .context("git commit failed")?;

    if output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        info!("[git] Committed: {}", msg);
        Ok(format!("Committed: {}\n{}", msg, stdout.trim()))
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git commit failed: {}", stderr)
    }
}

/// Get a diff summary of all changes in the current branch vs main.
pub async fn diff_summary(work_dir: &Path) -> Result<String> {
    // Get the diff stat
    let output = Command::new("git")
        .args(["diff", "--stat", "HEAD~1"])
        .current_dir(work_dir)
        .output()
        .await
        .context("git diff --stat failed")?;

    let stat = String::from_utf8_lossy(&output.stdout);

    // Get the actual diff (truncated)
    let diff_output = Command::new("git")
        .args(["diff", "HEAD~1"])
        .current_dir(work_dir)
        .output()
        .await?;

    let diff = String::from_utf8_lossy(&diff_output.stdout);
    let diff_truncated: String = diff.chars().take(3000).collect();

    Ok(format!(
        "**Diff Summary:**\n```\n{}\n```\n\n**Changes:**\n```diff\n{}{}\n```",
        stat.trim(),
        diff_truncated,
        if diff.len() > 3000 {
            "\n... [truncated]"
        } else {
            ""
        }
    ))
}

/// Create a pull request via `gh` CLI.
pub async fn create_pr(work_dir: &Path, branch: &str, title: &str, body: &str) -> Result<String> {
    info!("[git] Creating PR: {} (branch: {})", title, branch);

    // Push the branch first
    let push = Command::new("git")
        .args(["push", "-u", "origin", branch])
        .current_dir(work_dir)
        .output()
        .await
        .context("git push failed")?;

    if !push.status.success() {
        let stderr = String::from_utf8_lossy(&push.stderr);
        anyhow::bail!("git push failed: {}", stderr);
    }

    // Create PR via gh
    let output = Command::new("gh")
        .args([
            "pr", "create", "--title", title, "--body", body, "--head", branch,
        ])
        .current_dir(work_dir)
        .output()
        .await
        .context("gh pr create failed")?;

    if output.status.success() {
        let url = String::from_utf8_lossy(&output.stdout).trim().to_string();
        info!("[git] PR created: {}", url);
        Ok(url)
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("gh pr create failed: {}", stderr)
    }
}

/// Switch back to main branch.
pub async fn checkout_main(work_dir: &Path) -> Result<()> {
    Command::new("git")
        .args(["checkout", "main"])
        .current_dir(work_dir)
        .output()
        .await
        .context("git checkout main failed")?;
    Ok(())
}

/// Generate a semantic commit message from a task objective.
fn generate_commit_message(objective: &str) -> String {
    let lower = objective.to_lowercase();

    let prefix = if lower.contains("fix") || lower.contains("bug") || lower.contains("error") {
        "fix"
    } else if lower.contains("add") || lower.contains("implement") || lower.contains("create") {
        "feat"
    } else if lower.contains("refactor") || lower.contains("clean") || lower.contains("rename") {
        "refactor"
    } else if lower.contains("test") || lower.contains("spec") {
        "test"
    } else if lower.contains("doc") || lower.contains("readme") {
        "docs"
    } else if lower.contains("style") || lower.contains("format") || lower.contains("lint") {
        "style"
    } else {
        "feat"
    };

    // Truncate objective for commit message
    let short: String = objective.chars().take(72).collect();
    format!(
        "{}: {}\n\nAutonomously executed by Axi supervisor.",
        prefix, short
    )
}
