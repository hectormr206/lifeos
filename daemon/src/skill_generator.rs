//! Skill Generator & Registry — Axi learns from interactions and creates reusable skills.
//!
//! When Axi successfully completes a task, it can analyze the execution pattern
//! and generate a reusable skill (script + metadata) that can be invoked later
//! without re-planning. Skills are stored in ~/.local/share/lifeos/skills/.
//!
//! Skill format:
//! - manifest.json: name, description, trigger patterns, risk level
//! - run.sh: executable entrypoint
//! - README.md: human-readable documentation
//!
//! ## SkillRegistry (hot-reload)
//!
//! `SkillRegistry` is a thread-safe in-memory cache of all loaded skills.
//! It scans multiple directories for `.json` / `.toml` skill files and
//! `manifest.json` inside sub-directories.  A background watcher task
//! (`SkillRegistry::watch_loop`) polls the directories for changes and
//! reloads automatically.  An explicit reload can also be triggered via
//! `POST /api/v1/skills/reload`.

use anyhow::Result;
use log::{debug, info, warn};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::fs;
use tokio::sync::RwLock;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillManifest {
    pub name: String,
    pub description: String,
    pub version: String,
    pub trigger_patterns: Vec<String>,
    pub risk_level: String,
    pub created_at: String,
    pub last_used: Option<String>,
    pub use_count: u32,
    pub success_rate: f64,
    /// True for auto-generated skills until a human approves them. Existing
    /// manifests on disk that pre-date this field default to `false` (treated
    /// as approved) so prior installs do not regress to "needs review".
    /// Auto-generated manifests written via `generate_from_task` ALWAYS set
    /// this to true regardless of what the task tuple contains.
    #[serde(default)]
    pub requires_review: bool,
    /// RFC3339 timestamp when a human approved an auto-generated skill.
    /// Approval is granted by either setting this field via the dashboard or
    /// touching a sibling `approved` file in the skill directory.
    #[serde(default)]
    pub approved_at: Option<String>,
}

/// Check if auto-execution of generated skills is opt-in enabled.
///
/// Defaults to OFF. Set `LIFEOS_SKILLS_AUTOEXEC_ENABLE=1` (or true/yes/on)
/// to let the skill registry run bash scripts that LifeOS generated from
/// task execution traces without a human approving the content first.
fn skills_autoexec_enabled() -> bool {
    std::env::var("LIFEOS_SKILLS_AUTOEXEC_ENABLE")
        .map(|v| matches!(v.as_str(), "1" | "true" | "yes" | "on"))
        .unwrap_or(false)
}

/// Whether unsandboxed skill execution is allowed when `systemd-run` is
/// unavailable. Defaults to TRUE — the safe choice. The operator MUST
/// explicitly set `LIFEOS_SKILLS_REQUIRE_SANDBOX=0` (or false/no/off) to
/// opt OUT of sandboxing, accepting that skills will run unconfined as
/// the daemon UID. SA3: previous behaviour was a silent fallback to
/// unsandboxed exec, hiding the missing-sandbox condition from operators.
fn skills_require_sandbox() -> bool {
    !matches!(
        std::env::var("LIFEOS_SKILLS_REQUIRE_SANDBOX").as_deref(),
        Ok("0") | Ok("false") | Ok("no") | Ok("off")
    )
}

/// Hard cap for any skill source file (`SKILL.md`, `manifest.json`, `run.sh`)
/// read into memory. 4 MiB is plenty for legitimate skill content and stops
/// a hostile or accidentally-huge file from triggering an OOM in the daemon.
const MAX_SKILL_FILE_BYTES: u64 = 4 * 1024 * 1024;

/// Read a file, refusing if it exceeds [`MAX_SKILL_FILE_BYTES`]. Returns the
/// content or an io::Error so callers can keep their existing `?` chains.
async fn read_skill_file_capped(path: &std::path::Path) -> std::io::Result<String> {
    let meta = fs::metadata(path).await?;
    if meta.len() > MAX_SKILL_FILE_BYTES {
        log::warn!(
            "[skill_gen] refusing to read {} ({} bytes > {} cap)",
            path.display(),
            meta.len(),
            MAX_SKILL_FILE_BYTES
        );
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("skill file exceeds {MAX_SKILL_FILE_BYTES}-byte cap"),
        ));
    }
    fs::read_to_string(path).await
}

/// Directory holding daemon-managed approval markers for auto-generated
/// skills. Lives under the secrets dir so only the daemon (mode 0700)
/// can write here in normal flow — an attacker who plants a `manifest.json`
/// in a watched skills directory CANNOT also create the matching marker
/// file unless they already have daemon-UID write access (in which case
/// they have already won regardless of this gate).
const APPROVED_SKILLS_DIR: &str = "/var/lib/lifeos/secrets/approved-skills";

