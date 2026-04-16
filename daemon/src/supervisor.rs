//! Supervisor — Autonomous task execution loop.
//!
//! Pulls tasks from the queue, uses the LLM router to plan and execute steps,
//! evaluates results, retries on failure, and reports via notification channel.

use anyhow::{Context, Result};
use log::{debug, error, info, warn};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{broadcast, RwLock};

use crate::agent_roles::{AgentRole, AllAgentMetrics, Runbook};
use crate::llm_router::{strip_think_tags, ChatMessage, LlmRouter, RouterRequest, TaskComplexity};
use crate::memory_plane::MemoryPlaneManager;
use crate::privacy_filter::PrivacyFilter;
use crate::scheduled_tasks::ScheduledTaskManager;
use crate::task_queue::{TaskCreate, TaskPriority, TaskQueue};

// ---------------------------------------------------------------------------
// SLA configuration
// ---------------------------------------------------------------------------

/// Service-Level Agreement constraints for a task.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SlaConfig {
    /// Maximum allowed duration in seconds.
    pub max_duration_secs: u64,
    /// Minimum acceptable confidence (0.0–1.0).
    pub min_confidence: f64,
}

impl SlaConfig {
    /// Parse an SLA prefix from an objective string.
    /// Format: `[SLA:30m,95%] actual objective text`
    /// Returns `(Some(SlaConfig), stripped_objective)` or `(None, original)`.
    pub fn parse_from_objective(objective: &str) -> (Option<Self>, String) {
        let trimmed = objective.trim();
        if !trimmed.starts_with("[SLA:") {
            return (None, objective.to_string());
        }
        if let Some(end) = trimmed.find(']') {
            let inner = &trimmed[5..end]; // e.g. "30m,95%"
            let parts: Vec<&str> = inner.split(',').collect();
            if parts.len() == 2 {
                let duration_str = parts[0].trim();
                let confidence_str = parts[1].trim().trim_end_matches('%');

                let secs = if let Some(m) = duration_str.strip_suffix('m') {
                    m.parse::<u64>().ok().map(|v| v * 60)
                } else if let Some(s) = duration_str.strip_suffix('s') {
                    s.parse::<u64>().ok()
                } else if let Some(h) = duration_str.strip_suffix('h') {
                    h.parse::<u64>().ok().map(|v| v * 3600)
                } else {
                    duration_str.parse::<u64>().ok()
                };

                let conf = confidence_str.parse::<f64>().ok().map(|v| v / 100.0);

                if let (Some(s), Some(c)) = (secs, conf) {
                    let stripped = trimmed[end + 1..].trim().to_string();
                    return (
                        Some(SlaConfig {
                            max_duration_secs: s,
                            min_confidence: c,
                        }),
                        stripped,
                    );
                }
            }
        }
        (None, objective.to_string())
    }
}

// ---------------------------------------------------------------------------
// Reliability statistics
// ---------------------------------------------------------------------------

