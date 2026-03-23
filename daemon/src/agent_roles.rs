//! Agent Roles — Specialized agent definitions for the GM (General Manager).
//!
//! Each role has a specific system prompt, allowed tools, and constraints.
//! The supervisor/GM delegates sub-tasks to agents based on their role.

use serde::{Deserialize, Serialize};

/// Predefined agent roles.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentRole {
    /// General Manager — decomposes objectives, delegates, coordinates.
    Gm,
    /// Planner — creates detailed plans from objectives.
    Planner,
    /// Coder — writes and modifies code.
    Coder,
    /// Reviewer — reviews code changes for quality and correctness.
    Reviewer,
    /// Tester — runs tests and reports results.
    Tester,
    /// DevOps — handles builds, deployments, system operations.
    DevOps,
    /// Researcher — searches for information, reads docs, analyzes.
    Researcher,
}

impl AgentRole {
    /// System prompt for this role.
    pub fn system_prompt(&self) -> &'static str {
        match self {
            AgentRole::Gm => {
                "You are the General Manager (GM) of LifeOS. Your job is to:\n\
                 1. Receive high-level objectives\n\
                 2. Break them into sub-tasks\n\
                 3. Assign each sub-task to the right specialist role\n\
                 4. Coordinate the results\n\
                 5. Report the final outcome\n\n\
                 Respond with a JSON plan where each step has a 'role' field."
            }
            AgentRole::Planner => {
                "You are a Planner agent. You create detailed, step-by-step \
                 execution plans from objectives. Output JSON plans with concrete \
                 shell_command and read_file actions. Be precise and safe."
            }
            AgentRole::Coder => {
                "You are a Coder agent for LifeOS (Rust codebase). You write and \
                 modify Rust code. Follow existing patterns. Use sandbox_command \
                 for changes. Run cargo clippy and cargo test after changes. \
                 Never use sudo. Keep changes minimal and focused."
            }
            AgentRole::Reviewer => {
                "You are a Code Reviewer agent. You review diffs and code changes \
                 for: correctness, safety (no unwrap on user input, no panics), \
                 style (matches existing codebase), and potential issues. \
                 Output a brief review with approve/request_changes verdict."
            }
            AgentRole::Tester => {
                "You are a Tester agent. You run tests, check build status, and \
                 verify that changes don't break anything. Commands you should use: \
                 cargo test, cargo clippy -- -D warnings, cargo build. \
                 Report pass/fail with details."
            }
            AgentRole::DevOps => {
                "You are a DevOps agent. You handle builds, service management, \
                 system status checks, and deployment tasks. You can check systemctl \
                 status, read logs, verify services. Never restart critical services \
                 without confirmation."
            }
            AgentRole::Researcher => {
                "You are a Research agent. You find information by reading files, \
                 analyzing code structure, and summarizing findings. You don't \
                 modify files — only read and report."
            }
        }
    }

    /// What tools/actions this role is allowed to use.
    #[allow(dead_code)]
    pub fn allowed_actions(&self) -> &'static [&'static str] {
        match self {
            AgentRole::Gm => &["ai_query", "respond"],
            AgentRole::Planner => &["read_file", "ai_query", "respond"],
            AgentRole::Coder => &[
                "shell_command",
                "sandbox_command",
                "read_file",
                "write_file",
                "respond",
            ],
            AgentRole::Reviewer => &["read_file", "shell_command", "ai_query", "respond"],
            AgentRole::Tester => &["shell_command", "read_file", "respond"],
            AgentRole::DevOps => &["shell_command", "read_file", "respond"],
            AgentRole::Researcher => &["read_file", "ai_query", "shell_command", "respond"],
        }
    }

    /// Suggest the best role for a given objective.
    pub fn suggest_for(objective: &str) -> Self {
        let lower = objective.to_lowercase();

        if lower.contains("test") || lower.contains("prueba") || lower.contains("verificar") {
            return AgentRole::Tester;
        }
        if lower.contains("review") || lower.contains("revisar") || lower.contains("auditar") {
            return AgentRole::Reviewer;
        }
        if lower.contains("escrib") || lower.contains("implementa") || lower.contains("crea ")
            || lower.contains("agrega") || lower.contains("modific") || lower.contains("fix")
            || lower.contains("arregla") || lower.contains("codigo") || lower.contains("code")
        {
            return AgentRole::Coder;
        }
        if lower.contains("deploy") || lower.contains("build") || lower.contains("servicio")
            || lower.contains("systemctl") || lower.contains("docker") || lower.contains("imagen")
        {
            return AgentRole::DevOps;
        }
        if lower.contains("investiga") || lower.contains("busca") || lower.contains("analiza")
            || lower.contains("research") || lower.contains("encuentra") || lower.contains("lee")
        {
            return AgentRole::Researcher;
        }
        if lower.contains("plan") || lower.contains("diseña") || lower.contains("arquitectura") {
            return AgentRole::Planner;
        }

        // Default: GM handles it
        AgentRole::Gm
    }
}