/// A skill is APPROVED if either:
///   1. its `manifest.requires_review` is false (legacy / SKILL.md plugin), OR
///   2. its `manifest.approved_at` parses as a valid RFC3339 timestamp
///      (SB6 — empty / arbitrary strings no longer count), OR
///   3. an explicit marker file exists at
///      `/var/lib/lifeos/secrets/approved-skills/<skill_name>`. The
///      previous in-tree `<skill_dir>/approved` marker (SB5) is REMOVED
///      because anyone who could plant `manifest.json` in a watched dir
///      could also plant the marker, defeating the gate. The operator now
///      grants approval with `sudo touch /var/lib/lifeos/secrets/approved-skills/<name>`.
///
/// Approval does NOT bypass the autoexec gate — both must pass.
fn skill_is_approved(skill_dir: &std::path::Path, manifest: &SkillManifest) -> bool {
    if !manifest.requires_review {
        return true;
    }
    // SB6: only accept RFC3339-parseable timestamps. An attacker that
    // tampered with manifest.json could write `approved_at: "yes"` and
    // bypass the previous "non-empty string" check.
    if let Some(raw) = manifest.approved_at.as_deref() {
        if chrono::DateTime::parse_from_rfc3339(raw.trim()).is_ok() {
            return true;
        }
    }
    // SB5: marker file MUST live in the daemon-protected secrets dir,
    // not in the (potentially attacker-writable) skill_dir.
    let _ = skill_dir; // kept in signature for callers; intentionally unused now
    let marker = std::path::Path::new(APPROVED_SKILLS_DIR).join(&manifest.name);
    marker.exists()
}

/// Best-effort sandbox wrapper using `systemd-run --user --scope`. Returns
/// the wrapper command and arguments to prepend to the actual exec, OR
/// `None` if `systemd-run` is not available (e.g. test environments,
/// containers without systemd-user). When `None`, the caller logs a
/// `warn!` and runs unconfined — the operator already opted in by setting
/// `LIFEOS_SKILLS_AUTOEXEC_ENABLE=1`, but no sandbox available is a real
/// risk that we surface in the log.
///
/// Sandbox properties (intentional defaults):
///   - PrivateNetwork=yes       no outbound network from the skill
///   - ProtectHome=read-only    can read $HOME but not write to it
///   - NoNewPrivileges=yes      cannot escalate via setuid binaries
///   - ProtectSystem=strict     cannot write under /usr, /boot, /efi
///   - PrivateTmp=yes           private /tmp namespace
///   - MemoryMax=256M           OOM-kill before consuming the daemon's RAM
///   - TasksMax=64              cap fork-bomb damage
///   - RuntimeMaxSec=60         hard wall-clock kill in addition to caller's
fn sandbox_wrapper() -> Option<Vec<String>> {
    if !std::path::Path::new("/usr/bin/systemd-run").exists()
        && !std::path::Path::new("/bin/systemd-run").exists()
    {
        return None;
    }
    Some(vec![
        "systemd-run".to_string(),
        "--user".to_string(),
        "--scope".to_string(),
        "--quiet".to_string(),
        "--collect".to_string(),
        "--property=PrivateNetwork=yes".to_string(),
        "--property=ProtectHome=read-only".to_string(),
        "--property=NoNewPrivileges=yes".to_string(),
        "--property=ProtectSystem=strict".to_string(),
        "--property=PrivateTmp=yes".to_string(),
        "--property=MemoryMax=256M".to_string(),
        "--property=TasksMax=64".to_string(),
        "--property=RuntimeMaxSec=60".to_string(),
    ])
}

/// Atomically replace a file by writing to a tempfile in the same directory
/// and renaming. Avoids torn writes from concurrent updates of small JSON
/// state (see `SkillGenerator::update_skill_stats`).
async fn write_atomic(path: &std::path::Path, contents: &str) -> std::io::Result<()> {
    let dir = path.parent().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "atomic write: path has no parent",
        )
    })?;
    let pid = std::process::id();
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let tmp = dir.join(format!(
        ".{}.tmp-{pid}-{nonce}",
        path.file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("manifest")
    ));
    fs::write(&tmp, contents).await?;
    fs::rename(&tmp, path).await
}

pub struct SkillGenerator {
    skills_dir: PathBuf,
}

impl SkillGenerator {
    pub fn new(data_dir: &std::path::Path) -> Self {
        Self {
            skills_dir: data_dir.join("skills"),
        }
    }

    /// Generate a skill from a successful task execution.
    pub async fn generate_from_task(
        &self,
        task_objective: &str,
        steps: &[(String, String)], // (action_description, command/content)
        success: bool,
    ) -> Result<Option<SkillManifest>> {
        if !success || steps.is_empty() {
            return Ok(None);
        }

        // Only generate skills for multi-step tasks that succeeded
        if steps.len() < 2 {
            return Ok(None);
        }

        let skill_name = slugify(task_objective);
        let skill_dir = self.skills_dir.join(&skill_name);
        fs::create_dir_all(&skill_dir).await?;

        // Generate the shell script from executed steps
        let mut script = String::from("#!/bin/bash\n");
        script.push_str(&format!("# Auto-generated skill: {}\n", task_objective));
        script.push_str(&format!(
            "# Generated: {}\n",
            chrono::Utc::now().to_rfc3339()
        ));
        script.push_str("set -euo pipefail\n\n");

        for (desc, cmd) in steps {
            script.push_str(&format!("# {}\n", desc));
            script.push_str(&format!("{}\n\n", cmd));
        }

        // Write the script
        let script_path = skill_dir.join("run.sh");
        fs::write(&script_path, &script).await?;

        // Make executable
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::Permissions::from_mode(0o755);
            std::fs::set_permissions(&script_path, perms)?;
        }

        // Create trigger patterns from the objective
        let trigger_patterns = extract_trigger_patterns(task_objective);

