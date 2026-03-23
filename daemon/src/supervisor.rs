//! Supervisor — Autonomous task execution loop.
//!
//! Pulls tasks from the queue, uses the LLM router to plan and execute steps,
//! evaluates results, retries on failure, and reports via notification channel.

use anyhow::{Context, Result};
use log::{debug, error, info, warn};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{broadcast, RwLock};

use crate::llm_router::{ChatMessage, LlmRouter, RouterRequest, TaskComplexity};
use crate::memory_plane::MemoryPlaneManager;
use crate::privacy_filter::PrivacyFilter;
use crate::task_queue::TaskQueue;

// ---------------------------------------------------------------------------
// Notification types — consumed by Telegram bridge and other listeners
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum SupervisorNotification {
    TaskStarted {
        task_id: String,
        objective: String,
    },
    TaskCompleted {
        task_id: String,
        objective: String,
        result: String,
        steps_total: usize,
        steps_ok: usize,
        duration_ms: u64,
    },
    TaskFailed {
        task_id: String,
        objective: String,
        error: String,
        will_retry: bool,
    },
    Heartbeat {
        summary: serde_json::Value,
        uptime_hours: f64,
    },
}

// ---------------------------------------------------------------------------
// Plan types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Plan {
    pub steps: Vec<PlanStep>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanStep {
    pub description: String,
    pub action: StepAction,
    pub expected_outcome: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum StepAction {
    ShellCommand { command: String },
    /// Run a command inside an isolated git worktree (safe self-modification).
    SandboxCommand { command: String },
    AiQuery { prompt: String },
    ScreenCapture,
    ReadFile { path: String },
    WriteFile { path: String, content: String },
    Respond { message: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StepResult {
    pub success: bool,
    pub output: String,
    pub step_index: usize,
}

// ---------------------------------------------------------------------------
// Risk classification
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RiskLevel {
    Low,
    Medium,
    High,
}

// ---------------------------------------------------------------------------
// Supervisor
// ---------------------------------------------------------------------------

pub struct Supervisor {
    queue: Arc<TaskQueue>,
    router: Arc<RwLock<LlmRouter>>,
    privacy: Arc<PrivacyFilter>,
    memory: Option<Arc<RwLock<MemoryPlaneManager>>>,
    running: Arc<std::sync::atomic::AtomicBool>,
    work_dir: PathBuf,
    notify_tx: broadcast::Sender<SupervisorNotification>,
    started_at: std::time::Instant,
}

impl Supervisor {
    pub fn new(
        queue: Arc<TaskQueue>,
        router: Arc<RwLock<LlmRouter>>,
        privacy: Arc<PrivacyFilter>,
    ) -> Self {
        Self::with_memory(queue, router, privacy, None)
    }

    pub fn with_memory(
        queue: Arc<TaskQueue>,
        router: Arc<RwLock<LlmRouter>>,
        privacy: Arc<PrivacyFilter>,
        memory: Option<Arc<RwLock<MemoryPlaneManager>>>,
    ) -> Self {
        let (notify_tx, _) = broadcast::channel(64);

        // Determine working directory: prefer the LifeOS repo if it exists
        let work_dir = std::env::var("LIFEOS_REPO_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
                let candidates = [
                    PathBuf::from(&home).join("personalProjects/gama/lifeos"),
                    PathBuf::from("/var/home/lifeos/personalProjects/gama/lifeos"),
                    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/")),
                ];
                candidates
                    .into_iter()
                    .find(|p| p.join("Cargo.toml").exists())
                    .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/")))
            });

        info!("Supervisor working directory: {}", work_dir.display());

        Self {
            queue,
            router,
            privacy,
            memory,
            running: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            work_dir,
            notify_tx,
            started_at: std::time::Instant::now(),
        }
    }

    /// Subscribe to supervisor notifications.
    pub fn subscribe(&self) -> broadcast::Receiver<SupervisorNotification> {
        self.notify_tx.subscribe()
    }

    /// Start the supervisor loop. Runs until stopped.
    pub async fn run(&self) {
        use std::sync::atomic::Ordering;

        if self.running.swap(true, Ordering::SeqCst) {
            warn!("Supervisor already running");
            return;
        }

        info!("Supervisor started — polling task queue");

        let mut heartbeat_interval = tokio::time::interval(Duration::from_secs(86400)); // 24h
        heartbeat_interval.tick().await; // skip first immediate tick

        loop {
            if !self.running.load(Ordering::Relaxed) {
                info!("Supervisor stopping");
                break;
            }

            tokio::select! {
                _ = heartbeat_interval.tick() => {
                    self.send_heartbeat().await;
                }
                result = self.tick() => {
                    match result {
                        Ok(true) => continue,
                        Ok(false) => {
                            tokio::time::sleep(Duration::from_secs(5)).await;
                        }
                        Err(e) => {
                            error!("Supervisor tick error: {}", e);
                            tokio::time::sleep(Duration::from_secs(10)).await;
                        }
                    }
                }
            }
        }
    }

    pub fn stop(&self) {
        self.running
            .store(false, std::sync::atomic::Ordering::Relaxed);
    }

    pub fn is_running(&self) -> bool {
        self.running.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Send a heartbeat notification with queue summary.
    async fn send_heartbeat(&self) {
        let summary = self.queue.summary().unwrap_or_default();
        let uptime = self.started_at.elapsed().as_secs_f64() / 3600.0;
        let _ = self.notify_tx.send(SupervisorNotification::Heartbeat {
            summary,
            uptime_hours: uptime,
        });
    }

    /// Manually trigger a heartbeat (callable from API).
    pub async fn trigger_heartbeat(&self) {
        self.send_heartbeat().await;
    }

    /// Process one task if available. Returns true if a task was processed.
    async fn tick(&self) -> Result<bool> {
        let task = match self.queue.dequeue()? {
            Some(t) => t,
            None => return Ok(false),
        };

        info!(
            "Supervisor picked up task: {} — {}",
            task.id, task.objective
        );
        self.queue.mark_running(&task.id)?;

        let _ = self.notify_tx.send(SupervisorNotification::TaskStarted {
            task_id: task.id.clone(),
            objective: task.objective.clone(),
        });

        let start = std::time::Instant::now();

        match self.execute_task(&task.id, &task.objective).await {
            Ok((result, steps_total, steps_ok)) => {
                // Summarize the raw result with AI for cleaner Telegram output
                let summary = self
                    .summarize_result(&task.objective, &result)
                    .await
                    .unwrap_or_else(|_| result.clone());

                self.queue.mark_completed(&task.id, &summary)?;

                self.audit_log(&task.id, &task.objective, "completed", &summary)
                    .await;

                // Save to memory: what was done, what worked
                self.memory_writeback(
                    &task.objective,
                    "completed",
                    &summary,
                    &format!("{}/{} steps OK in {}ms", steps_ok, steps_total, start.elapsed().as_millis()),
                )
                .await;

                let _ = self.notify_tx.send(SupervisorNotification::TaskCompleted {
                    task_id: task.id,
                    objective: task.objective,
                    result: summary,
                    steps_total,
                    steps_ok,
                    duration_ms: start.elapsed().as_millis() as u64,
                });
            }
            Err(e) => {
                let error_msg = format!("{:#}", e);
                let will_retry = self.queue.mark_failed(&task.id, &error_msg)?;

                self.audit_log(&task.id, &task.objective, "failed", &error_msg)
                    .await;

                // Save to memory: what failed and why
                self.memory_writeback(
                    &task.objective,
                    "failed",
                    &error_msg,
                    if will_retry { "will retry" } else { "permanent failure" },
                )
                .await;

                let _ = self.notify_tx.send(SupervisorNotification::TaskFailed {
                    task_id: task.id,
                    objective: task.objective,
                    error: error_msg,
                    will_retry,
                });
            }
        }

        Ok(true)
    }

    /// Execute a single task: plan -> execute steps -> return result + step counts.
    async fn execute_task(
        &self,
        task_id: &str,
        objective: &str,
    ) -> Result<(String, usize, usize)> {
        let plan = self.create_plan(objective).await?;
        let plan_json = serde_json::to_string_pretty(&plan)?;
        self.queue.set_plan(task_id, &plan_json)?;

        info!(
            "Task {} planned with {} steps",
            task_id,
            plan.steps.len()
        );

        let mut results = Vec::new();
        let mut last_output = String::new();

        for (i, step) in plan.steps.iter().enumerate() {
            info!(
                "Task {} step {}/{}: {}",
                task_id,
                i + 1,
                plan.steps.len(),
                step.description
            );

            match self.execute_step(step).await {
                Ok(output) => {
                    last_output = output.clone();
                    results.push(StepResult {
                        success: true,
                        output,
                        step_index: i,
                    });
                }
                Err(e) => {
                    let error = format!("Step {} failed: {}", i + 1, e);
                    warn!("Task {} — {}", task_id, error);
                    results.push(StepResult {
                        success: false,
                        output: error.clone(),
                        step_index: i,
                    });
                    last_output = error;
                }
            }
        }

        let steps_total = plan.steps.len();
        let steps_ok = results.iter().filter(|r| r.success).count();

        if steps_ok == 0 && steps_total > 0 {
            anyhow::bail!(
                "All {} steps failed. Last error: {}",
                steps_total,
                last_output
            );
        }

        let summary = format!(
            "{}/{} steps completed. Result: {}",
            steps_ok, steps_total, last_output
        );

        Ok((summary, steps_total, steps_ok))
    }

    /// Use AI to produce a clean, human-readable summary of a raw task result.
    async fn summarize_result(&self, objective: &str, raw_result: &str) -> Result<String> {
        // Skip summarization for short results — they're already readable
        if raw_result.len() < 300 {
            return Ok(raw_result.to_string());
        }

        let prompt = format!(
            "Resumen conciso en español (max 500 chars) del resultado de esta tarea:\n\
             Tarea: {}\n\
             Resultado crudo:\n{}",
            objective,
            &raw_result[..raw_result.len().min(3000)]
        );

        let request = RouterRequest {
            messages: vec![ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(prompt),
            }],
            complexity: Some(TaskComplexity::Simple),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(256),
        };

        let router = self.router.read().await;
        let response = router.chat(&request).await?;
        Ok(response.text)
    }

    /// Save task outcome to the memory plane for future context.
    async fn memory_writeback(
        &self,
        objective: &str,
        status: &str,
        detail: &str,
        meta: &str,
    ) {
        let memory = match &self.memory {
            Some(m) => m,
            None => return,
        };

        let content = format!(
            "Tarea: {}\nEstado: {}\nDetalle: {}\nMeta: {}\nFecha: {}",
            objective,
            status,
            &detail[..detail.len().min(2000)],
            meta,
            chrono::Local::now().to_rfc3339(),
        );

        let importance = match status {
            "failed" => 70u8,
            "completed" => 40,
            _ => 30,
        };

        let tags = vec![
            "supervisor".to_string(),
            format!("status:{}", status),
        ];

        let mem = memory.read().await;
        if let Err(e) = mem
            .add_entry("decision", "system", &tags, Some("supervisor"), importance, &content)
            .await
        {
            warn!("Memory writeback failed: {}", e);
        } else {
            debug!("Memory writeback: {} — {}", status, &objective[..objective.len().min(60)]);
        }
    }

    /// Capture a screenshot and return its path.
    async fn execute_screen_capture(&self) -> Result<String> {
        let screenshot_dir = self.work_dir.join("target/screenshots");
        tokio::fs::create_dir_all(&screenshot_dir).await.ok();
        let filename = format!("supervisor-{}.png", chrono::Local::now().format("%Y%m%d-%H%M%S"));
        let path = screenshot_dir.join(&filename);

        // Try grim (Wayland/COSMIC)
        let output = tokio::process::Command::new("grim")
            .arg(&path)
            .output()
            .await;

        match output {
            Ok(o) if o.status.success() => {
                Ok(format!("Screenshot saved to {}", path.display()))
            }
            _ => {
                // Fallback: try xdg-desktop-portal screenshot
                let output = tokio::process::Command::new("gnome-screenshot")
                    .args(["-f", &path.to_string_lossy()])
                    .output()
                    .await;
                match output {
                    Ok(o) if o.status.success() => {
                        Ok(format!("Screenshot saved to {}", path.display()))
                    }
                    _ => Ok("Screenshot capture failed — no grim or gnome-screenshot available".into()),
                }
            }
        }
    }

    /// Execute a command inside a temporary git worktree (isolated sandbox).
    /// The worktree is created, the command runs in it, and then it's cleaned up.
    async fn execute_in_sandbox(&self, command: &str) -> Result<String> {
        let id = uuid::Uuid::new_v4().to_string();
        let branch_name = format!("sandbox-{}", &id[..8]);
        let worktree_path = std::env::temp_dir().join(format!("lifeos-sandbox-{}", &branch_name));

        info!("Creating sandbox worktree: {}", worktree_path.display());

        // Create worktree
        let create_output = tokio::process::Command::new("git")
            .args(["worktree", "add", "-b", &branch_name])
            .arg(&worktree_path)
            .current_dir(&self.work_dir)
            .output()
            .await
            .context("Failed to create git worktree")?;

        if !create_output.status.success() {
            let stderr = String::from_utf8_lossy(&create_output.stderr);
            anyhow::bail!("Failed to create worktree: {}", stderr);
        }

        // Run command in worktree
        let result = tokio::process::Command::new("sh")
            .arg("-c")
            .arg(command)
            .current_dir(&worktree_path)
            .output()
            .await;

        // Always clean up worktree
        let _ = tokio::process::Command::new("git")
            .args(["worktree", "remove", "--force"])
            .arg(&worktree_path)
            .current_dir(&self.work_dir)
            .output()
            .await;
        let _ = tokio::process::Command::new("git")
            .args(["branch", "-D", &branch_name])
            .current_dir(&self.work_dir)
            .output()
            .await;

        match result {
            Ok(output) if output.status.success() => {
                let stdout = String::from_utf8_lossy(&output.stdout);
                Ok(if stdout.is_empty() {
                    "(sandbox command completed with no output)".into()
                } else if stdout.len() > 4000 {
                    format!("{}...\n[truncated]", &stdout[..4000])
                } else {
                    stdout.to_string()
                })
            }
            Ok(output) => {
                let stdout = String::from_utf8_lossy(&output.stdout);
                let stderr = String::from_utf8_lossy(&output.stderr);
                anyhow::bail!("Sandbox command failed: {}{}", stdout, stderr)
            }
            Err(e) => anyhow::bail!("Sandbox execution error: {}", e),
        }
    }

    /// Query memory for relevant past experiences before planning.
    async fn recall_context(&self, objective: &str) -> String {
        let memory = match &self.memory {
            Some(m) => m,
            None => return String::new(),
        };

        let mem = memory.read().await;
        match mem
            .search_entries(objective, 3, Some("system"))
            .await
        {
            Ok(results) if !results.is_empty() => {
                let mut context = String::from("Relevant past experiences:\n");
                for r in &results {
                    context.push_str(&format!(
                        "- [{}] {}\n",
                        r.entry.kind,
                        &r.entry.content[..r.entry.content.len().min(200)]
                    ));
                }
                context
            }
            _ => String::new(),
        }
    }

    async fn create_plan(&self, objective: &str) -> Result<Plan> {
        let system_prompt = format!(
            r#"You are a task planner for LifeOS, an AI-native operating system.
The working directory is: {}
Given an objective, decompose it into concrete executable steps.
Respond ONLY with a JSON object like:
{{
  "steps": [
    {{
      "description": "what this step does",
      "action": {{"type": "shell_command", "command": "the command to run"}},
      "expected_outcome": "what success looks like"
    }}
  ]
}}

Available action types:
- shell_command: Run a shell command. Use for git, cargo, system commands. Commands run in the working directory above.
- sandbox_command: Run a command in an isolated git worktree. Use for code changes that might break things. The worktree is auto-cleaned.
- ai_query: Ask an AI a question. Use for analysis, summarization, reasoning.
- screen_capture: Take a screenshot of the current desktop.
- read_file: Read a file from disk. Use absolute paths or paths relative to working directory.
- write_file: Write content to a file. Provide "path" and "content".
- respond: Send a text response back to the user. Use as the last step.

Keep plans short (2-6 steps). Prefer simple, safe commands.
Never use sudo. Never delete files without confirmation.
For code changes, prefer sandbox_command over shell_command.
Always end with a "respond" step summarizing what was done."#,
            self.work_dir.display()
        );

        // Learning loop: recall relevant past experiences
        let memory_context = self.recall_context(objective).await;

        let mut user_content = objective.to_string();
        if !memory_context.is_empty() {
            user_content = format!("{}\n\n{}", objective, memory_context);
        }

        let request = RouterRequest {
            messages: vec![
                ChatMessage {
                    role: "system".into(),
                    content: serde_json::Value::String(system_prompt),
                },
                ChatMessage {
                    role: "user".into(),
                    content: serde_json::Value::String(user_content),
                },
            ],
            complexity: Some(TaskComplexity::Complex),
            sensitivity: Some(self.privacy.classify(objective)),
            preferred_provider: None,
            max_tokens: Some(2048),
        };

        let router = self.router.read().await;
        let response = router
            .chat(&request)
            .await
            .context("Failed to get plan from LLM")?;

        parse_plan_from_response(&response.text)
    }

    /// Classify risk level of an action.
    fn classify_risk(action: &StepAction) -> RiskLevel {
        match action {
            StepAction::ShellCommand { command } => {
                let cmd = command.to_lowercase();
                // High risk: destructive or irreversible commands
                let high_risk = [
                    "rm -rf", "rm -r", "rmdir", "mkfs", "dd if=",
                    "git push", "git reset --hard", "git checkout .",
                    "git clean", "reboot", "shutdown", "systemctl stop",
                    "pkill", "killall", "chmod 777", "> /dev/",
                    "curl.*| sh", "wget.*| sh", "sudo",
                ];
                if high_risk.iter().any(|p| cmd.contains(p)) {
                    return RiskLevel::High;
                }
                // Medium risk: file modification, git operations
                let medium_risk = [
                    "git commit", "git merge", "git rebase",
                    "cargo publish", "npm publish",
                    "mv ", "cp -r",
                ];
                if medium_risk.iter().any(|p| cmd.contains(p)) {
                    return RiskLevel::Medium;
                }
                RiskLevel::Low
            }
            StepAction::SandboxCommand { .. } => RiskLevel::Low, // sandboxed = safe
            StepAction::WriteFile { .. } => RiskLevel::Medium,
            StepAction::ReadFile { .. } | StepAction::AiQuery { .. } => RiskLevel::Low,
            StepAction::ScreenCapture | StepAction::Respond { .. } => RiskLevel::Low,
        }
    }

    async fn execute_step(&self, step: &PlanStep) -> Result<String> {
        let risk = Self::classify_risk(&step.action);
        if risk == RiskLevel::High {
            let desc = match &step.action {
                StepAction::ShellCommand { command } => command.clone(),
                _ => step.description.clone(),
            };
            warn!("BLOCKED high-risk action: {}", desc);
            let _ = self.notify_tx.send(SupervisorNotification::TaskFailed {
                task_id: "risk-block".into(),
                objective: format!("High-risk action blocked: {}", desc),
                error: "This action was classified as high-risk and requires manual execution.".into(),
                will_retry: false,
            });
            anyhow::bail!("High-risk action blocked: {}. Execute manually if intended.", desc);
        }

        match &step.action {
            StepAction::ShellCommand { command } => self.execute_shell(command).await,
            StepAction::SandboxCommand { command } => self.execute_in_sandbox(command).await,
            StepAction::AiQuery { prompt } => self.execute_ai_query(prompt).await,
            StepAction::ScreenCapture => self.execute_screen_capture().await,
            StepAction::ReadFile { path } => {
                let full_path = if std::path::Path::new(path).is_absolute() {
                    PathBuf::from(path)
                } else {
                    self.work_dir.join(path)
                };
                let content = tokio::fs::read_to_string(&full_path)
                    .await
                    .with_context(|| format!("Failed to read {}", full_path.display()))?;
                if content.len() > 8000 {
                    Ok(format!(
                        "{}...\n[truncated, {} bytes total]",
                        &content[..8000],
                        content.len()
                    ))
                } else {
                    Ok(content)
                }
            }
            StepAction::WriteFile { path, content } => {
                let full_path = if std::path::Path::new(path).is_absolute() {
                    PathBuf::from(path)
                } else {
                    self.work_dir.join(path)
                };
                tokio::fs::write(&full_path, content)
                    .await
                    .with_context(|| format!("Failed to write {}", full_path.display()))?;
                Ok(format!("Wrote {} bytes to {}", content.len(), full_path.display()))
            }
            StepAction::Respond { message } => Ok(message.clone()),
        }
    }

    async fn execute_shell(&self, command: &str) -> Result<String> {
        info!("Executing shell: {}", command);

        let output = tokio::process::Command::new("sh")
            .arg("-c")
            .arg(command)
            .current_dir(&self.work_dir)
            .output()
            .await
            .with_context(|| format!("Failed to execute: {}", command))?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);

        if output.status.success() {
            let result = if stdout.is_empty() {
                "(no output)".to_string()
            } else if stdout.len() > 4000 {
                format!("{}...\n[truncated]", &stdout[..4000])
            } else {
                stdout.to_string()
            };
            Ok(result)
        } else {
            anyhow::bail!(
                "Command exited with {}: {}{}",
                output.status,
                stdout,
                stderr
            )
        }
    }

    async fn execute_ai_query(&self, prompt: &str) -> Result<String> {
        let sensitivity = self.privacy.classify(prompt);
        let request = RouterRequest {
            messages: vec![ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(prompt.into()),
            }],
            complexity: Some(TaskComplexity::Medium),
            sensitivity: Some(sensitivity),
            preferred_provider: None,
            max_tokens: Some(1024),
        };

        let router = self.router.read().await;
        let response = router.chat(&request).await?;
        Ok(response.text)
    }

    async fn audit_log(&self, task_id: &str, objective: &str, status: &str, detail: &str) {
        let log_dir = PathBuf::from("/var/log/lifeos");
        if std::fs::create_dir_all(&log_dir).is_err() {
            // Fallback to data dir
            return;
        }
        let path = log_dir.join("supervisor-audit.log");
        let entry = format!(
            "{}\t{}\t{}\t{}\t{}\n",
            chrono::Local::now().to_rfc3339(),
            task_id,
            status,
            objective.chars().take(100).collect::<String>(),
            detail.chars().take(200).collect::<String>(),
        );
        use tokio::io::AsyncWriteExt;
        if let Ok(mut f) = tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .await
        {
            let _ = f.write_all(entry.as_bytes()).await;
        }
    }
}