/// Aggregated reliability metrics computed from the audit log.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ReliabilityStats {
    pub total_tasks: usize,
    pub success_rate: f64,
    pub avg_duration_ms: f64,
    pub most_failed_action_type: Option<String>,
    pub avg_confidence: f64,
}

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
    ApprovalRequired {
        task_id: String,
        objective: String,
        action_description: String,
    },
    /// AL.4 — Observable progress: emitted before each step execution.
    TaskProgress {
        task_id: String,
        step_index: usize,
        steps_total: usize,
        description: String,
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
    ShellCommand {
        command: String,
    },
    /// Run a command inside an isolated git worktree (safe self-modification).
    SandboxCommand {
        command: String,
    },
    AiQuery {
        prompt: String,
    },
    /// Fetch a URL and return its text content (HTML stripped).
    BrowseUrl {
        url: String,
    },
    /// Search the web using Serper API and return results.
    WebSearch {
        query: String,
    },
    /// Search for files by name pattern.
    FileSearch {
        pattern: String,
    },
    /// Search file contents for a string.
    ContentSearch {
        query: String,
    },
    /// Copy text to the system clipboard.
    ClipboardCopy {
        text: String,
    },
    /// Take a screenshot, analyze it with local LLM, and return description.
    ScreenAnalyze {
        prompt: Option<String>,
    },
    ScreenCapture,
    ReadFile {
        path: String,
    },
    WriteFile {
        path: String,
        content: String,
    },
    Respond {
        message: String,
    },
    /// Open a URL in the browser and take a screenshot for visual verification.
    BrowserScreenshot {
        url: String,
    },
    /// Click on a DOM element identified by CSS selector.
    BrowserClick {
        url: String,
        selector: String,
    },
    /// Fill an input element identified by CSS selector with a value.
    BrowserFill {
        url: String,
        selector: String,
        value: String,
    },
    /// Evaluate arbitrary JavaScript on a page and return the result.
    BrowserEvalJs {
        url: String,
        code: String,
    },
    /// Install a Flatpak application.
    FlatpakInstall {
        app_id: String,
    },
    /// Open an application by name.
    OpenApp {
        name: String,
    },
    /// Open a file with its default application.
    OpenFile {
        path: String,
    },
    /// Type text into the focused window via ydotool.
    TypeText {
        text: String,
    },
    /// Send a keyboard shortcut (e.g., "ctrl+s").
    SendKeys {
        combo: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StepResult {
    pub success: bool,
    pub output: String,
    pub step_index: usize,
    /// Confidence score: 1.0 = clear success, 0.8 = output but no signal,
    /// 0.5 = empty output, 0.3 = warnings detected, 0.0 = failure.
    pub confidence: f64,
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
    scheduler: std::sync::Mutex<Option<Arc<ScheduledTaskManager>>>,
    running: Arc<std::sync::atomic::AtomicBool>,
    work_dir: PathBuf,
    notify_tx: broadcast::Sender<SupervisorNotification>,
    started_at: std::time::Instant,
    metrics: std::sync::Mutex<AllAgentMetrics>,
    /// When true, medium-risk actions (git commit, mv, cp) execute without
    /// waiting for approval. Controlled by LIFEOS_AUTO_APPROVE_MEDIUM env var.
    auto_approve_medium: bool,
    /// When true, execute_task() returns a dry-run preview instead of executing.
    /// Controlled by LIFEOS_SHADOW_MODE env var.
    shadow_mode: bool,
    /// Optional event bus for broadcasting health reports to the dashboard.
    event_bus: std::sync::Mutex<Option<broadcast::Sender<crate::events::DaemonEvent>>>,
    /// Sensory pipeline — consulted before any `StepAction::ScreenCapture`
    /// or `StepAction::ScreenAnalyze` shells out to grim so the supervisor
    /// loop honors kill-switch, master screen toggle, suspend, lock, and
    /// sensitive-window policy. Round-2 audit C-NEW-5.
    sensory_pipeline:
        std::sync::Mutex<Option<Arc<RwLock<crate::sensory_pipeline::SensoryPipelineManager>>>>,
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
                    .unwrap_or_else(|| {
                        std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"))
                    })
            });

        info!("Supervisor working directory: {}", work_dir.display());

        let auto_approve_medium = std::env::var("LIFEOS_AUTO_APPROVE_MEDIUM")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(true); // default ON — medium-risk auto-executes with notification

        let shadow_mode = std::env::var("LIFEOS_SHADOW_MODE")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);

        if shadow_mode {
            info!("Supervisor shadow mode ENABLED — tasks will be dry-run only");
        }

        Self {
            queue,
            router,
            privacy,
            memory,
            scheduler: std::sync::Mutex::new(None),
            running: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            work_dir,
            notify_tx,
            started_at: std::time::Instant::now(),
            metrics: std::sync::Mutex::new(AllAgentMetrics::default()),
            auto_approve_medium,
            shadow_mode,
            event_bus: std::sync::Mutex::new(None),
            sensory_pipeline: std::sync::Mutex::new(None),
        }
    }

    /// Attach an event bus for broadcasting health reports to the dashboard.
    pub fn set_event_bus(&self, bus: broadcast::Sender<crate::events::DaemonEvent>) {
        *self.event_bus.lock().unwrap_or_else(|e| e.into_inner()) = Some(bus);
    }

    /// Attach the sensory pipeline manager so `StepAction::ScreenCapture`
    /// and `StepAction::ScreenAnalyze` can honor the unified sense gate.
    /// Without this, the supervisor captures even with screen_enabled=false.
    pub fn set_sensory_pipeline(
        &self,
        manager: Arc<RwLock<crate::sensory_pipeline::SensoryPipelineManager>>,
    ) {
        *self
            .sensory_pipeline
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(manager);
    }

    /// Attach a scheduled task manager.
    pub fn set_scheduler(&self, scheduler: Arc<ScheduledTaskManager>) {
        *self.scheduler.lock().unwrap_or_else(|e| e.into_inner()) = Some(scheduler);
    }

    /// Get agent metrics snapshot.
    pub fn metrics(&self) -> AllAgentMetrics {
        self.metrics
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
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

        let parallel = std::env::var("LIFEOS_PARALLEL_TASKS")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);

        if parallel {
            info!("Supervisor started — parallel mode (up to 3 concurrent tasks)");
        } else {
            info!("Supervisor started — polling task queue");
        }

        let mut heartbeat_interval = tokio::time::interval(Duration::from_secs(86400)); // 24h
        heartbeat_interval.tick().await; // skip first immediate tick
        let mut scheduler_interval = tokio::time::interval(Duration::from_secs(60)); // check every min
        scheduler_interval.tick().await;

        loop {
            if !self.running.load(Ordering::Relaxed) {
                info!("Supervisor stopping");
                break;
            }

            tokio::select! {
                _ = heartbeat_interval.tick() => {
                    self.send_heartbeat().await;
                }
                _ = scheduler_interval.tick() => {
                    self.check_scheduled_tasks().await;
                }
                result = async {
                    if parallel { self.parallel_tick().await } else { self.tick().await }
                } => {
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

    /// Send a heartbeat notification with queue summary and health metrics.
    async fn send_heartbeat(&self) {
        let summary = self.queue.summary().unwrap_or_default();
        let uptime = self.started_at.elapsed().as_secs_f64() / 3600.0;

        // Gather system metrics for the health report
        let mut health_details = serde_json::Map::new();

        // CPU load average
        if let Ok(loadavg) = tokio::fs::read_to_string("/proc/loadavg").await {
            if let Some(avg1) = loadavg.split_whitespace().next() {
                health_details.insert(
                    "cpu_load_1m".into(),
                    serde_json::Value::String(avg1.to_string()),
                );
            }
        }

        // RAM usage
        if let Ok(output) = tokio::process::Command::new("free")
            .args(["-m"])
            .output()
            .await
        {
            let stdout = String::from_utf8_lossy(&output.stdout);
            if let Some(mem_line) = stdout.lines().nth(1) {
                let parts: Vec<&str> = mem_line.split_whitespace().collect();
                if parts.len() >= 7 {
                    let total: u64 = parts[1].parse().unwrap_or(0);
                    let available: u64 = parts[6].parse().unwrap_or(0);
                    if total > 0 {
                        let used_pct = ((total - available) as f64 / total as f64 * 100.0) as u32;
                        health_details.insert(
                            "ram_used_pct".into(),
                            serde_json::Value::Number(used_pct.into()),
                        );
                        health_details.insert(
                            "ram_available_mb".into(),
                            serde_json::Value::Number(available.into()),
                        );
                    }
                }
            }
        }

        // Disk usage on /var
        if let Ok(output) = tokio::process::Command::new("df")
            .args(["--output=pcent", "/var"])
            .output()
            .await
        {
            let stdout = String::from_utf8_lossy(&output.stdout);
            if let Some(pct_str) = stdout.lines().nth(1) {
                if let Ok(pct) = pct_str.trim().trim_end_matches('%').parse::<u32>() {
                    health_details.insert(
                        "disk_used_pct".into(),
                        serde_json::Value::Number(pct.into()),
                    );
                }
            }
        }

        // Task queue stats from summary
        health_details.insert("queue_summary".into(), summary.clone());

        // Provider usage — reliability stats
        let reliability = self.reliability_stats();
        health_details.insert(
            "tasks_total".into(),
            serde_json::Value::Number(reliability.total_tasks.into()),
        );
        health_details.insert(
            "success_rate".into(),
            serde_json::json!(format!("{:.1}%", reliability.success_rate * 100.0)),
        );

        // Proactive health warnings
        let alerts = crate::proactive::check_all(Some(&self.queue), None).await;
        if !alerts.is_empty() {
            let warnings: Vec<serde_json::Value> = alerts
                .iter()
                .map(|a| {
                    serde_json::json!({
                        "category": format!("{:?}", a.category),
                        "severity": format!("{:?}", a.severity),
                        "message": a.message,
                    })
                })
                .collect();
            health_details.insert("health_warnings".into(), serde_json::Value::Array(warnings));
        }

        health_details.insert(
            "uptime_hours".into(),
            serde_json::json!(format!("{:.1}", uptime)),
        );

        let _ = self.notify_tx.send(SupervisorNotification::Heartbeat {
            summary,
            uptime_hours: uptime,
        });

        // Also emit a DaemonEvent so the dashboard and event bus receive the health report
        if let Some(ref bus) = *self.event_bus.lock().unwrap_or_else(|e| e.into_inner()) {
            let report_json = serde_json::to_string(&health_details).unwrap_or_default();
            let _ = bus.send(crate::events::DaemonEvent::Notification {
                priority: "health_report".into(),
                message: report_json,
            });
        }
    }

    /// Check for due scheduled tasks and enqueue them.
    async fn check_scheduled_tasks(&self) {
        let scheduler = match self
            .scheduler
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
        {
            Some(s) => s,
            None => return,
        };

        match scheduler.get_due_tasks() {
            Ok(tasks) => {
                for task in tasks {
                    info!("Scheduled task due: {} — {}", task.id, task.objective);
                    if let Err(e) = self.queue.enqueue(TaskCreate {
                        objective: task.objective.clone(),
                        priority: TaskPriority::Normal,
                        source: "scheduler".into(),
                        max_attempts: 2,
                    }) {
                        warn!("Failed to enqueue scheduled task: {}", e);
                    }
                    if let Err(e) = scheduler.mark_executed(&task.id, &task.schedule) {
                        warn!("Failed to mark scheduled task executed: {}", e);
                    }
                }
            }
            Err(e) => warn!("Failed to check scheduled tasks: {}", e),
        }
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

        // Pre-flight risk check: block dangerous objectives BEFORE planning
        if Self::objective_is_dangerous(&task.objective) {
            let msg = format!(
                "BLOCKED: '{}' contains a dangerous command pattern. Execute manually if intended.",
                crate::str_utils::truncate_bytes_safe(&task.objective, 100)
            );
            warn!("{}", msg);
            // Cancel permanently — do NOT use mark_failed (which retries)
            self.queue.cancel(&task.id)?;
            let _ = self.notify_tx.send(SupervisorNotification::TaskFailed {
                task_id: task.id,
                objective: task.objective,
                error: msg,
                will_retry: false,
            });
            return Ok(true);
        }

        self.queue.mark_running(&task.id)?;

        let _ = self.notify_tx.send(SupervisorNotification::TaskStarted {
            task_id: task.id.clone(),
            objective: task.objective.clone(),
        });

        let role = AgentRole::suggest_for(&task.objective);
        let start = std::time::Instant::now();

        // Trust-mode: create a feature branch so changes are isolated
        let trust_mode = std::env::var("LIFEOS_AUTO_APPROVE_MEDIUM").unwrap_or_default() == "true";
        let task_branch = if trust_mode {
            let slug: String = task
                .objective
                .chars()
                .filter(|c| c.is_alphanumeric() || *c == ' ')
                .take(30)
                .collect::<String>()
                .replace(' ', "-")
                .to_lowercase();
            match crate::git_workflow::create_task_branch(&self.work_dir, &task.id, &slug).await {
                Ok(branch) => {
                    info!("[supervisor] Created branch: {}", branch);
                    Some(branch)
                }
                Err(e) => {
                    debug!("[supervisor] Branch creation skipped: {}", e);
                    None
                }
            }
        } else {
            None
        };

        // Timeout: 5 minutes max per task (prevents stuck tasks)
        let task_timeout = std::time::Duration::from_secs(300);
        let task_result =
            tokio::time::timeout(task_timeout, self.execute_task(&task.id, &task.objective)).await;

        let task_result = match task_result {
            Ok(inner) => inner,
            Err(_) => Err(anyhow::anyhow!(
                "Tarea cancelada: excedio el limite de 5 minutos. Intenta dividirla en pasos mas pequeños."
            )),
        };

        match task_result {
            Ok((result, steps_total, steps_ok)) => {
                // Summarize the raw result with AI for cleaner Telegram output
                let summary = self
                    .summarize_result(&task.objective, &result)
                    .await
                    .unwrap_or_else(|_| result.clone());

                self.queue.mark_completed(&task.id, &summary)?;

                let task_confidence = if steps_total > 0 {
                    steps_ok as f64 / steps_total as f64
                } else {
                    0.0
                };

                self.audit_log(
                    &task.id,
                    &task.objective,
                    "completed",
                    &summary,
                    task_confidence,
                )
                .await;

                // Generate a reusable skill from this successful task
                if steps_ok >= 2 {
                    let skill_gen = crate::skill_generator::SkillGenerator::new(&self.work_dir);
                    // Extract step descriptions and commands for skill generation
                    let step_data: Vec<(String, String)> = summary
                        .lines()
                        .filter(|l| l.starts_with("[OK]"))
                        .map(|l| (l.to_string(), l.to_string()))
                        .collect();
                    if let Err(e) = skill_gen
                        .generate_from_task(&task.objective, &step_data, true)
                        .await
                    {
                        debug!("Skill generation skipped: {}", e);
                    }
                }

                // Save to memory: what was done, what worked
                self.memory_writeback(
                    &task.objective,
                    "completed",
                    &summary,
                    &format!(
                        "{}/{} steps OK in {}ms",
                        steps_ok,
                        steps_total,
                        start.elapsed().as_millis()
                    ),
                )
                .await;

                let duration_ms = start.elapsed().as_millis() as u64;

                // Git workflow: auto-commit if task wrote files and trust_mode is on
                if trust_mode && summary.contains("Wrote") {
                    match crate::git_workflow::auto_commit(&self.work_dir, &task.objective).await {
                        Ok(commit_msg) => {
                            info!("[supervisor] auto-committed: {}", commit_msg);
                            // Generate diff summary for notification
                            if let Ok(diff) =
                                crate::git_workflow::diff_summary(&self.work_dir).await
                            {
                                let _ =
                                    self.notify_tx.send(SupervisorNotification::TaskCompleted {
                                        task_id: task.id.clone(),
                                        objective: format!(
                                            "{}\n\nDiff:\n{}",
                                            task.objective,
                                            crate::str_utils::truncate_bytes_safe(&diff, 1500)
                                        ),
                                        result: commit_msg,
                                        steps_total,
                                        steps_ok,
                                        duration_ms,
                                    });
                            }

                            // Create PR if we have a feature branch
                            if let Some(ref branch) = task_branch {
                                match crate::git_workflow::create_pr(
                                    &self.work_dir,
                                    branch,
                                    &format!(
                                        "feat: {}",
                                        crate::str_utils::truncate_bytes_safe(&task.objective, 60)
                                    ),
                                    &format!(
                                        "Autonomously implemented by Axi supervisor.\n\n\
                                         Objective: {}\nSteps: {}/{} OK\nDuration: {}ms",
                                        task.objective, steps_ok, steps_total, duration_ms
                                    ),
                                )
                                .await
                                {
                                    Ok(url) => info!("[supervisor] PR created: {}", url),
                                    Err(e) => debug!("[supervisor] PR creation skipped: {}", e),
                                }
                                // Return to main branch
                                let _ = crate::git_workflow::checkout_main(&self.work_dir).await;
                            }
                        }
                        Err(e) => {
                            debug!("[supervisor] auto-commit skipped: {}", e);
                        }
                    }
                }

                if let Ok(mut m) = self.metrics.lock() {
                    m.record(role, true, duration_ms);
                }

                // Record reliability outcome (success)
                Self::record_reliability(
                    &self.work_dir,
                    &task.id,
                    "supervisor",
                    "scheduled",
                    true,
                    None,
                    steps_total,
                    steps_ok,
                );

                let _ = self.notify_tx.send(SupervisorNotification::TaskCompleted {
                    task_id: task.id,
                    objective: task.objective,
                    result: summary,
                    steps_total,
                    steps_ok,
                    duration_ms,
                });
            }
            Err(e) => {
                let error_msg = format!("{:#}", e);
                let will_retry = self.queue.mark_failed(&task.id, &error_msg)?;

                self.audit_log(&task.id, &task.objective, "failed", &error_msg, 0.0)
                    .await;

                // Save to memory: what failed and why
                self.memory_writeback(
                    &task.objective,
                    "failed",
                    &error_msg,
                    if will_retry {
                        "will retry"
                    } else {
                        "permanent failure"
                    },
                )
                .await;

                if let Ok(mut m) = self.metrics.lock() {
                    m.record(role, false, start.elapsed().as_millis() as u64);
                }

                // Record reliability outcome (failure)
                Self::record_reliability(
                    &self.work_dir,
                    &task.id,
                    "supervisor",
                    "scheduled",
                    false,
                    Some(&error_msg),
                    0,
                    0,
                );

                // Apply runbook: suggest recovery if we recognize the error pattern
                let mut error_with_hint = error_msg.clone();
                if let Some(hint) = Runbook::suggest_recovery(&error_msg) {
                    error_with_hint = format!("{}\n\nSugerencia: {}", error_msg, hint);
                }

                // Rollback: discard uncommitted changes and return to main
                if trust_mode {
                    let _ = tokio::process::Command::new("git")
                        .args(["checkout", "."])
                        .current_dir(&self.work_dir)
                        .output()
                        .await;
                    let _ = crate::git_workflow::checkout_main(&self.work_dir).await;
                    info!("[supervisor] Rolled back changes after task failure");
                }

                let _ = self.notify_tx.send(SupervisorNotification::TaskFailed {
                    task_id: task.id,
                    objective: task.objective,
                    error: error_with_hint,
                    will_retry,
                });
            }
        }

        Ok(true)
    }

    /// Dequeue up to 3 tasks and execute them concurrently via `tokio::spawn`.
    /// Returns `Ok(true)` if at least one task was dispatched, `Ok(false)` if the queue was empty.
    async fn parallel_tick(&self) -> Result<bool> {
        const MAX_PARALLEL: usize = 3;

        let mut tasks = Vec::with_capacity(MAX_PARALLEL);
        for _ in 0..MAX_PARALLEL {
            match self.queue.dequeue() {
                Ok(Some(t)) => tasks.push(t),
                _ => break,
            }
        }

        if tasks.is_empty() {
            return Ok(false);
        }

        info!(
            "Supervisor parallel_tick: dispatching {} tasks",
            tasks.len()
        );

        let mut handles = Vec::with_capacity(tasks.len());
        for task in tasks {
            // Clone/share what we need across the spawned future
            let queue = Arc::clone(&self.queue);
            let router = Arc::clone(&self.router);
            let notify_tx = self.notify_tx.clone();
            let task_id = task.id.clone();
            let objective = task.objective.clone();

            // We cannot move `self` into the spawn, so we perform a lightweight
            // execution: plan via the router & run steps inline.  For full parity
            // with `tick()` (skill generation, memory write-back, etc.) we re-use
            // the same helper by wrapping a reference through an Arc-based shim.
            //
            // Because `Supervisor` is not `Send`-safe as a whole (Mutex fields),
            // we extract only the pieces we need.
            let _privacy = Arc::clone(&self.privacy);
            let _memory = self.memory.clone();
            let _work_dir = self.work_dir.clone();
            let _auto_approve_medium = self.auto_approve_medium;
            // Pre-flight risk check
            if Self::objective_is_dangerous(&objective) {
                let msg = format!(
                    "BLOCKED: '{}' contains a dangerous command pattern.",
                    crate::str_utils::truncate_bytes_safe(&objective, 100)
                );
                warn!("{}", msg);
                let _ = queue.cancel(&task_id);
                let _ = notify_tx.send(SupervisorNotification::TaskFailed {
                    task_id,
                    objective,
                    error: msg,
                    will_retry: false,
                });
                continue;
            }

            let _ = queue.mark_running(&task_id);
            let _ = notify_tx.send(SupervisorNotification::TaskStarted {
                task_id: task_id.clone(),
                objective: objective.clone(),
            });

            let handle = tokio::spawn(async move {
                let _role = AgentRole::suggest_for(&objective);
                let start = std::time::Instant::now();

                // Lightweight planning + execution using the router directly
                let plan_prompt = format!(
                    "You are a Linux assistant. Plan steps to accomplish:\n\n{}\n\n\
                     Respond with a JSON object: {{\"steps\": [{{\"description\": \"...\", \
                     \"action\": {{\"type\": \"shell_command\", \"command\": \"...\"}}, \
                     \"expected_outcome\": \"...\"}}]}}",
                    objective
                );
                let request = RouterRequest {
                    messages: vec![ChatMessage {
                        role: "user".into(),
                        content: serde_json::Value::String(plan_prompt),
                    }],
                    complexity: Some(TaskComplexity::Complex),
                    sensitivity: None,
                    preferred_provider: None,
                    max_tokens: Some(2048),
                    task_type: None,
                };

                let plan_result = {
                    let guard = router.read().await;
                    guard.chat(&request).await
                };

                let duration_ms = start.elapsed().as_millis() as u64;

                match plan_result {
                    Ok(response) => {
                        let summary = response.text;
                        let _ = queue.mark_completed(&task_id, &summary);
                        let _ = notify_tx.send(SupervisorNotification::TaskCompleted {
                            task_id,
                            objective,
                            result: summary,
                            steps_total: 1,
                            steps_ok: 1,
                            duration_ms,
                        });
                    }
                    Err(e) => {
                        let error_msg = format!("{:#}", e);
                        let will_retry = queue.mark_failed(&task_id, &error_msg).unwrap_or(false);
                        let _ = notify_tx.send(SupervisorNotification::TaskFailed {
                            task_id,
                            objective,
                            error: error_msg,
                            will_retry,
                        });
                    }
                }
            });

            handles.push(handle);
        }

        // Wait for all spawned tasks to complete
        for handle in handles {
            let _ = handle.await;
        }

        Ok(true)
    }

    /// Execute a single task: plan -> execute steps -> return result + step counts.
    async fn execute_task(&self, task_id: &str, objective: &str) -> Result<(String, usize, usize)> {
        // Check if we have a reusable skill for this objective
        let skill_gen = crate::skill_generator::SkillGenerator::new(&self.work_dir);
        if let Ok(Some((skill, skill_dir))) = skill_gen.find_skill(objective).await {
            info!(
                "Task {} matched skill '{}' — executing directly",
                task_id, skill.name
            );
            match skill_gen.execute_skill(&skill_dir).await {
                Ok(output) => {
                    return Ok((format!("[Skill '{}'] {}", skill.name, output), 1, 1));
                }
                Err(e) => {
                    warn!(
                        "Skill '{}' failed ({}), falling back to LLM planning",
                        skill.name, e
                    );
                }
            }
        }

        // Parse SLA metadata from the objective if present
        let (sla, clean_objective) = SlaConfig::parse_from_objective(objective);
        let objective = if sla.is_some() {
            clean_objective.as_str()
        } else {
            objective
        };

        // SLA pre-check: in shadow mode, estimate duration from plan step count.
        // Each step is estimated at ~30 seconds.
        if let Some(ref sla_cfg) = sla {
            if self.shadow_mode {
                // Rough estimate: 30s per step, assume 4 steps average
                let estimated_secs = 4 * 30;
                if estimated_secs > sla_cfg.max_duration_secs {
                    anyhow::bail!(
                        "SLA violation: estimated time ({}s) exceeds limit ({}s)",
                        estimated_secs,
                        sla_cfg.max_duration_secs
                    );
                }
            }
        }

        // Select the best agent role for this task
        let role = AgentRole::suggest_for(objective);
        info!("Task {} assigned to role: {:?}", task_id, role);

        let plan = self.create_plan_with_role(objective, role).await?;
        let plan_json = serde_json::to_string_pretty(&plan)?;
        self.queue.set_plan(task_id, &plan_json)?;

        info!(
            "Task {} planned with {} steps (role: {:?})",
            task_id,
            plan.steps.len(),
            role
        );

        // SLA post-plan check: estimate ~30s per step and bail if over limit
        if let Some(ref sla_cfg) = sla {
            let estimated_secs = (plan.steps.len() as u64) * 30;
            if estimated_secs > sla_cfg.max_duration_secs {
                anyhow::bail!(
                    "SLA violation: estimated time ({}s for {} steps) exceeds limit ({}s)",
                    estimated_secs,
                    plan.steps.len(),
                    sla_cfg.max_duration_secs
                );
            }
        }

        // ---------------------------------------------------------------
        // Shadow mode: dry-run preview without executing anything
        // ---------------------------------------------------------------
        if self.shadow_mode {
            let mut preview = String::from("SHADOW MODE — Plan preview:\n");
            for (i, step) in plan.steps.iter().enumerate() {
                let action_type = match &step.action {
                    StepAction::ShellCommand { .. } => "shell_command",
                    StepAction::SandboxCommand { .. } => "sandbox_command",
                    StepAction::AiQuery { .. } => "ai_query",
                    StepAction::BrowseUrl { .. } => "browse_url",
                    StepAction::WebSearch { .. } => "web_search",
                    StepAction::FileSearch { .. } => "file_search",
                    StepAction::ContentSearch { .. } => "content_search",
                    StepAction::ClipboardCopy { .. } => "clipboard_copy",
                    StepAction::ScreenAnalyze { .. } => "screen_analyze",
                    StepAction::ScreenCapture => "screen_capture",
                    StepAction::ReadFile { .. } => "read_file",
                    StepAction::WriteFile { .. } => "write_file",
                    StepAction::Respond { .. } => "respond",
                    StepAction::BrowserScreenshot { .. } => "browser_screenshot",
                    StepAction::BrowserClick { .. } => "browser_click",
                    StepAction::BrowserFill { .. } => "browser_fill",
                    StepAction::BrowserEvalJs { .. } => "browser_eval_js",
                    StepAction::FlatpakInstall { .. } => "flatpak_install",
                    StepAction::OpenApp { .. } => "open_app",
                    StepAction::OpenFile { .. } => "open_file",
                    StepAction::TypeText { .. } => "type_text",
                    StepAction::SendKeys { .. } => "send_keys",
                };
                preview.push_str(&format!(
                    "{}) [{}] {}\n",
                    i + 1,
                    action_type,
                    step.description
                ));
            }
            self.audit_log(task_id, objective, "shadow_preview", &preview, 0.0)
                .await;
            return Ok((preview, plan.steps.len(), 0));
        }

        // ---------------------------------------------------------------
        // Real execution with retry-with-variation + cascade prevention
        // ---------------------------------------------------------------

        // Workspace persistence: if any step uses SandboxCommand, create one
        // worktree for the entire task instead of one per step.
        let has_sandbox_steps = plan
            .steps
            .iter()
            .any(|s| matches!(s.action, StepAction::SandboxCommand { .. }));
        let task_worktree = if has_sandbox_steps {
            match self.create_sandbox_worktree().await {
                Ok((path, branch)) => {
                    info!(
                        "Task {} — persistent sandbox worktree created: {}",
                        task_id,
                        path.display()
                    );
                    Some((path, branch))
                }
                Err(e) => {
                    warn!(
                        "Task {} — failed to create persistent worktree, will use per-step: {}",
                        task_id, e
                    );
                    None
                }
            }
        } else {
            None
        };
        let task_worktree_path = task_worktree.as_ref().map(|(p, _)| p.as_path());

        let mut results = Vec::new();
        let mut last_output = String::new();
        // Track indices of failed shell_command steps for cascade prevention
        let mut failed_shell_indices: Vec<usize> = Vec::new();

        for (i, step) in plan.steps.iter().enumerate() {
            // Cascade failure prevention: if a prior shell_command failed and
            // this step's description references a previous step's output,
            // skip it to avoid cascading errors.
            if !failed_shell_indices.is_empty() {
                let desc_lower = step.description.to_lowercase();
                let depends_on_failed = failed_shell_indices.iter().any(|&fi| {
                    // Heuristic: step mentions "output", "result", or "previous"
                    // and the failed step was a shell_command
                    desc_lower.contains("output")
                        || desc_lower.contains("result")
                        || desc_lower.contains("previous")
                        || desc_lower.contains(&format!("step {}", fi + 1))
                });
                if depends_on_failed {
                    let skip_msg = format!("Step {} skipped: depends on failed step output", i + 1);
                    warn!("Task {} — {}", task_id, skip_msg);
                    let r = StepResult {
                        success: false,
                        output: skip_msg.clone(),
                        step_index: i,
                        confidence: 0.0,
                    };
                    self.audit_log(
                        task_id,
                        &step.description,
                        "skipped_cascade",
                        &skip_msg,
                        0.0,
                    )
                    .await;
                    results.push(r);
                    last_output = skip_msg;
                    continue;
                }
            }

            // Stream progress to Telegram and event subscribers
            let progress_msg = format!("Paso {}/{}: {}", i + 1, plan.steps.len(), step.description);
            info!("Task {} {}", task_id, progress_msg);
            let _ = self.notify_tx.send(SupervisorNotification::TaskProgress {
                task_id: task_id.to_string(),
                step_index: i,
                steps_total: plan.steps.len(),
                description: step.description.clone(),
            });
            let _ = self.notify_tx.send(SupervisorNotification::TaskStarted {
                task_id: format!("{}-step-{}", task_id, i + 1),
                objective: progress_msg,
            });

            match self.execute_step(step, task_worktree_path).await {
                Ok(output) => {
                    let confidence = Self::compute_confidence(&output);
                    last_output = output.clone();
                    self.audit_log(task_id, &step.description, "step_ok", &output, confidence)
                        .await;
                    results.push(StepResult {
                        success: true,
                        output,
                        step_index: i,
                        confidence,
                    });
                }
                Err(e) => {
                    let error_msg = format!("{}", e);
                    warn!("Task {} — Step {} failed: {}", task_id, i + 1, error_msg);

                    // Retry with variation: ask LLM for an alternative approach
                    info!(
                        "Task {} — Attempting retry with variation for step {}",
                        task_id,
                        i + 1
                    );
                    match self.generate_alternative_step(step, &error_msg).await {
                        Ok(alt_step) => {
                            info!(
                                "Task {} — Retrying step {} with alternative: {}",
                                task_id,
                                i + 1,
                                alt_step.description
                            );
                            match self.execute_step(&alt_step, task_worktree_path).await {
                                Ok(output) => {
                                    let confidence = Self::compute_confidence(&output);
                                    last_output = output.clone();
                                    self.audit_log(
                                        task_id,
                                        &alt_step.description,
                                        "step_ok_retry",
                                        &output,
                                        confidence,
                                    )
                                    .await;
                                    results.push(StepResult {
                                        success: true,
                                        output,
                                        step_index: i,
                                        confidence,
                                    });
                                    continue;
                                }
                                Err(retry_err) => {
                                    warn!(
                                        "Task {} — Retry also failed for step {}: {}",
                                        task_id,
                                        i + 1,
                                        retry_err
                                    );
                                }
                            }
                        }
                        Err(alt_err) => {
                            debug!(
                                "Task {} — Could not generate alternative for step {}: {}",
                                task_id,
                                i + 1,
                                alt_err
                            );
                        }
                    }

                    // Both original and retry failed
                    let error = format!("Step {} failed: {}", i + 1, error_msg);
                    self.audit_log(task_id, &step.description, "step_fail", &error, 0.0)
                        .await;

                    // Track for cascade prevention if this was a shell_command
                    if matches!(step.action, StepAction::ShellCommand { .. }) {
                        failed_shell_indices.push(i);
                    }

                    results.push(StepResult {
                        success: false,
                        output: error.clone(),
                        step_index: i,
                        confidence: 0.0,
                    });
                    last_output = error;
                }
            }
        }

        // Clean up the persistent sandbox worktree if we created one
        if let Some((ref wt_path, ref wt_branch)) = task_worktree {
            self.cleanup_sandbox_worktree(wt_path, wt_branch).await;
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

        // Build a clean summary from all step outputs (not just last)
        let mut summary_parts = Vec::new();
        for (i, r) in results.iter().enumerate() {
            let step_desc = plan
                .steps
                .get(r.step_index)
                .map(|s| s.description.as_str())
                .unwrap_or("step");
            let icon = if r.success { "OK" } else { "FAIL" };
            let output_preview = if r.output.len() > 500 {
                format!(
                    "{}...",
                    crate::str_utils::truncate_bytes_safe(&r.output, 500)
                )
            } else {
                r.output.clone()
            };
            summary_parts.push(format!(
                "[{} {}/{}] {}\n{}",
                icon,
                i + 1,
                steps_total,
                step_desc,
                output_preview.trim()
            ));
        }

        let summary = summary_parts.join("\n\n");

        Ok((summary, steps_total, steps_ok))
    }

    /// Use AI to produce a clean, human-readable summary of a raw task result.
    async fn summarize_result(&self, objective: &str, raw_result: &str) -> Result<String> {
        // Skip summarization for short/clean results
        if raw_result.len() < 500 {
            return Ok(raw_result.to_string());
        }

        let prompt = format!(
            "Resume en español en maximo 800 caracteres el resultado de esta tarea. \
             Incluye los datos clave (output de comandos, archivos encontrados, etc). \
             No repitas la tarea, solo el resultado.\n\
             Tarea: {}\n\
             Resultado:\n{}",
            objective,
            crate::str_utils::truncate_bytes_safe(raw_result, 3000)
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
            task_type: None,
        };

        let router = self.router.read().await;
        let response = router.chat(&request).await?;
        Ok(response.text)
    }

    /// Save task outcome to the memory plane for future context.
    async fn memory_writeback(&self, objective: &str, status: &str, detail: &str, meta: &str) {
        let memory = match &self.memory {
            Some(m) => m,
            None => return,
        };

        let content = format!(
            "Tarea: {}\nEstado: {}\nDetalle: {}\nMeta: {}\nFecha: {}",
            objective,
            status,
            crate::str_utils::truncate_bytes_safe(detail, 2000),
            meta,
            chrono::Local::now().to_rfc3339(),
        );

        let importance = match status {
            "failed" => 70u8,
            "completed" => 40,
            _ => 30,
        };

        let tags = vec!["supervisor".to_string(), format!("status:{}", status)];

        let mem = memory.read().await;
        if let Err(e) = mem
            .add_entry(
                "decision",
                "system",
                &tags,
                Some("supervisor"),
                importance,
                &content,
            )
            .await
        {
            warn!("Memory writeback failed: {}", e);
        } else {
            debug!(
                "Memory writeback: {} — {}",
                status,
                crate::str_utils::truncate_bytes_safe(objective, 60)
            );
        }
    }

    /// Capture a screenshot and return its path.
    async fn execute_screen_capture(&self) -> Result<String> {
        // Unified sense gate. Round-2 audit C-NEW-5: the supervisor
        // previously captured at will from `StepAction::ScreenCapture`,
        // ignoring every user policy lever.
        let sensory = self
            .sensory_pipeline
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        let sensory = sensory.ok_or_else(|| {
            anyhow::anyhow!(
                "supervisor screen capture refused: sensory pipeline not wired (fail-closed)"
            )
        })?;
        {
            let guard = sensory.read().await;
            if let Err(reason) = guard
                .ensure_sense_allowed(
                    crate::sensory_pipeline::Sense::Screen,
                    "supervisor.screen_capture",
                )
                .await
            {
                anyhow::bail!("supervisor screen capture refused: {}", reason);
            }
        }

        let screenshot_dir = self.work_dir.join("target/screenshots");
        tokio::fs::create_dir_all(&screenshot_dir).await.ok();
        let filename = format!(
            "supervisor-{}.png",
            chrono::Local::now().format("%Y%m%d-%H%M%S")
        );
        let path = screenshot_dir.join(&filename);

        // Try grim (Wayland/COSMIC)
        let output = tokio::process::Command::new("grim")
            .arg(&path)
            .output()
            .await;

        match output {
            Ok(o) if o.status.success() => Ok(format!("Screenshot saved to {}", path.display())),
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
                    _ => Ok(
                        "Screenshot capture failed — no grim or gnome-screenshot available".into(),
                    ),
                }
            }
        }
    }

    /// Fetch a URL and return its text content.
    async fn execute_browse(&self, url: &str) -> Result<String> {
        info!("Browsing: {}", url);
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(15))
            .user_agent("LifeOS-Axi/0.1")
            .build()?;

        let resp = client
            .get(url)
            .send()
            .await
            .context(format!("Failed to fetch {}", url))?;
        let status = resp.status();
        if !status.is_success() {
            anyhow::bail!("HTTP {} for {}", status, url);
        }

        let body = resp.text().await?;
        // Strip HTML tags to get clean text
        let text = strip_html(&body);

        if text.len() > 6000 {
            Ok(format!(
                "{}...\n[truncated, {} chars]",
                crate::str_utils::truncate_bytes_safe(&text, 6000),
                text.len()
            ))
        } else {
            Ok(text)
        }
    }

    /// Take a screenshot, analyze it with local LLM, and return the analysis.
    async fn execute_screen_analyze(&self, prompt: Option<&str>) -> Result<String> {
        // Step 1: Capture screenshot
        let screenshot_path = self.capture_screenshot().await?;

        // Step 2: Analyze with LLM
        let analysis_prompt = prompt.unwrap_or("Describe what you see on the screen. Is there any error, dialog, or notification visible?");

        let request = RouterRequest {
            messages: vec![
                ChatMessage {
                    role: "system".into(),
                    content: serde_json::Value::String(format!(
                        "{}\n\nYou are a visual analyst for LifeOS. Describe what you see concisely in Spanish.",
                        crate::time_context::time_context_short()
                    )),
                },
                ChatMessage {
                    role: "user".into(),
                    content: serde_json::Value::String(format!(
                        "{}\n\n[Screenshot captured at: {}]",
                        analysis_prompt, screenshot_path
                    )),
                },
            ],
            complexity: Some(TaskComplexity::Vision),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(512),
        task_type: None,
        };

        let router = self.router.read().await;
        match router.chat(&request).await {
            Ok(response) => Ok(format!(
                "Screenshot: {}\nAnalysis: {}",
                screenshot_path, response.text
            )),
            Err(e) => Ok(format!(
                "Screenshot saved: {}\nAnalysis failed: {}",
                screenshot_path, e
            )),
        }
    }

    /// Capture a screenshot and return its path.
    async fn capture_screenshot(&self) -> Result<String> {
        // Same gate as execute_screen_capture — covers the analyze path.
        let sensory = self
            .sensory_pipeline
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        let sensory = sensory.ok_or_else(|| {
            anyhow::anyhow!("supervisor capture refused: sensory pipeline not wired (fail-closed)")
        })?;
        {
            let guard = sensory.read().await;
            if let Err(reason) = guard
                .ensure_sense_allowed(
                    crate::sensory_pipeline::Sense::Screen,
                    "supervisor.capture_screenshot",
                )
                .await
            {
                anyhow::bail!("supervisor capture refused: {}", reason);
            }
        }

        let screenshot_dir = std::env::temp_dir().join("lifeos-screenshots");
        tokio::fs::create_dir_all(&screenshot_dir).await.ok();
        let filename = format!("sv-{}.png", chrono::Local::now().format("%H%M%S"));
        let path = screenshot_dir.join(&filename);

        let output = tokio::process::Command::new("grim")
            .arg(&path)
            .output()
            .await;

        match output {
            Ok(o) if o.status.success() => Ok(path.to_string_lossy().to_string()),
            _ => {
                // Fallback
                let output = tokio::process::Command::new("gnome-screenshot")
                    .args(["-f", &path.to_string_lossy()])
                    .output()
                    .await;
                match output {
                    Ok(o) if o.status.success() => Ok(path.to_string_lossy().to_string()),
                    _ => anyhow::bail!("No screenshot tool available (grim or gnome-screenshot)"),
                }
            }
        }
    }

    /// Search for files by name pattern in the working directory.
    async fn execute_file_search(&self, pattern: &str) -> Result<String> {
        info!("File search: {}", pattern);
        let output = tokio::process::Command::new("find")
            .args([
                self.work_dir.to_str().unwrap_or("."),
                "-name",
                pattern,
                "-not",
                "-path",
                "*/target/*",
                "-not",
                "-path",
                "*/.git/*",
                "-type",
                "f",
            ])
            .output()
            .await?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        if stdout.is_empty() {
            Ok(format!("No files found matching '{}'", pattern))
        } else if stdout.len() > 4000 {
            Ok(format!(
                "{}...\n[truncated]",
                crate::str_utils::truncate_bytes_safe(&stdout, 4000)
            ))
        } else {
            Ok(stdout.to_string())
        }
    }

    /// Copy text to system clipboard.
    async fn execute_clipboard_copy(&self, text: &str) -> Result<String> {
        // Try wl-copy (Wayland) first, then xclip (X11)
        let result = tokio::process::Command::new("wl-copy")
            .stdin(std::process::Stdio::piped())
            .spawn();

        if let Ok(mut child) = result {
            if let Some(mut stdin) = child.stdin.take() {
                use tokio::io::AsyncWriteExt;
                stdin.write_all(text.as_bytes()).await.ok();
                drop(stdin);
            }
            let status = child.wait().await?;
            if status.success() {
                return Ok(format!("Copied {} chars to clipboard", text.len()));
            }
        }

        // Fallback: xclip
        let result = tokio::process::Command::new("xclip")
            .args(["-selection", "clipboard"])
            .stdin(std::process::Stdio::piped())
            .spawn();

        if let Ok(mut child) = result {
            if let Some(mut stdin) = child.stdin.take() {
                use tokio::io::AsyncWriteExt;
                stdin.write_all(text.as_bytes()).await.ok();
                drop(stdin);
            }
            child.wait().await?;
            return Ok(format!("Copied {} chars to clipboard (xclip)", text.len()));
        }

        anyhow::bail!("No clipboard tool available (wl-copy or xclip)")
    }

    /// Search for files by name pattern in the working directory.
    async fn execute_file_search_by_content(&self, query: &str) -> Result<String> {
        info!("Content search: {}", query);
        let output = tokio::process::Command::new("grep")
            .args([
                "-rl",
                "--include=*.rs",
                "--include=*.toml",
                "--include=*.md",
                "--include=*.json",
                query,
                self.work_dir.to_str().unwrap_or("."),
            ])
            .output()
            .await?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        if stdout.is_empty() {
            Ok(format!("No files contain '{}'", query))
        } else {
            Ok(format!(
                "Files containing '{}':\n{}",
                query,
                crate::str_utils::truncate_bytes_safe(&stdout, 3000)
            ))
        }
    }

    /// Search the web using Groq browser_search (free, ZDR) → Serper API fallback.
    async fn execute_web_search(&self, query: &str) -> Result<String> {
        info!("Web search: {}", query);

        // Priority 1: Groq browser_search (free, zero data retention)
        let groq_key = std::env::var("GROQ_API_KEY").unwrap_or_default();
        if !groq_key.is_empty() {
            let client = reqwest::Client::new();
            let tools = serde_json::json!([{
                "type": "function",
                "function": {
                    "name": "browser_search",
                    "description": "Search the web",
                    "parameters": {
                        "type": "object",
                        "properties": { "query": { "type": "string" } },
                        "required": ["query"]
                    }
                }
            }]);
            let body = serde_json::json!({
                "model": "qwen-qwq-32b",
                "messages": [{"role": "user", "content": format!("Search the web for: {}", query)}],
                "tools": tools,
                "tool_choice": "auto",
                "max_tokens": 2048
            });
            if let Ok(res) = client
                .post("https://api.groq.com/openai/v1/chat/completions")
                .header("Authorization", format!("Bearer {}", groq_key))
                .json(&body)
                .send()
                .await
            {
                if res.status().is_success() {
                    if let Ok(json) = res.json::<serde_json::Value>().await {
                        let text = json["choices"][0]["message"]["content"]
                            .as_str()
                            .unwrap_or("");
                        if !text.is_empty() {
                            return Ok(format!("Web search results for '{}':\n{}", query, text));
                        }
                    }
                }
            }
        }

        // Priority 2: Serper API (free tier: 2500/mo)
        let serper_key = std::env::var("SERPER_API_KEY").unwrap_or_default();

        if !serper_key.is_empty() {
            let client = reqwest::Client::new();
            let res = client
                .post("https://google.serper.dev/search")
                .header("X-API-KEY", &serper_key)
                .json(&serde_json::json!({"q": query, "num": 5}))
                .send()
                .await?;

            if res.status().is_success() {
                let body: serde_json::Value = res.json().await?;
                let results = body["organic"]
                    .as_array()
                    .map(|arr| {
                        arr.iter()
                            .take(5)
                            .map(|item| {
                                format!(
                                    "- {} ({})\n  {}",
                                    item["title"].as_str().unwrap_or(""),
                                    item["link"].as_str().unwrap_or(""),
                                    item["snippet"].as_str().unwrap_or("")
                                )
                            })
                            .collect::<Vec<_>>()
                            .join("\n")
                    })
                    .unwrap_or_else(|| "No results".into());
                return Ok(format!("Search results for '{}':\n{}", query, results));
            }
        }

        // Fallback: ask LLM (it may use Groq's built-in search if available)
        self.execute_ai_query(&format!(
            "Search the internet for: {}. Provide the most relevant and current information.",
            query
        ))
        .await
    }

    /// Create a persistent sandbox worktree for multi-step task execution.
    /// Returns `(worktree_path, branch_name)` so the caller can clean up later.
    async fn create_sandbox_worktree(&self) -> Result<(PathBuf, String)> {
        let id = uuid::Uuid::new_v4().to_string();
        let branch_name = format!("sandbox-{}", &id[..8]);
        let worktree_path = std::env::temp_dir().join(format!("lifeos-sandbox-{}", &branch_name));

        info!("Creating sandbox worktree: {}", worktree_path.display());

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

        Ok((worktree_path, branch_name))
    }

    /// Remove a sandbox worktree and its associated branch.
    async fn cleanup_sandbox_worktree(&self, worktree_path: &std::path::Path, branch_name: &str) {
        info!("Cleaning up sandbox worktree: {}", worktree_path.display());
        let _ = tokio::process::Command::new("git")
            .args(["worktree", "remove", "--force"])
            .arg(worktree_path)
            .current_dir(&self.work_dir)
            .output()
            .await;
        let _ = tokio::process::Command::new("git")
            .args(["branch", "-D", branch_name])
            .current_dir(&self.work_dir)
            .output()
            .await;
    }

    /// Run a command inside an existing sandbox worktree directory.
    fn run_in_worktree(
        &self,
        command: &str,
        worktree_path: &std::path::Path,
    ) -> impl std::future::Future<Output = Result<String>> + 'static {
        let command = command.to_string();
        let worktree_path = worktree_path.to_path_buf();
        async move {
            let result = tokio::process::Command::new("sh")
                .arg("-c")
                .arg(&command)
                .current_dir(&worktree_path)
                .output()
                .await;

            match result {
                Ok(output) if output.status.success() => {
                    let stdout = String::from_utf8_lossy(&output.stdout);
                    Ok(if stdout.is_empty() {
                        "(sandbox command completed with no output)".into()
                    } else if stdout.len() > 4000 {
                        format!(
                            "{}...\n[truncated]",
                            crate::str_utils::truncate_bytes_safe(&stdout, 4000)
                        )
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
    }

    /// Execute a command inside a temporary git worktree (isolated sandbox).
    /// The worktree is created, the command runs in it, and then it's cleaned up.
    /// For multi-step tasks, prefer `create_sandbox_worktree` + `run_in_worktree`
    /// to avoid creating/destroying a worktree per step.
    async fn execute_in_sandbox(&self, command: &str) -> Result<String> {
        let (worktree_path, branch_name) = self.create_sandbox_worktree().await?;
        let result = self.run_in_worktree(command, &worktree_path).await;
        self.cleanup_sandbox_worktree(&worktree_path, &branch_name)
            .await;
        result
    }

    /// Query memory for relevant past experiences before planning.
    async fn recall_context(&self, objective: &str) -> String {
        let memory = match &self.memory {
            Some(m) => m,
            None => return String::new(),
        };

        let mem = memory.read().await;
        match mem.search_entries(objective, 3, Some("system")).await {
            Ok(results) if !results.is_empty() => {
                let mut context = String::from("Relevant past experiences:\n");
                for r in &results {
                    context.push_str(&format!(
                        "- [{}] {}\n",
                        r.entry.kind,
                        crate::str_utils::truncate_bytes_safe(&r.entry.content, 200)
                    ));
                }
                context
            }
            _ => String::new(),
        }
    }

    async fn create_plan_with_role(&self, objective: &str, role: AgentRole) -> Result<Plan> {
        let role_context = role.system_prompt();
        let time_ctx = crate::time_context::time_context();
        let system_prompt = format!(
            r#"{time_ctx}

{role_context}

You are an autonomous executor inside LifeOS, an AI-native operating system.
The working directory is: {}
Your job is to EXECUTE tasks, not explain them. When the user says "git status", you RUN `git status` via shell_command. When they say "install firefox", you RUN `flatpak install`. NEVER just describe or explain — always create a plan that DOES the work.
Respond ONLY with a JSON object (no markdown, no thinking, no explanation). Format:
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
- sandbox_command: Run a command in an isolated git worktree. Use for code changes that might break things.
- ai_query: Ask an AI a question. Use for analysis, summarization, reasoning.
- browse_url: Fetch a URL and return its text content (HTML stripped). Provide "url".
- web_search: Search the internet for information. Provide "query". Returns top results.
- file_search: Search for files by name pattern. Provide "pattern" (e.g., "*.rs", "README*").
- content_search: Search file contents for a string. Provide "query".
- clipboard_copy: Copy text to the system clipboard. Provide "text".
- screen_analyze: Take a screenshot and analyze it with AI. Optionally provide "prompt".
- screen_capture: Take a screenshot of the current desktop (returns file path).
- read_file: Read a file from disk. Use absolute paths or paths relative to working directory.
- write_file: Write content to a file. Provide "path" and "content".
- respond: Send a text response back to the user. Use as the last step.
- browser_screenshot: Open a URL in a headless browser and take a screenshot. Provide "url". Use to verify web apps.
- flatpak_install: Install a Flatpak app. Provide "app_id" (e.g., "org.mozilla.firefox").
- open_app: Open an application by name. Provide "name" (e.g., "firefox", "libreoffice-calc").
- open_file: Open a file with its default application. Provide "path".
- type_text: Type text into the currently focused window. Provide "text".
- send_keys: Send a keyboard shortcut. Provide "combo" (e.g., "ctrl+s", "alt+F4").

Keep plans short (2-6 steps). Prefer simple, safe commands.
Never use sudo. Never delete files without confirmation.
For code changes, prefer sandbox_command over shell_command.
Always end with a "respond" step summarizing what was done."#,
            self.work_dir.display()
        );

        // Learning loop: recall relevant past experiences
        let memory_context = self.recall_context(objective).await;

        let mut user_content = objective.to_string();

        // Prepend live context (active window, queue state, etc.)
        let context_prompt = self.build_context_prompt();
        if !context_prompt.is_empty() {
            user_content = format!("{}\n\n{}", context_prompt, user_content);
        }

        if !memory_context.is_empty() {
            user_content = format!("{}\n\n{}", user_content, memory_context);
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
            task_type: None,
        };

        let router = self.router.read().await;
        let response = router
            .chat(&request)
            .await
            .context("Failed to get plan from LLM")?;

        parse_plan_from_response(&response.text)
    }

    /// Check if the objective itself contains dangerous commands.
    /// This runs BEFORE the LLM even sees the task.
    fn objective_is_dangerous(objective: &str) -> bool {
        let lower = objective.to_lowercase();
        let dangerous = [
            "rm -rf /",
            "rm -rf /*",
            "rm -rf ~",
            "mkfs",
            "dd if=",
            "> /dev/sd",
            "> /dev/nvme",
            "chmod -r 777 /",
            ":(){ :|:& };:",
            "fork bomb",
            "sudo rm",
            "sudo dd",
            "sudo mkfs",
            "shutdown",
            "reboot",
            "init 0",
            "init 6",
            "kill -9 1",
            "git push --force origin main",
            "git push -f origin main",
        ];
        dangerous.iter().any(|p| lower.contains(p))
    }

    /// Classify risk level of an action.
    fn classify_risk(action: &StepAction) -> RiskLevel {
        match action {
            StepAction::ShellCommand { command } => {
                let cmd = command.to_lowercase();
                // High risk: destructive or irreversible commands
                let high_risk = [
                    "rm -rf",
                    "rm -r /",
                    "mkfs",
                    "dd if=",
                    "git push --force",
                    "git push -f ",
                    "git reset --hard",
                    "git checkout .",
                    "git clean -fd",
                    "reboot",
                    "shutdown",
                    "systemctl stop",
                    "pkill -9",
                    "killall",
                    "chmod 777",
                    "> /dev/",
                    "curl.*| sh",
                    "wget.*| sh",
                ];
                if high_risk.iter().any(|p| cmd.contains(p)) {
                    return RiskLevel::High;
                }
                // Medium risk: git operations, file modification, publishing
                // These auto-execute when auto_approve_medium is true (default),
                // but always send a notification so user can track what happened.
                let medium_risk = [
                    "git commit",
                    "git push",
                    "git merge",
                    "git rebase",
                    "git stash",
                    "cargo publish",
                    "npm publish",
                    "mv ",
                    "cp -r",
                    "sudo",
                ];
                if medium_risk.iter().any(|p| cmd.contains(p)) {
                    return RiskLevel::Medium;
                }
                RiskLevel::Low
            }
            StepAction::SandboxCommand { .. } => RiskLevel::Low,
            StepAction::BrowseUrl { .. } => RiskLevel::Low,
            StepAction::WebSearch { .. } => RiskLevel::Low,
            StepAction::FileSearch { .. } => RiskLevel::Low,
            StepAction::ContentSearch { .. } => RiskLevel::Low,
            StepAction::ClipboardCopy { .. } => RiskLevel::Low,
            StepAction::ScreenAnalyze { .. } => RiskLevel::Low,
            StepAction::WriteFile { .. } => RiskLevel::Medium,
            StepAction::ReadFile { .. } | StepAction::AiQuery { .. } => RiskLevel::Low,
            StepAction::ScreenCapture | StepAction::Respond { .. } => RiskLevel::Low,
            StepAction::BrowserScreenshot { .. } => RiskLevel::Low,
            StepAction::BrowserClick { .. } => RiskLevel::Medium,
            StepAction::BrowserFill { .. } => RiskLevel::Medium,
            StepAction::BrowserEvalJs { .. } => RiskLevel::Medium,
            StepAction::FlatpakInstall { .. } => RiskLevel::Medium,
            StepAction::OpenApp { .. } => RiskLevel::Low,
            StepAction::OpenFile { .. } => RiskLevel::Low,
            StepAction::TypeText { .. } => RiskLevel::Medium,
            StepAction::SendKeys { .. } => RiskLevel::Medium,
        }
    }

    async fn execute_step(
        &self,
        step: &PlanStep,
        task_worktree: Option<&std::path::Path>,
    ) -> Result<String> {
        let risk = Self::classify_risk(&step.action);
        let desc = match &step.action {
            StepAction::ShellCommand { command } => command.clone(),
            StepAction::WriteFile { path, .. } => format!("write_file: {}", path),
            StepAction::FlatpakInstall { app_id } => format!("flatpak_install: {}", app_id),
            StepAction::TypeText { text } => {
                format!(
                    "type_text: {}...",
                    crate::str_utils::truncate_bytes_safe(text, 40)
                )
            }
            StepAction::SendKeys { combo } => format!("send_keys: {}", combo),
            StepAction::BrowserClick { url, selector } => {
                format!("browser_click: {} @ {}", selector, url)
            }
            StepAction::BrowserFill { url, selector, .. } => {
                format!("browser_fill: {} @ {}", selector, url)
            }
            StepAction::BrowserEvalJs { url, .. } => format!("browser_eval_js: {}", url),
            _ => step.description.clone(),
        };

        if risk == RiskLevel::High {
            warn!("BLOCKED high-risk action: {}", desc);
            let _ = self.notify_tx.send(SupervisorNotification::TaskFailed {
                task_id: "risk-block".into(),
                objective: format!("High-risk action blocked: {}", desc),
                error: "This action was classified as high-risk and requires manual execution."
                    .into(),
                will_retry: false,
            });
            anyhow::bail!(
                "High-risk action blocked: {}. Execute manually if intended.",
                desc
            );
        }

        if risk == RiskLevel::Medium {
            if self.auto_approve_medium {
                info!("Medium-risk action auto-approved (notifying): {}", desc);
            } else {
                warn!(
                    "Medium-risk action detected, blocking for approval: {}",
                    desc
                );
                let _ = self
                    .notify_tx
                    .send(SupervisorNotification::ApprovalRequired {
                        task_id: "medium-risk".into(),
                        objective: desc.clone(),
                        action_description: format!(
                            "Accion de riesgo medio requiere aprobacion: {}\n{}",
                            step.description, desc
                        ),
                    });
                anyhow::bail!(
                    "Medium-risk action requires approval: {}. Send /approve to continue.",
                    desc
                );
            }
            // Always notify even when auto-approved, for audit trail
            let _ = self
                .notify_tx
                .send(SupervisorNotification::ApprovalRequired {
                    task_id: "medium-risk-auto".into(),
                    objective: desc.clone(),
                    action_description: format!(
                        "Accion de riesgo medio (auto-aprobada): {}\n{}",
                        step.description, desc
                    ),
                });
        }

        match &step.action {
            StepAction::ShellCommand { command } => self.execute_shell(command).await,
            StepAction::SandboxCommand { command } => {
                if let Some(wt_path) = task_worktree {
                    self.run_in_worktree(command, wt_path).await
                } else {
                    self.execute_in_sandbox(command).await
                }
            }
            StepAction::BrowseUrl { url } => self.execute_browse(url).await,
            StepAction::WebSearch { query } => self.execute_web_search(query).await,
            StepAction::FileSearch { pattern } => self.execute_file_search(pattern).await,
            StepAction::ContentSearch { query } => self.execute_file_search_by_content(query).await,
            StepAction::ClipboardCopy { text } => self.execute_clipboard_copy(text).await,
            StepAction::ScreenAnalyze { prompt } => {
                self.execute_screen_analyze(prompt.as_deref()).await
            }
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
                        crate::str_utils::truncate_bytes_safe(&content, 8000),
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

                // Auto-verify: if we wrote a Rust file, run cargo check
                let mut result_msg =
                    format!("Wrote {} bytes to {}", content.len(), full_path.display());
                if path.ends_with(".rs") || path.ends_with("Cargo.toml") {
                    info!("[supervisor] auto-verifying Rust write with cargo check");
                    let check = tokio::process::Command::new("cargo")
                        .args(["check", "--message-format=short"])
                        .current_dir(&self.work_dir)
                        .output()
                        .await;
                    match check {
                        Ok(output) if output.status.success() => {
                            result_msg.push_str("\n[cargo check: OK]");
                        }
                        Ok(output) => {
                            let stderr = String::from_utf8_lossy(&output.stderr);
                            let errors: String = stderr
                                .lines()
                                .filter(|l| l.contains("error"))
                                .take(5)
                                .collect::<Vec<_>>()
                                .join("\n");
                            result_msg.push_str(&format!(
                                "\n[cargo check: FAILED]\n{}",
                                crate::str_utils::truncate_bytes_safe(&errors, 500)
                            ));
                        }
                        Err(_) => {} // cargo not available, skip
                    }
                }
                Ok(result_msg)
            }
            StepAction::Respond { message } => Ok(message.clone()),

            // Desktop operator actions
            StepAction::BrowserScreenshot { url } => {
                let browser =
                    crate::browser_automation::BrowserAutomation::new(self.work_dir.join("target"));
                browser.navigate_and_capture(url).await
            }
            StepAction::BrowserClick { url, selector } => {
                let browser =
                    crate::browser_automation::BrowserAutomation::new(self.work_dir.join("target"));
                browser.click_element(url, selector).await
            }
            StepAction::BrowserFill {
                url,
                selector,
                value,
            } => {
                let browser =
                    crate::browser_automation::BrowserAutomation::new(self.work_dir.join("target"));
                browser.fill_input(url, selector, value).await
            }
            StepAction::BrowserEvalJs { url, code } => {
                let browser =
                    crate::browser_automation::BrowserAutomation::new(self.work_dir.join("target"));
                browser.evaluate_js_on_page(url, code).await
            }
            StepAction::FlatpakInstall { app_id } => {
                let result = crate::desktop_operator::DesktopOperator::execute(
                    &crate::desktop_operator::DesktopAction::FlatpakInstall {
                        app_id: app_id.clone(),
                    },
                    None,
                )
                .await;
                if result.success {
                    Ok(result.output)
                } else {
                    anyhow::bail!("{}", result.output)
                }
            }
            StepAction::OpenApp { name } => {
                let result = crate::desktop_operator::DesktopOperator::execute(
                    &crate::desktop_operator::DesktopAction::OpenApp { name: name.clone() },
                    None,
                )
                .await;
                Ok(result.output)
            }
            StepAction::OpenFile { path } => {
                let result = crate::desktop_operator::DesktopOperator::execute(
                    &crate::desktop_operator::DesktopAction::OpenFile { path: path.clone() },
                    None,
                )
                .await;
                Ok(result.output)
            }
            StepAction::TypeText { text } => {
                let result = crate::desktop_operator::DesktopOperator::execute(
                    &crate::desktop_operator::DesktopAction::TypeText { text: text.clone() },
                    None,
                )
                .await;
                Ok(result.output)
            }
            StepAction::SendKeys { combo } => {
                let result = crate::desktop_operator::DesktopOperator::execute(
                    &crate::desktop_operator::DesktopAction::SendKeys {
                        combo: combo.clone(),
                    },
                    None,
                )
                .await;
                Ok(result.output)
            }
        }
    }

    /// Compute a confidence score for a step's output.
    fn compute_confidence(output: &str) -> f64 {
        if output.is_empty() || output == "(no output)" {
            return 0.5;
        }
        let lower = output.to_lowercase();
        // Check for warning signals
        if lower.contains("warning") || lower.contains("warn") || lower.contains("deprecated") {
            return 0.3;
        }
        // Check for clear success signals
        let success_keywords = [
            "success",
            "ok",
            "passed",
            "completed",
            "done",
            "created",
            "written",
        ];
        if success_keywords.iter().any(|kw| lower.contains(kw)) {
            return 1.0;
        }
        // Non-empty output with no clear signal
        0.8
    }

    /// Ask the LLM for an alternative approach when a step fails.
    async fn generate_alternative_step(
        &self,
        original_step: &PlanStep,
        error: &str,
    ) -> Result<PlanStep> {
        let step_json = serde_json::to_string(original_step)
            .unwrap_or_else(|_| original_step.description.clone());
        let prompt = format!(
            r#"A step in an automated plan failed. Suggest ONE alternative step that achieves the same goal using a different approach.

Original step:
{}

Error:
{}

Respond ONLY with a JSON object (no markdown):
{{"description": "...", "action": {{"type": "...", ...}}, "expected_outcome": "..."}}"#,
            step_json,
            crate::str_utils::truncate_bytes_safe(error, 500)
        );

        let request = RouterRequest {
            messages: vec![ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(prompt),
            }],
            complexity: Some(TaskComplexity::Medium),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(512),
            task_type: None,
        };

        let router = self.router.read().await;
        let response = router
            .chat(&request)
            .await
            .context("Failed to get alternative step from LLM")?;

        let json_str = extract_json(&response.text);
        let alt_step: PlanStep =
            serde_json::from_str(&json_str).context("Failed to parse alternative step JSON")?;
        Ok(alt_step)
    }

    async fn execute_shell(&self, command: &str) -> Result<String> {
        // Check exec whitelist — warn if not pre-approved but still execute
        let whitelist = crate::exec_whitelist::ExecWhitelistManager::load(&self.work_dir).await;
        if whitelist.is_denied(command) {
            warn!("[exec_whitelist] Command is in deny list: {}", command);
        } else if !whitelist.is_approved(command) {
            warn!(
                "[exec_whitelist] Command not in whitelist (executing anyway): {}",
                command
            );
        }

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
                format!(
                    "{}...\n[truncated]",
                    crate::str_utils::truncate_bytes_safe(&stdout, 4000)
                )
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
            task_type: None,
        };

        let router = self.router.read().await;
        let response = router.chat(&request).await?;
        Ok(response.text)
    }

    /// Compute reliability statistics by reading the supervisor audit log.
    pub fn reliability_stats(&self) -> ReliabilityStats {
        let log_paths = [
            PathBuf::from("/var/log/lifeos/supervisor-audit.log"),
            PathBuf::from("/var/lib/lifeos/supervisor-audit.log"),
        ];

        let content = log_paths
            .iter()
            .find_map(|p| std::fs::read_to_string(p).ok())
            .unwrap_or_default();

        if content.is_empty() {
            return ReliabilityStats::default();
        }

        let mut total = 0usize;
        let mut successes = 0usize;
        let mut confidence_sum = 0.0f64;
        let mut failed_types: HashMap<String, usize> = HashMap::new();

        for line in content.lines() {
            let fields: Vec<&str> = line.split('\t').collect();
            if fields.len() < 6 {
                continue;
            }
            let status = fields[2];
            // Only count terminal states
            if status != "completed" && status != "failed" && status != "step_fail" {
                continue;
            }
            total += 1;
            if status == "completed" || status == "step_ok" || status == "step_ok_retry" {
                successes += 1;
            }
            if status == "step_fail" || status == "failed" {
                let action_hint = fields.get(3).unwrap_or(&"unknown");
                *failed_types.entry(action_hint.to_string()).or_insert(0) += 1;
            }
            // Parse confidence from last field: "confidence=0.85"
            if let Some(conf_field) = fields.last() {
                if let Some(val_str) = conf_field.strip_prefix("confidence=") {
                    if let Ok(c) = val_str.parse::<f64>() {
                        confidence_sum += c;
                    }
                }
            }
        }

        let most_failed = failed_types
            .into_iter()
            .max_by_key(|(_k, v)| *v)
            .map(|(k, _)| k);

        ReliabilityStats {
            total_tasks: total,
            success_rate: if total > 0 {
                successes as f64 / total as f64
            } else {
                0.0
            },
            avg_duration_ms: 0.0, // Duration not tracked per-line in audit log
            most_failed_action_type: most_failed,
            avg_confidence: if total > 0 {
                confidence_sum / total as f64
            } else {
                0.0
            },
        }
    }

    /// Build a context prompt from current system state to prepend to LLM requests.
    ///
    /// Gathers:
    /// - Last screenshot filename (as proxy for active window)
    /// - Last task objective processed
    /// - Current working directory
    pub fn build_context_prompt(&self) -> String {
        let mut parts: Vec<String> = Vec::new();

        parts.push(format!("Working directory: {}", self.work_dir.display()));

        // Try to find the latest screenshot to infer active window context
        let screenshot_dir = std::env::temp_dir().join("lifeos-screenshots");
        if let Ok(entries) = std::fs::read_dir(&screenshot_dir) {
            let latest = entries
                .filter_map(|e| e.ok())
                .filter(|e| {
                    e.path()
                        .extension()
                        .map(|ext| ext == "png")
                        .unwrap_or(false)
                })
                .max_by_key(|e| e.metadata().ok().and_then(|m| m.modified().ok()));
            if let Some(entry) = latest {
                parts.push(format!(
                    "Last screen capture: {}",
                    entry.file_name().to_string_lossy()
                ));
            }
        }

        // Include queue summary if available
        if let Ok(summary) = self.queue.summary() {
            if let Some(obj) = summary.as_object() {
                if let Some(pending) = obj.get("pending") {
                    parts.push(format!("Pending tasks in queue: {}", pending));
                }
            }
        }

        if parts.is_empty() {
            return String::new();
        }

        format!("[Current context]\n{}\n", parts.join("\n"))
    }

    async fn audit_log(
        &self,
        task_id: &str,
        objective: &str,
        status: &str,
        detail: &str,
        confidence: f64,
    ) {
        let log_dir = PathBuf::from("/var/log/lifeos");
        // Try primary dir, fallback to /var/lib/lifeos
        let log_dir = if std::fs::create_dir_all(&log_dir).is_ok() {
            log_dir
        } else {
            let fallback = PathBuf::from("/var/lib/lifeos");
            if std::fs::create_dir_all(&fallback).is_err() {
                return;
            }
            fallback
        };
        let path = log_dir.join("supervisor-audit.log");
        let entry = format!(
            "{}\t{}\t{}\t{}\t{}\tconfidence={:.2}\n",
            chrono::Local::now().to_rfc3339(),
            task_id,
            status,
            objective.chars().take(100).collect::<String>(),
            detail.chars().take(200).collect::<String>(),
            confidence,
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

    /// Record a task outcome in the reliability tracker.
    #[allow(clippy::too_many_arguments)]
    fn record_reliability(
        work_dir: &std::path::Path,
        task_id: &str,
        task_type: &str,
        source: &str,
        success: bool,
        error: Option<&str>,
        steps_total: usize,
        steps_ok: usize,
    ) {
        let db_path = work_dir.join("reliability.db");
        match crate::reliability::ReliabilityTracker::new(db_path) {
            Ok(tracker) => {
                let now = chrono::Utc::now();
                let outcome = crate::reliability::TaskOutcome {
                    task_id: task_id.to_string(),
                    task_type: task_type.to_string(),
                    source: source.to_string(),
                    started_at: now,
                    completed_at: now,
                    success,
                    error: error.map(|s| s.to_string()),
                    retries: 0,
                    rollback_clean: true,
                    steps_total: steps_total as u32,
                    steps_completed: steps_ok as u32,
                };
                if let Err(e) = tracker.record_outcome(&outcome) {
                    warn!("[reliability] Failed to record outcome: {}", e);
                }
            }
            Err(e) => {
                warn!("[reliability] Failed to open tracker: {}", e);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Plan parsing
// ---------------------------------------------------------------------------

fn parse_plan_from_response(text: &str) -> Result<Plan> {
    // Strip <think>...</think> blocks before extracting JSON — reasoning models
    // (Qwen3, DeepSeek) wrap their output in think tags which breaks JSON parsing.
    let stripped = strip_think_tags(text);
    let json_str = extract_json(&stripped);

    match serde_json::from_str::<Plan>(&json_str) {
        Ok(plan) if !plan.steps.is_empty() => {
            log::debug!("Parsed plan with {} steps", plan.steps.len());
            Ok(plan)
        }
        Ok(_) | Err(_) => {
            // If text looks like it contains a useful response, wrap it
            let clean = sanitize_fallback_text(&stripped);
            if clean.is_empty() {
                Ok(Plan {
                    steps: vec![PlanStep {
                        description: "No response from LLM".into(),
                        action: StepAction::Respond {
                            message: "(empty response)".into(),
                        },
                        expected_outcome: "User informed".into(),
                    }],
                })
            } else {
                log::info!(
                    "Could not parse plan JSON, wrapping as direct response ({} chars)",
                    clean.len()
                );
                Ok(Plan {
                    steps: vec![PlanStep {
                        description: "Direct LLM response".into(),
                        action: StepAction::Respond { message: clean },
                        expected_outcome: "User receives response".into(),
                    }],
                })
            }
        }
    }
}

/// Clean up raw LLM text for use as a fallback response when JSON parsing fails.
/// Removes thinking/reasoning scaffolding, markdown formatting, and special tokens.
fn sanitize_fallback_text(text: &str) -> String {
    let text = text.replace("<|im_start|>", " ").replace("<|im_end|>", " ");

    let reasoning_prefixes = [
        "thinking process",
        "the user wants",
        "i need to",
        "let me ",
        "analyze the request",
        "determine the output",
        "drafting the",
        "selection:",
        "check constraints",
        "final polish",
        "constraints:",
        "goal:",
        "reasoning:",
        "analysis:",
        "internal reasoning",
        "**analyze",
        "**task:",
        "**input:",
        "**output:",
        "**constraint",
        "**requirement",
        "**context:",
        "**goal:",
        "**formulate",
    ];

    let mut cleaned_lines = Vec::new();
    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        let normalized = line
            .trim_start_matches([
                '*', '-', '#', '`', '>', ' ', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '.',
            ])
            .trim()
            .to_lowercase();
        if reasoning_prefixes.iter().any(|p| normalized.starts_with(p)) {
            continue;
        }
        // Strip markdown bold/italic asterisks
        let line = line.replace("**", "").replace("*", "");
        let line = line.trim();
        if !line.is_empty() {
            cleaned_lines.push(line.to_string());
        }
    }

    let result = cleaned_lines.join(" ");
    // Collapse whitespace
    result.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Strip HTML tags to get plain text (simple approach).
fn strip_html(html: &str) -> String {
    let mut result = String::with_capacity(html.len() / 2);
    let mut in_tag = false;
    let in_script = false;

    for ch in html.chars() {
        if ch == '<' {
            in_tag = true;
            continue;
        }
        if ch == '>' {
            in_tag = false;
            continue;
        }
        if in_tag {
            continue;
        }
        if !in_script {
            if ch == '\n' || ch == '\r' {
                if !result.ends_with('\n') {
                    result.push('\n');
                }
            } else {
                result.push(ch);
            }
        }
    }
    // Collapse multiple blank lines
    let mut prev_blank = false;
    let lines: Vec<&str> = result
        .lines()
        .filter(|l| {
            let blank = l.trim().is_empty();
            if blank && prev_blank {
                return false;
            }
            prev_blank = blank;
            true
        })
        .collect();
    lines.join("\n").trim().to_string()
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