        let manifest = SkillManifest {
            name: skill_name.clone(),
            description: task_objective.to_string(),
            version: "1.0.0".into(),
            trigger_patterns,
            risk_level: "low".into(),
            created_at: chrono::Utc::now().to_rfc3339(),
            last_used: None,
            use_count: 0,
            success_rate: 1.0,
            // Auto-generated content always needs human approval before
            // execution. The user approves by either editing
            // `manifest.json` to set `approved_at` or `touch <skill_dir>/approved`.
            requires_review: true,
            approved_at: None,
        };

        // Write manifest
        let manifest_json = serde_json::to_string_pretty(&manifest)?;
        fs::write(skill_dir.join("manifest.json"), &manifest_json).await?;

        info!(
            "[skill_gen] Generated skill '{}' from task: {}",
            skill_name, task_objective
        );

        Ok(Some(manifest))
    }

    /// List all available skills.
    pub async fn list_skills(&self) -> Result<Vec<SkillManifest>> {
        let mut skills = Vec::new();

        if !self.skills_dir.exists() {
            return Ok(skills);
        }

        let mut entries = fs::read_dir(&self.skills_dir).await?;
        while let Ok(Some(entry)) = entries.next_entry().await {
            let manifest_path = entry.path().join("manifest.json");
            if manifest_path.exists() {
                if let Ok(content) = fs::read_to_string(&manifest_path).await {
                    if let Ok(manifest) = serde_json::from_str::<SkillManifest>(&content) {
                        skills.push(manifest);
                    }
                }
            }
        }

        Ok(skills)
    }

    /// Find a matching skill for an objective.
    pub async fn find_skill(&self, objective: &str) -> Result<Option<(SkillManifest, PathBuf)>> {
        let lower = objective.to_lowercase();
        let skills = self.list_skills().await?;

        for skill in skills {
            for pattern in &skill.trigger_patterns {
                if lower.contains(&pattern.to_lowercase()) {
                    let skill_dir = self.skills_dir.join(slugify(&skill.name));
                    return Ok(Some((skill, skill_dir)));
                }
            }
        }

        Ok(None)
    }

    /// Execute a skill by running its run.sh.
    ///
    /// SECURITY HARDENING (item #S3 in pending-items-roadmap.md):
    /// - Auto-execution is gated behind LIFEOS_SKILLS_AUTOEXEC_ENABLE so
    ///   a user must explicitly opt in before auto-generated skills run.
    /// - A 60-second wall clock timeout prevents runaway scripts.
    /// - Every execution is logged with the skill path + exit code so
    ///   a post-incident audit can reconstruct what ran when.
    ///
    /// A proper fix — approval UI, sandboxing via bubblewrap or systemd
    /// transient units with DynamicUser+ProtectSystem+ReadOnlyPaths, and
    /// content validation on the generated script before first execution
    /// — is the follow-up sprint for S3.
    pub async fn execute_skill(&self, skill_dir: &std::path::Path) -> Result<String> {
        let script = skill_dir.join("run.sh");
        if !script.exists() {
            anyhow::bail!("Skill script not found: {}", script.display());
        }

        if !skills_autoexec_enabled() {
            log::warn!(
                "[skill_gen] execute_skill blocked — auto-exec disabled (set \
                 LIFEOS_SKILLS_AUTOEXEC_ENABLE=1 to opt in): {}",
                script.display()
            );
            anyhow::bail!(
                "Skill auto-execution is disabled. Set \
                 LIFEOS_SKILLS_AUTOEXEC_ENABLE=1 to opt in. This guard \
                 exists because skills are generated from task execution \
                 traces without a human review step, and executing them \
                 blindly runs arbitrary bash as the daemon's user."
            );
        }

        // Approval gate: auto-generated skills must be approved by a human
        // before they execute, even with autoexec on. See `skill_is_approved`.
        let manifest_path = skill_dir.join("manifest.json");
        if let Ok(json) = read_skill_file_capped(&manifest_path).await {
            if let Ok(manifest) = serde_json::from_str::<SkillManifest>(&json) {
                if !skill_is_approved(skill_dir, &manifest) {
                    log::warn!(
                        "[skill_gen] execute_skill blocked — manifest requires_review and not approved: {}",
                        skill_dir.display()
                    );
                    anyhow::bail!(
                        "Skill {} requires human approval. Either set \
                         `approved_at` in manifest.json (RFC3339 timestamp) \
                         or `touch {}/approved` after reviewing run.sh.",
                        manifest.name,
                        skill_dir.display()
                    );
                }
            }
        }

        // Wrap in systemd-run --user --scope sandbox when available.
        // Falls back to unconfined exec if systemd-run is missing — the
        // operator already opted in to autoexec, but we surface the missing
        // sandbox loudly so it cannot be silently ignored.
        let (cmd, args, sandboxed): (String, Vec<String>, bool) = match sandbox_wrapper() {
            Some(mut wrapper) => {
                let bin = wrapper.remove(0);
                wrapper.push("bash".to_string());
                wrapper.push(script.display().to_string());
                (bin, wrapper, true)
            }
            None => {
                if skills_require_sandbox() {
                    log::warn!(
                        "[skill_gen] systemd-run not available and \
                         LIFEOS_SKILLS_REQUIRE_SANDBOX is on (default) — REFUSING to \
                         exec unsandboxed: {}",
                        script.display()
                    );
                    anyhow::bail!(
                        "Refusing to execute skill unsandboxed: systemd-run not \
                         available. Install systemd-user OR explicitly opt out by \
                         setting LIFEOS_SKILLS_REQUIRE_SANDBOX=0 (accepts unconfined \
                         exec as the daemon UID)."
                    );
                }
                log::warn!(
                    "[skill_gen] systemd-run not available, executing UNSANDBOXED \
                     (LIFEOS_SKILLS_REQUIRE_SANDBOX=0 opt-out): {}",
                    script.display()
                );
                (
                    "bash".to_string(),
                    vec![script.display().to_string()],
                    false,
                )
            }
        };

        log::warn!(
            "[skill_gen] EXECUTING skill (auto-exec opt-in, sandbox={}): {}",
            sandboxed,
            script.display()
        );

        let exec = tokio::process::Command::new(&cmd).args(&args).output();
        let output = match tokio::time::timeout(std::time::Duration::from_secs(60), exec).await {
            Ok(Ok(o)) => o,
            Ok(Err(e)) => return Err(anyhow::Error::from(e).context("Failed to execute skill")),
            Err(_) => {
                log::warn!(
                    "[skill_gen] skill timed out after 60s: {}",
                    script.display()
                );
                anyhow::bail!("Skill timed out after 60 seconds");
            }
        };

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);

        log::info!(
            "[skill_gen] skill finished: {} exit={:?}",
            script.display(),
            output.status.code()
        );

        if output.status.success() {
            // Update use count and success rate
            self.update_skill_stats(&skill_dir.join("manifest.json"), true)
                .await;
            Ok(stdout.to_string())
        } else {
            self.update_skill_stats(&skill_dir.join("manifest.json"), false)
                .await;
            anyhow::bail!("Skill failed: {}{}", stdout, stderr)
        }
    }

    /// Update skill usage statistics after execution.
    ///
    /// Read-modify-write of a small JSON file. Two concurrent skill
    /// executions racing on this could produce a torn write under the
    /// previous direct `fs::write`; we now stage to a tempfile in the same
    /// directory and `rename(2)` into place. rename is atomic per POSIX
    /// when source and destination are on the same filesystem, which is
    /// guaranteed here because the tempfile lives next to the manifest.
    async fn update_skill_stats(&self, manifest_path: &std::path::Path, success: bool) {
        let Ok(content) = read_skill_file_capped(manifest_path).await else {
            return;
        };
        let mut manifest: SkillManifest = match serde_json::from_str(&content) {
            Ok(m) => m,
            Err(e) => {
                log::warn!(
                    "[skill_gen] update_skill_stats: failed to parse {}: {}",
                    manifest_path.display(),
                    e
                );
                return;
            }
        };
        manifest.use_count += 1;
        manifest.last_used = Some(chrono::Utc::now().to_rfc3339());
        // Running average of success rate
        let total = manifest.use_count as f64;
        let prev_successes = manifest.success_rate * (total - 1.0);
        manifest.success_rate = (prev_successes + if success { 1.0 } else { 0.0 }) / total;

        if let Ok(json) = serde_json::to_string_pretty(&manifest) {
            if let Err(e) = write_atomic(manifest_path, &json).await {
                log::warn!(
                    "[skill_gen] update_skill_stats: atomic write failed for {}: {}",
                    manifest_path.display(),
                    e
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------
// SkillRegistry — in-memory cache with hot-reload
// ---------------------------------------------------------------------------

/// Thread-safe skill registry that caches loaded skills and supports hot-reload.
///
/// Multiple directories are scanned:
/// 1. The supervisor's generated skills (data_dir/skills/)
/// 2. User-installed SKILL.md plugins (~/.config/lifeos/skills/)
/// 3. System MCP skills (/var/lib/lifeos/skills/)
///
/// Skills can be defined as:
/// - A directory containing `manifest.json` (SkillGenerator format)
/// - A standalone `.json` file with SkillManifest fields
/// - A standalone `.toml` file with SkillManifest fields
#[derive(Clone)]
pub struct SkillRegistry {
    inner: Arc<RwLock<SkillRegistryInner>>,
    dirs: Arc<Vec<PathBuf>>,
}

struct SkillRegistryInner {
    /// skill name -> (manifest, directory containing the skill)
    skills: HashMap<String, (SkillManifest, PathBuf)>,
    /// Last scan timestamp (used by the watcher to detect changes)
    last_scan: std::time::Instant,
    /// Number of reloads performed
    reload_count: u64,
}

/// Summary returned after a reload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReloadSummary {
    pub total_loaded: usize,
    pub new_skills: Vec<String>,
    pub removed_skills: Vec<String>,
    pub reload_count: u64,
}

impl SkillRegistry {
    /// Create a new registry that watches the given directories.
    pub fn new(dirs: Vec<PathBuf>) -> Self {
        Self {
            inner: Arc::new(RwLock::new(SkillRegistryInner {
                skills: HashMap::new(),
                last_scan: std::time::Instant::now(),
                reload_count: 0,
            })),
            dirs: Arc::new(dirs),
        }
    }

    /// Build a registry from the standard LifeOS paths.
    pub fn from_defaults() -> Self {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
        let dirs = vec![
            // Supervisor-generated skills
            PathBuf::from(&home).join(".local/share/lifeos/skills"),
            // User-installed SKILL.md plugins
            PathBuf::from(&home).join(".config/lifeos/skills"),
            // System MCP skills
            PathBuf::from("/var/lib/lifeos/skills"),
        ];
        Self::new(dirs)
    }

    /// Perform a full scan of all directories and reload the cache.
    /// Returns a summary of what changed.
    pub async fn reload(&self) -> Result<ReloadSummary> {
        let mut new_skills: HashMap<String, (SkillManifest, PathBuf)> = HashMap::new();

        for dir in self.dirs.iter() {
            if !dir.exists() {
                continue;
            }
            self.scan_directory(dir, &mut new_skills).await;
        }

        let mut inner = self.inner.write().await;
        let old_names: std::collections::HashSet<String> = inner.skills.keys().cloned().collect();
        let new_names: std::collections::HashSet<String> = new_skills.keys().cloned().collect();

        let added: Vec<String> = new_names.difference(&old_names).cloned().collect();
        let removed: Vec<String> = old_names.difference(&new_names).cloned().collect();

        if !added.is_empty() {
            info!("[skill_registry] New skills loaded: {:?}", added);
        }
        if !removed.is_empty() {
            info!("[skill_registry] Skills removed: {:?}", removed);
        }

        inner.skills = new_skills;
        inner.last_scan = std::time::Instant::now();
        inner.reload_count += 1;

        let summary = ReloadSummary {
            total_loaded: inner.skills.len(),
            new_skills: added,
            removed_skills: removed,
            reload_count: inner.reload_count,
        };

        info!(
            "[skill_registry] Reload #{}: {} skills loaded",
            summary.reload_count, summary.total_loaded
        );

        Ok(summary)
    }

    /// Scan a single directory for skills.
    async fn scan_directory(
        &self,
        dir: &std::path::Path,
        out: &mut HashMap<String, (SkillManifest, PathBuf)>,
    ) {
        let mut entries = match fs::read_dir(dir).await {
            Ok(e) => e,
            Err(e) => {
                debug!("[skill_registry] Cannot read {}: {}", dir.display(), e);
                return;
            }
        };

        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();

            if path.is_dir() {
                // Look for manifest.json inside subdirectory
                let manifest_path = path.join("manifest.json");
                if manifest_path.exists() {
                    if let Some(manifest) = Self::load_manifest_json(&manifest_path).await {
                        out.insert(manifest.name.clone(), (manifest, path));
                        continue;
                    }
                }
                // Also accept SKILL.md-style directories (axi_tools compat)
                let skill_md = path.join("SKILL.md");
                if skill_md.exists() {
                    if let Some(manifest) = Self::load_skill_md(&skill_md, &path).await {
                        out.insert(manifest.name.clone(), (manifest, path));
                    }
                }
            } else if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
                match ext {
                    "json" => {
                        if let Some(manifest) = Self::load_standalone_json(&path).await {
                            let parent = path.parent().unwrap_or(dir).to_path_buf();
                            out.insert(manifest.name.clone(), (manifest, parent));
                        }
                    }
                    "toml" => {
                        if let Some(manifest) = Self::load_standalone_toml(&path).await {
                            let parent = path.parent().unwrap_or(dir).to_path_buf();
                            out.insert(manifest.name.clone(), (manifest, parent));
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    async fn load_manifest_json(path: &std::path::Path) -> Option<SkillManifest> {
        let content = read_skill_file_capped(path).await.ok()?;
        match serde_json::from_str::<SkillManifest>(&content) {
            Ok(m) => Some(m),
            Err(e) => {
                warn!(
                    "[skill_registry] manifest.json at {} failed to parse: {e}",
                    path.display()
                );
                None
            }
        }
    }

    async fn load_standalone_json(path: &std::path::Path) -> Option<SkillManifest> {
        let content = read_skill_file_capped(path).await.ok()?;
        match serde_json::from_str::<SkillManifest>(&content) {
            Ok(mut m) => {
                // SB8: standalone files (not under generate_from_task's
                // managed output) are NEVER trusted to set requires_review=false.
                // An attacker who plants a JSON/TOML in a watched dir would
                // otherwise bypass the approval gate. Approval must come from
                // an explicit marker in the daemon-protected secrets dir.
                m.requires_review = true;
                Some(m)
            }
            Err(e) => {
                warn!(
                    "[skill_registry] {} failed to parse as JSON skill: {e}",
                    path.display()
                );
                None
            }
        }
    }

    async fn load_standalone_toml(path: &std::path::Path) -> Option<SkillManifest> {
        let content = read_skill_file_capped(path).await.ok()?;
        match toml::from_str::<SkillManifest>(&content) {
            Ok(mut m) => {
                // SB8: see load_standalone_json above.
                m.requires_review = true;
                Some(m)
            }
            Err(e) => {
                warn!(
                    "[skill_registry] {} failed to parse as TOML skill: {e}",
                    path.display()
                );
                None
            }
        }
    }

    /// Load a SKILL.md file (axi_tools format) and convert to SkillManifest.
    async fn load_skill_md(
        skill_md: &std::path::Path,
        skill_dir: &std::path::Path,
    ) -> Option<SkillManifest> {
        let content = read_skill_file_capped(skill_md).await.ok()?;
        let name = skill_dir
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("unknown")
            .to_string();

        // Extract description: first non-heading, non-empty line
        let description = content
            .lines()
            .find(|l| !l.starts_with('#') && !l.trim().is_empty())
            .unwrap_or("No description")
            .trim()
            .to_string();

        Some(SkillManifest {
            name,
            description,
            version: "1.0.0".into(),
            trigger_patterns: Vec::new(),
            risk_level: "low".into(),
            created_at: String::new(),
            last_used: None,
            use_count: 0,
            success_rate: 0.0,
            // SKILL.md-style skills are user-installed plugins, not
            // auto-generated. Default approved.
            requires_review: false,
            approved_at: None,
        })
    }

    /// List all currently loaded skills.
    pub async fn list(&self) -> Vec<SkillManifest> {
        let inner = self.inner.read().await;
        inner.skills.values().map(|(m, _)| m.clone()).collect()
    }

    /// Find a skill by exact name.
    pub async fn get(&self, name: &str) -> Option<(SkillManifest, PathBuf)> {
        let inner = self.inner.read().await;
        inner.skills.get(name).cloned()
    }

    /// Run a skill by name with optional input.
    pub async fn run(&self, name: &str, _input: &str) -> Result<String> {
        let (manifest, skill_dir) = self
            .get(name)
            .await
            .ok_or_else(|| anyhow::anyhow!("Skill '{}' not found in registry", name))?;

        // Try run.sh first (SkillGenerator format)
        let script = skill_dir.join("run.sh");
        if script.exists() {
            let gen = SkillGenerator {
                skills_dir: skill_dir.parent().unwrap_or(&skill_dir).to_path_buf(),
            };
            return gen.execute_skill(&skill_dir).await;
        }

        // Try SKILL.md command: field
        //
        // SECURITY NOTE (S3): the previous code happily parsed a `command:`
        // line out of any SKILL.md file found in any of the configured
        // skills directories (including user-writable ~/.config/lifeos/skills)
        // and ran it through `sh -c`. That means any file that lands in a
        // watched directory can execute arbitrary shell next time the skill
        // is matched. We now gate this behind the same autoexec opt-in as
        // run.sh and add a 60s timeout.
        let skill_md = skill_dir.join("SKILL.md");
        if skill_md.exists() {
            if !skills_autoexec_enabled() {
                log::warn!(
                    "[skill_registry] SKILL.md command blocked — auto-exec disabled: {}",
                    skill_md.display()
                );
                anyhow::bail!(
                    "Skill auto-execution is disabled. Set \
                     LIFEOS_SKILLS_AUTOEXEC_ENABLE=1 to opt in."
                );
            }

            // Approval gate, same as run.sh path.
            if !skill_is_approved(&skill_dir, &manifest) {
                log::warn!(
                    "[skill_registry] SKILL.md command blocked — manifest requires_review and not approved: {}",
                    skill_md.display()
                );
                anyhow::bail!(
                    "Skill {} requires human approval. Either set \
                     `approved_at` in manifest.json (RFC3339 timestamp) \
                     or `touch {}/approved` after reviewing SKILL.md.",
                    manifest.name,
                    skill_dir.display()
                );
            }

            let content = read_skill_file_capped(&skill_md).await?;
            let command = content
                .lines()
                .find(|l| l.to_lowercase().starts_with("command:"))
                .and_then(|l| l.split_once(':').map(|x| x.1))
                .map(|s| s.trim().to_string())
                .ok_or_else(|| anyhow::anyhow!("SKILL.md has no command: line"))?;

            // Build sandboxed exec for the sh -c invocation. The wrapper
            // applies the same defence-in-depth properties as the run.sh
            // path (PrivateNetwork, ProtectHome=read-only, MemoryMax, etc).
            let (cmd, args, sandboxed): (String, Vec<String>, bool) = match sandbox_wrapper() {
                Some(mut wrapper) => {
                    let bin = wrapper.remove(0);
                    wrapper.push("sh".to_string());
                    wrapper.push("-c".to_string());
                    wrapper.push(command.clone());
                    (bin, wrapper, true)
                }
                None => {
                    if skills_require_sandbox() {
                        log::warn!(
                            "[skill_registry] systemd-run not available and \
                             LIFEOS_SKILLS_REQUIRE_SANDBOX is on (default) — REFUSING \
                             to exec SKILL.md command unsandboxed: {}",
                            skill_md.display()
                        );
                        anyhow::bail!(
                            "Refusing to execute SKILL.md command unsandboxed: systemd-run \
                             not available. Install systemd-user OR explicitly opt out by \
                             setting LIFEOS_SKILLS_REQUIRE_SANDBOX=0."
                        );
                    }
                    log::warn!(
                        "[skill_registry] systemd-run not available, executing UNSANDBOXED \
                         SKILL.md cmd (LIFEOS_SKILLS_REQUIRE_SANDBOX=0 opt-out): {}",
                        skill_md.display()
                    );
                    (
                        "sh".to_string(),
                        vec!["-c".to_string(), command.clone()],
                        false,
                    )
                }
            };

            log::warn!(
                "[skill_registry] EXECUTING SKILL.md command (sandbox={}) from {}: {}",
                sandboxed,
                skill_md.display(),
                command.chars().take(200).collect::<String>()
            );

            let exec = tokio::process::Command::new(&cmd)
                .args(&args)
                .current_dir(&skill_dir)
                .output();
            let output = match tokio::time::timeout(std::time::Duration::from_secs(60), exec).await
            {
                Ok(Ok(o)) => o,
                Ok(Err(e)) => {
                    return Err(anyhow::Error::from(e).context("Failed to execute SKILL.md command"))
                }
                Err(_) => anyhow::bail!("SKILL.md command timed out after 60 seconds"),
            };

            let stdout = String::from_utf8_lossy(&output.stdout);
            if output.status.success() {
                return Ok(stdout.to_string());
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr);
                anyhow::bail!("Skill '{}' failed: {}{}", manifest.name, stdout, stderr);
            }
        }

        anyhow::bail!(
            "Skill '{}' has no executable entry point (run.sh or SKILL.md command:)",
            name
        )
    }

    /// Background watcher loop.  Polls the skill directories every `interval`
    /// and reloads when filesystem modification times change.
    pub async fn watch_loop(self, interval: std::time::Duration) {
        info!(
            "[skill_registry] File watcher started (poll interval: {:?})",
            interval
        );

        // Track the most-recent mtime we have seen across all directories.
        let mut last_mtime: Option<std::time::SystemTime> = None;

        loop {
            tokio::time::sleep(interval).await;

            // Compute the latest mtime across all watched directories.
            let current_mtime = self.latest_mtime().await;

            let changed = match (last_mtime, current_mtime) {
                (None, Some(_)) => true,
                (Some(prev), Some(cur)) => cur > prev,
                _ => false,
            };

            if changed {
                debug!("[skill_registry] Change detected, reloading...");
                match self.reload().await {
                    Ok(summary) => {
                        if !summary.new_skills.is_empty() || !summary.removed_skills.is_empty() {
                            info!(
                                "[skill_registry] Hot-reload: +{} new, -{} removed, {} total",
                                summary.new_skills.len(),
                                summary.removed_skills.len(),
                                summary.total_loaded
                            );
                        }
                    }
                    Err(e) => {
                        warn!("[skill_registry] Reload failed: {}", e);
                    }
                }
                last_mtime = current_mtime;
            }
        }
    }

    /// Find the most recent modification time across all skill directories.
    async fn latest_mtime(&self) -> Option<std::time::SystemTime> {
        let mut latest: Option<std::time::SystemTime> = None;

        for dir in self.dirs.iter() {
            if !dir.exists() {
                continue;
            }
            // Check the directory itself
            if let Ok(meta) = fs::metadata(dir).await {
                if let Ok(mtime) = meta.modified() {
                    latest =
                        Some(latest.map_or(mtime, |prev: std::time::SystemTime| prev.max(mtime)));
                }
            }
            // Check immediate children
            let mut entries = match fs::read_dir(dir).await {
                Ok(e) => e,
                Err(_) => continue,
            };
            while let Ok(Some(entry)) = entries.next_entry().await {
                if let Ok(meta) = entry.metadata().await {
                    if let Ok(mtime) = meta.modified() {
                        latest = Some(
                            latest.map_or(mtime, |prev: std::time::SystemTime| prev.max(mtime)),
                        );
                    }
                }
            }
        }

        latest
    }

    /// Get diagnostics for the registry.
    pub async fn diagnostics(&self) -> SkillRegistryDiagnostics {
        let inner = self.inner.read().await;
        let skills: Vec<&SkillManifest> = inner.skills.values().map(|(m, _)| m).collect();
        let total = skills.len();
        let avg_success = if total > 0 {
            skills.iter().map(|s| s.success_rate).sum::<f64>() / total as f64
        } else {
            0.0
        };
        SkillRegistryDiagnostics {
            total_skills: total,
            avg_success_rate: avg_success,
            reload_count: inner.reload_count,
            watched_dirs: self.dirs.iter().map(|d| d.display().to_string()).collect(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillRegistryDiagnostics {
    pub total_skills: usize,
    pub avg_success_rate: f64,
    pub reload_count: u64,
    pub watched_dirs: Vec<String>,
}

// ---------------------------------------------------------------------------

/// Record of an interaction step for learning/replay.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InteractionRecord {
    pub timestamp: String,
    pub action: String,
    pub screenshot_before: Option<String>,
    pub screenshot_after: Option<String>,
    pub result: String,
    pub success: bool,
}

/// Convert a task objective to a filesystem-safe slug.
fn slugify(text: &str) -> String {
    text.to_lowercase()
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '-' {
                c
            } else {
                '-'
            }
        })
        .collect::<String>()
        .split('-')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("-")
        .chars()
        .take(60)
        .collect()
}

/// Extract trigger patterns from a task objective.
fn extract_trigger_patterns(objective: &str) -> Vec<String> {
    let words: Vec<&str> = objective.split_whitespace().collect();
    let mut patterns = Vec::new();

    // Use significant 2-3 word combinations as triggers
    if words.len() >= 2 {
        patterns.push(words[..2.min(words.len())].join(" ").to_lowercase());
    }
    if words.len() >= 3 {
        patterns.push(words[..3.min(words.len())].join(" ").to_lowercase());
    }

    // Add the full objective as a pattern
    patterns.push(objective.to_lowercase());

    patterns
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "lifeos-skill-test-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or_default()
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn manifest_with_review(name: &str, requires_review: bool) -> SkillManifest {
        SkillManifest {
            name: name.to_string(),
            description: "test".into(),
            version: "1.0.0".into(),
            trigger_patterns: vec![],
            risk_level: "low".into(),
            created_at: "t".into(),
            last_used: None,
            use_count: 0,
            success_rate: 0.0,
            requires_review,
            approved_at: None,
        }
    }

    #[test]
    fn skill_is_approved_when_requires_review_false() {
        let dir = tmpdir("approved-default");
        let m = manifest_with_review("x", false);
        assert!(skill_is_approved(&dir, &m));
    }

    #[test]
    fn skill_blocked_when_requires_review_and_no_marker() {
        let dir = tmpdir("approved-blocked");
        let m = manifest_with_review("x", true);
        assert!(!skill_is_approved(&dir, &m));
    }

    #[test]
    fn skill_in_tree_marker_no_longer_grants_approval() {
        // SB5: the previous in-tree `<skill_dir>/approved` marker is
        // explicitly NOT honoured anymore — anyone who can plant
        // `manifest.json` in a watched dir could also plant the marker.
        let dir = tmpdir("approved-marker-rejected");
        std::fs::write(dir.join("approved"), "").unwrap();
        let m = manifest_with_review("x", true);
        assert!(
            !skill_is_approved(&dir, &m),
            "in-tree marker must not grant approval"
        );
    }

    #[test]
    fn skill_approved_via_manifest_rfc3339_field() {
        let dir = tmpdir("approved-manifest");
        let mut m = manifest_with_review("x", true);
        m.approved_at = Some("2026-04-22T11:00:00Z".to_string());
        assert!(skill_is_approved(&dir, &m));
    }

    #[test]
    fn skill_not_approved_via_empty_field() {
        let dir = tmpdir("approved-empty");
        let mut m = manifest_with_review("x", true);
        m.approved_at = Some("   ".to_string());
        assert!(!skill_is_approved(&dir, &m));
    }

    #[test]
    fn skill_not_approved_via_garbage_approved_at() {
        // SB6: any non-RFC3339 string was previously accepted; now rejected.
        let dir = tmpdir("approved-garbage");
        let mut m = manifest_with_review("x", true);
        m.approved_at = Some("yes".to_string());
        assert!(!skill_is_approved(&dir, &m));
        m.approved_at = Some("approved-by-attacker".to_string());
        assert!(!skill_is_approved(&dir, &m));
    }

    #[tokio::test]
    async fn read_capped_rejects_oversized() {
        let dir = tmpdir("cap-reject");
        let path = dir.join("big.md");
        let big = vec![b'x'; (MAX_SKILL_FILE_BYTES + 1) as usize];
        std::fs::write(&path, &big).unwrap();
        let res = read_skill_file_capped(&path).await;
        assert!(res.is_err(), "expected error on oversized file");
    }

    #[tokio::test]
    async fn read_capped_accepts_normal() {
        let dir = tmpdir("cap-ok");
        let path = dir.join("ok.md");
        std::fs::write(&path, b"hello world").unwrap();
        let res = read_skill_file_capped(&path).await;
        assert_eq!(res.unwrap(), "hello world");
    }

    #[tokio::test]
    async fn write_atomic_replaces_file() {
        let dir = tmpdir("atomic-replace");
        let path = dir.join("manifest.json");
        std::fs::write(&path, "old contents").unwrap();
        write_atomic(&path, "new contents").await.unwrap();
        let read_back = std::fs::read_to_string(&path).unwrap();
        assert_eq!(read_back, "new contents");
        // No leftover tempfiles in the dir.
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .filter(|e| {
                e.file_name()
                    .to_str()
                    .is_some_and(|s| s.starts_with(".manifest.json.tmp"))
            })
            .collect();
        assert!(
            leftovers.is_empty(),
            "tempfile leftover after atomic write: {leftovers:?}"
        );
    }

    #[tokio::test]
    async fn generated_skill_is_marked_for_review() {
        let dir = tmpdir("gen-review");
        let gen = SkillGenerator::new(&dir);
        let manifest = gen
            .generate_from_task(
                "open editor and save",
                &[
                    ("open".into(), "code .".into()),
                    ("save".into(), "echo saved".into()),
                ],
                true,
            )
            .await
            .unwrap()
            .expect("generated manifest");
        assert!(
            manifest.requires_review,
            "generated skills must default to requires_review=true"
        );
        assert!(manifest.approved_at.is_none());
    }

    #[tokio::test]
    async fn execute_skill_blocks_when_review_required() {
        let dir = tmpdir("exec-blocked");
        std::env::set_var("LIFEOS_SKILLS_AUTOEXEC_ENABLE", "1");
        let gen = SkillGenerator::new(&dir);
        let _m = gen
            .generate_from_task(
                "test task here",
                &[("a".into(), "true".into()), ("b".into(), "true".into())],
                true,
            )
            .await
            .unwrap()
            .unwrap();
        // The generator slugs the task name.
        let skill_dir = dir.join("skills").join(slugify("test task here"));
        let result = gen.execute_skill(&skill_dir).await;
        std::env::remove_var("LIFEOS_SKILLS_AUTOEXEC_ENABLE");
        let err = result.expect_err("must refuse unapproved auto-generated skill");
        let msg = format!("{err}");
        assert!(
            msg.contains("requires human approval") || msg.contains("requires_review"),
            "expected approval error, got: {msg}"
        );
    }

    #[test]
    fn manifest_default_requires_review_is_false_for_legacy_files() {
        // Older manifests on disk lack `requires_review`. Serde defaults
        // must give them `false` so existing approved skills keep working.
        let json = r#"{
            "name": "legacy",
            "description": "old skill",
            "version": "1.0.0",
            "trigger_patterns": [],
            "risk_level": "low",
            "created_at": "t",
            "last_used": null,
            "use_count": 0,
            "success_rate": 0.0
        }"#;
        let m: SkillManifest = serde_json::from_str(json).unwrap();
        assert!(!m.requires_review);
        assert!(m.approved_at.is_none());
    }
}