// ---------------------------------------------------------------------------
// Plan parsing
// ---------------------------------------------------------------------------

fn parse_plan_from_response(text: &str) -> Result<Plan> {
    let json_str = extract_json(text);

    match serde_json::from_str::<Plan>(&json_str) {
        Ok(plan) if !plan.steps.is_empty() => Ok(plan),
        Ok(_) | Err(_) => Ok(Plan {
            steps: vec![PlanStep {
                description: "Direct LLM response".into(),
                action: StepAction::Respond {
                    message: text.to_string(),
                },
                expected_outcome: "User receives response".into(),
            }],
        }),
    }
}

fn extract_json(text: &str) -> String {
    if let Some(start) = text.find("```json") {
        let after = &text[start + 7..];
        if let Some(end) = after.find("```") {
            return after[..end].trim().to_string();
        }
    }
    if let Some(start) = text.find('{') {
        if let Some(end) = text.rfind('}') {
            return text[start..=end].to_string();
        }
    }
    text.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_plan_json() {
        let response = r#"```json
{
  "steps": [
    {
      "description": "Check git status",
      "action": {"type": "shell_command", "command": "git status"},
      "expected_outcome": "See current repo state"
    },
    {
      "description": "Report result",
      "action": {"type": "respond", "message": "Done checking status"},
      "expected_outcome": "User informed"
    }
  ]
}
```"#;
        let plan = parse_plan_from_response(response).unwrap();
        assert_eq!(plan.steps.len(), 2);
        assert!(matches!(
            plan.steps[0].action,
            StepAction::ShellCommand { .. }
        ));
    }

    #[test]
    fn parse_plan_fallback() {
        let response = "I couldn't understand that, but here's some info...";
        let plan = parse_plan_from_response(response).unwrap();
        assert_eq!(plan.steps.len(), 1);
        assert!(matches!(plan.steps[0].action, StepAction::Respond { .. }));
    }

    #[test]
    fn extract_json_from_markdown() {
        let text = "Here's the plan:\n```json\n{\"steps\":[]}\n```\nDone.";
        let json = extract_json(text);
        assert_eq!(json, "{\"steps\":[]}");
    }
}
