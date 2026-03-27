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

use anyhow::{Context, Result};
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
    pub async fn execute_skill(&self, skill_dir: &std::path::Path) -> Result<String> {
        let script = skill_dir.join("run.sh");
        if !script.exists() {
            anyhow::bail!("Skill script not found: {}", script.display());
        }

        let output = tokio::process::Command::new("bash")
            .arg(&script)
            .output()
            .await
            .context("Failed to execute skill")?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);

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
    async fn update_skill_stats(&self, manifest_path: &std::path::Path, success: bool) {
        if let Ok(content) = fs::read_to_string(manifest_path).await {
            if let Ok(mut manifest) = serde_json::from_str::<SkillManifest>(&content) {
                manifest.use_count += 1;
                manifest.last_used = Some(chrono::Utc::now().to_rfc3339());
                // Running average of success rate
                let total = manifest.use_count as f64;
                let prev_successes = manifest.success_rate * (total - 1.0);
                manifest.success_rate = (prev_successes + if success { 1.0 } else { 0.0 }) / total;

                if let Ok(json) = serde_json::to_string_pretty(&manifest) {
                    let _ = fs::write(manifest_path, json).await;
                }
            }
        }
    }

    /// Get diagnostic metrics: total skills, avg success rate, most/least used.
    pub async fn diagnostics(&self) -> Result<SkillDiagnostics> {
        let skills = self.list_skills().await?;
        let total = skills.len();
        let avg_success = if total > 0 {
            skills.iter().map(|s| s.success_rate).sum::<f64>() / total as f64
        } else {
            0.0
        };
        let most_used = skills.iter().max_by_key(|s| s.use_count).cloned();
        let least_reliable = skills
            .iter()
            .filter(|s| s.use_count >= 3 && s.success_rate < 0.5)
            .cloned()
            .collect();

        Ok(SkillDiagnostics {
            total_skills: total,
            avg_success_rate: avg_success,
            most_used,
            unreliable_skills: least_reliable,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillDiagnostics {
    pub total_skills: usize,
    pub avg_success_rate: f64,
    pub most_used: Option<SkillManifest>,
    pub unreliable_skills: Vec<SkillManifest>,
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
                // Also accept SKILL.md-style directories (telegram_tools compat)
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
        let content = fs::read_to_string(path).await.ok()?;
        serde_json::from_str::<SkillManifest>(&content).ok()
    }

    async fn load_standalone_json(path: &std::path::Path) -> Option<SkillManifest> {
        let content = fs::read_to_string(path).await.ok()?;
        serde_json::from_str::<SkillManifest>(&content).ok()
    }

    async fn load_standalone_toml(path: &std::path::Path) -> Option<SkillManifest> {
        let content = fs::read_to_string(path).await.ok()?;
        toml::from_str::<SkillManifest>(&content).ok()
    }

    /// Load a SKILL.md file (telegram_tools format) and convert to SkillManifest.
    async fn load_skill_md(
        skill_md: &std::path::Path,
        skill_dir: &std::path::Path,
    ) -> Option<SkillManifest> {
        let content = fs::read_to_string(skill_md).await.ok()?;
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

    /// Find a skill matching an objective by trigger patterns.
    pub async fn find_for_objective(&self, objective: &str) -> Option<(SkillManifest, PathBuf)> {
        let lower = objective.to_lowercase();
        let inner = self.inner.read().await;
        for (manifest, dir) in inner.skills.values() {
            for pattern in &manifest.trigger_patterns {
                if lower.contains(&pattern.to_lowercase()) {
                    return Some((manifest.clone(), dir.clone()));
                }
            }
        }
        None
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
        let skill_md = skill_dir.join("SKILL.md");
        if skill_md.exists() {
            let content = fs::read_to_string(&skill_md).await?;
            let command = content
                .lines()
                .find(|l| l.to_lowercase().starts_with("command:"))
                .and_then(|l| l.split_once(':').map(|x| x.1))
                .map(|s| s.trim().to_string())
                .ok_or_else(|| anyhow::anyhow!("SKILL.md has no command: line"))?;

            let output = tokio::process::Command::new("sh")
                .arg("-c")
                .arg(&command)
                .current_dir(&skill_dir)
                .output()
                .await
                .context("Failed to execute SKILL.md command")?;

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

/// Record an interaction for skill learning.
/// Saves screenshot before/after + action + result to the skill directory.
pub async fn record_interaction(
    skills_dir: &std::path::Path,
    skill_name: &str,
    record: &InteractionRecord,
) -> anyhow::Result<()> {
    let recordings_dir = skills_dir.join(skill_name).join("recordings");
    fs::create_dir_all(&recordings_dir).await?;

    let filename = format!(
        "interaction-{}.json",
        chrono::Utc::now().format("%Y%m%d-%H%M%S-%3f")
    );
    let json = serde_json::to_string_pretty(record)?;
    fs::write(recordings_dir.join(filename), json).await?;

    info!(
        "[skill_gen] Recorded interaction for '{}': {} ({})",
        skill_name,
        record.action,
        if record.success { "OK" } else { "FAIL" }
    );
    Ok(())
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
