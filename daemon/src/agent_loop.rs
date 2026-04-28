//! Agent Loop — Connects the autonomous agent to the task queue via LLM planning.
//!
//! When the user is away (screen locked), this module asks the LLM what
//! proactive tasks Axi should work on, then enqueues them into the task queue
//! for the supervisor to execute.
//!
//! Gated behind `LIFEOS_AGENT_LOOP=true` environment variable.
//!
//! Safety:
//! - Maximum 3 tasks enqueued per autonomous session
//! - Only low-risk, pre-approved task categories
//! - Respects existing pending tasks (won't flood the queue)
//! - Stops immediately when user returns

use anyhow::Result;
use log::{debug, info, warn};
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::llm_router::{ChatMessage, LlmRouter, RouterRequest, TaskComplexity};
use crate::task_queue::{TaskCreate, TaskPriority, TaskQueue, TaskStatus};

/// Maximum tasks the agent loop can enqueue per autonomous session.
const MAX_TASKS_PER_SESSION: u32 = 3;
/// Maximum pending tasks allowed before the agent loop stops generating new ones.
const MAX_PENDING_BEFORE_PAUSE: usize = 5;
/// Minimum interval between task generation attempts (seconds).
const GENERATION_COOLDOWN_SECS: u64 = 120;

/// State tracked across the autonomous session (reset when user returns).
pub struct AgentLoopState {
    tasks_enqueued_this_session: u32,
    last_generation_attempt: Option<std::time::Instant>,
}

impl AgentLoopState {
    pub fn new() -> Self {
        Self {
            tasks_enqueued_this_session: 0,
            last_generation_attempt: None,
        }
    }

    /// Reset state when the user returns (session ends).
    pub fn reset(&mut self) {
        self.tasks_enqueued_this_session = 0;
        self.last_generation_attempt = None;
    }

    /// How many tasks were enqueued during this autonomous session.
    pub fn tasks_enqueued(&self) -> u32 {
        self.tasks_enqueued_this_session
    }
}