/// A sub-agent instance with its role and task.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubAgent {
    pub id: String,
    pub role: AgentRole,
    pub objective: String,
    pub status: SubAgentStatus,
    pub result: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SubAgentStatus {
    Pending,
    Running,
    Completed,
    Failed,
}

// ---------------------------------------------------------------------------
// Per-agent metrics
// ---------------------------------------------------------------------------

/// Tracks success/failure metrics per agent role.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct AgentMetrics {
    pub tasks_completed: u64,
    pub tasks_failed: u64,
    pub total_duration_ms: u64,
    pub avg_duration_ms: u64,
}

/// Aggregate metrics for all roles.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct AllAgentMetrics {
    pub by_role: std::collections::HashMap<String, AgentMetrics>,
    pub total_tasks: u64,
    pub total_completed: u64,
    pub total_failed: u64,
}

impl AllAgentMetrics {
    pub fn record(&mut self, role: AgentRole, success: bool, duration_ms: u64) {
        let role_name = format!("{:?}", role).to_lowercase();
        let entry = self.by_role.entry(role_name).or_default();

        self.total_tasks += 1;
        if success {
            entry.tasks_completed += 1;
            self.total_completed += 1;
        } else {
            entry.tasks_failed += 1;
            self.total_failed += 1;
        }
        entry.total_duration_ms += duration_ms;
        let total = entry.tasks_completed + entry.tasks_failed;
        if total > 0 {
            entry.avg_duration_ms = entry.total_duration_ms / total;
        }
    }
}

// ---------------------------------------------------------------------------
// Automatic failure runbooks
// ---------------------------------------------------------------------------

/// Known failure patterns and suggested recovery actions.
pub struct Runbook;

impl Runbook {
    /// Given an error message, suggest a recovery action.
    pub fn suggest_recovery(error: &str) -> Option<&'static str> {
        let lower = error.to_lowercase();

        if lower.contains("connection refused") || lower.contains("connect error") {
            return Some("Network issue. Check internet connectivity: ping 8.8.8.8");
        }
        if lower.contains("rate limit") || lower.contains("429") || lower.contains("too many requests") {
            return Some("Rate limited. Wait 60 seconds and retry, or switch to a different LLM provider.");
        }
        if lower.contains("out of memory") || lower.contains("oom") {
            return Some("Out of memory. Try: reduce context size, close other apps, or use a smaller model.");
        }
        if lower.contains("permission denied") || lower.contains("eacces") {
            return Some("Permission denied. Check file ownership. May need to run with correct user.");
        }
        if lower.contains("no space left") || lower.contains("disk full") {
            return Some("Disk full. Run: df -h && du -sh /var/lib/lifeos/ && lifeos-maintenance-cleanup.sh");
        }
        if lower.contains("llama-server") || lower.contains("model") && lower.contains("not found") {
            return Some("AI model issue. Check: systemctl status llama-server && ls /var/lib/lifeos/models/");
        }
        if lower.contains("cargo") && lower.contains("error") {
            return Some("Build error. Run: cargo clean && cargo build 2>&1 | head -30");
        }
        if lower.contains("git") && lower.contains("conflict") {
            return Some("Git conflict. Run: git status && git diff to inspect, then resolve manually.");
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return Some("Request timed out. The LLM provider may be slow. Retry or switch provider.");
        }

        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suggest_coder_for_code_task() {
        assert_eq!(
            AgentRole::suggest_for("Implementa una nueva funcion para el router"),
            AgentRole::Coder
        );
    }

    #[test]
    fn suggest_tester_for_test_task() {
        assert_eq!(
            AgentRole::suggest_for("Corre los tests y verifica que pasen"),
            AgentRole::Tester
        );
    }

    #[test]
    fn suggest_researcher_for_analysis() {
        assert_eq!(
            AgentRole::suggest_for("Investiga como funciona el memory_plane"),
            AgentRole::Researcher
        );
    }

    #[test]
    fn suggest_gm_for_generic() {
        assert_eq!(
            AgentRole::suggest_for("Hola, como estas?"),
            AgentRole::Gm
        );
    }

    #[test]
    fn coder_can_sandbox() {
        let actions = AgentRole::Coder.allowed_actions();
        assert!(actions.contains(&"sandbox_command"));
    }

    #[test]
    fn reviewer_cannot_write() {
        let actions = AgentRole::Reviewer.allowed_actions();
        assert!(!actions.contains(&"write_file"));
    }
}