/// Check if the agent loop is enabled via environment variable.
pub fn is_enabled() -> bool {
    std::env::var("LIFEOS_AGENT_LOOP")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// Try to generate and enqueue one autonomous task.
///
/// Returns `Ok(true)` if a task was enqueued, `Ok(false)` if skipped (cooldown,
/// limits, no suggestions), or `Err` on failure.
pub async fn try_generate_task(
    state: &mut AgentLoopState,
    queue: &Arc<TaskQueue>,
    router: &Arc<RwLock<LlmRouter>>,
) -> Result<bool> {
    // Safety: session limit
    if state.tasks_enqueued_this_session >= MAX_TASKS_PER_SESSION {
        debug!(
            "[agent_loop] Session limit reached ({}/{}), skipping",
            state.tasks_enqueued_this_session, MAX_TASKS_PER_SESSION
        );
        return Ok(false);
    }

    // Safety: cooldown
    if let Some(last) = state.last_generation_attempt {
        if last.elapsed().as_secs() < GENERATION_COOLDOWN_SECS {
            debug!("[agent_loop] Cooldown active, skipping");
            return Ok(false);
        }
    }

    // Safety: don't flood the queue
    let pending = queue.list(Some(TaskStatus::Pending), 10)?;
    let running = queue.list(Some(TaskStatus::Running), 10)?;
    let active_count = pending.len() + running.len();
    if active_count >= MAX_PENDING_BEFORE_PAUSE {
        debug!(
            "[agent_loop] Queue has {} active tasks, pausing generation",
            active_count
        );
        return Ok(false);
    }

    state.last_generation_attempt = Some(std::time::Instant::now());

    // Build context about current system state for the LLM
    let pending_objectives: Vec<String> = pending.iter().map(|t| t.objective.clone()).collect();
    let context = build_system_context(&pending_objectives).await;

    // Ask the LLM to suggest ONE proactive task
    let suggestion = ask_llm_for_task(router, &context).await?;

    match suggestion {
        Some(objective) => {
            info!("[agent_loop] Enqueuing autonomous task: {}", objective);
            queue.enqueue(TaskCreate {
                objective,
                priority: TaskPriority::Low,
                source: "agent_loop".into(),
                max_attempts: 2,
            })?;
            state.tasks_enqueued_this_session += 1;
            Ok(true)
        }
        None => {
            debug!("[agent_loop] LLM suggested no tasks");
            Ok(false)
        }
    }
}

/// Build a context string about the system state for the LLM.
async fn build_system_context(pending_objectives: &[String]) -> String {
    let time_ctx = crate::time_context::time_context();
    let mut ctx = format!("{}\n\n", time_ctx);

    // Show what's already in the queue
    if !pending_objectives.is_empty() {
        ctx.push_str("Tasks already in queue:\n");
        for obj in pending_objectives {
            ctx.push_str(&format!("- {}\n", obj));
        }
        ctx.push('\n');
    }

    // Disk usage
    if let Ok(output) = tokio::process::Command::new("df")
        .args(["--output=pcent,avail", "/var"])
        .output()
        .await
    {
        let stdout = String::from_utf8_lossy(&output.stdout);
        if let Some(line) = stdout.lines().nth(1) {
            ctx.push_str(&format!("Disk /var: {}\n", line.trim()));
        }
    }

    // RAM
    if let Ok(output) = tokio::process::Command::new("free")
        .args(["-h", "--si"])
        .output()
        .await
    {
        let stdout = String::from_utf8_lossy(&output.stdout);
        if let Some(line) = stdout.lines().nth(1) {
            ctx.push_str(&format!("Memory: {}\n", line.trim()));
        }
    }

    ctx
}

/// Ask the LLM to suggest one proactive task for autonomous execution.
///
/// Returns `None` if the LLM says "NONE" (nothing useful to do).
async fn ask_llm_for_task(
    router: &Arc<RwLock<LlmRouter>>,
    system_context: &str,
) -> Result<Option<String>> {
    let system_prompt = format!(
        r#"You are Axi, the autonomous agent inside LifeOS. The user is AWAY (screen locked).
Your job is to suggest ONE small, safe, proactive task that would be helpful.

{system_context}

Rules:
- Only suggest tasks that are LOW RISK and reversible
- Good examples: check disk space and clean temp files, check for system updates, run cargo test on a project, summarize unread notifications, check git status of projects
- BAD examples: anything involving sudo, deleting user files, sending messages, modifying system configs, installing software
- Do NOT suggest tasks that duplicate what's already in the queue
- If there's nothing useful to do, respond with exactly "NONE"
- Respond with ONLY the task objective (one line, no explanation, no JSON)
- Keep it under 100 characters"#
    );

    let request = RouterRequest {
        messages: vec![
            ChatMessage {
                role: "system".into(),
                content: serde_json::Value::String(system_prompt),
            },
            ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(
                    "What's one useful thing I can do while the user is away?".into(),
                ),
            },
        ],
        complexity: Some(TaskComplexity::Simple),
        sensitivity: None,
        preferred_provider: None,
        max_tokens: Some(100),
        task_type: None,
    tools: None,
    };

    let router_guard = router.read().await;
    let response = router_guard.chat(&request).await?;
    drop(router_guard);

    let text = crate::llm_router::strip_think_tags(&response.text)
        .trim()
        .to_string();

    if text.eq_ignore_ascii_case("NONE") || text.is_empty() || text.len() > 200 {
        return Ok(None);
    }

    // Basic sanity: reject if it contains obviously dangerous patterns
    let lower = text.to_lowercase();
    let dangerous = ["sudo", "rm -rf", "mkfs", "dd if=", "shutdown", "reboot"];
    if dangerous.iter().any(|d| lower.contains(d)) {
        warn!(
            "[agent_loop] LLM suggested dangerous task, rejecting: {}",
            text
        );
        return Ok(None);
    }

    Ok(Some(text))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_loop_parse_values() {
        // Test the parsing logic directly — env var tests are racy in
        // parallel test runs, so we verify the string comparison instead.
        let parse = |val: &str| val == "1" || val.eq_ignore_ascii_case("true");
        assert!(parse("true"));
        assert!(parse("TRUE"));
        assert!(parse("1"));
        assert!(!parse("false"));
        assert!(!parse("0"));
        assert!(!parse(""));
    }

    #[test]
    fn session_state_reset() {
        let mut state = AgentLoopState::new();
        state.tasks_enqueued_this_session = 3;
        state.last_generation_attempt = Some(std::time::Instant::now());
        state.reset();
        assert_eq!(state.tasks_enqueued_this_session, 0);
        assert!(state.last_generation_attempt.is_none());
    }
}
