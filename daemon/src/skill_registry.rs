//! Skill Registry v2 — Plugin SDK + Capability Registry (Fase AC)
//!
//! Provides a formal manifest schema (`SkillManifest`) with typed capabilities
//! and permissions, a centralised `SkillRegistry` that discovers skills from
//! well-known directories, validates manifests, and supports hot-reload.
//!
//! Discovery paths (highest-precedence first):
//! 1. `~/.local/share/lifeos/skills/` — user-installed skills
//! 2. `/usr/share/lifeos/skills/`     — system (immutable image) skills
//!
//! Each skill is a directory containing a `skill.json` manifest.

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use log::{debug, info, warn};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use tokio::sync::RwLock;

// ---------------------------------------------------------------------------
// Manifest types
// ---------------------------------------------------------------------------

/// Formal v2 skill manifest — declared in `skill.json` inside each skill dir.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillManifest {
    pub name: String,
    pub version: String,
    pub description: String,
    pub author: String,
    #[serde(default)]
    pub capabilities: Vec<SkillCapability>,
    #[serde(default)]
    pub permissions: Vec<SkillPermission>,
    #[serde(default)]
    pub triggers: Vec<String>,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

fn default_true() -> bool {
    true
}

/// What kind of extension a skill provides.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SkillCapability {
    /// Adds a new tool to the agent.
    Tool,
    /// Intercepts / reacts to daemon events.
    Hook,
    /// Adds a new LLM provider.
    Provider,
    /// Adds a data source (sensor / metric).
    Sensor,
    /// Adds a messaging channel.
    Channel,
}

/// Permissions a skill declares it needs.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SkillPermission {
    FilesystemRead,
    FilesystemWrite,
    Network,
    ShellExecute,
    LlmQuery,
    NotificationSend,
}

// ---------------------------------------------------------------------------
// Registry types
// ---------------------------------------------------------------------------

/// A skill that has been discovered, validated, and loaded into the registry.
#[derive(Debug, Clone)]
pub struct RegisteredSkill {
    pub manifest: SkillManifest,
    pub path: PathBuf,
    pub loaded_at: DateTime<Utc>,
    pub status: SkillStatus,
}

/// Current runtime status of a registered skill.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum SkillStatus {
    Active,
    Disabled,
    Error(String),
}

/// A single diagnostic finding for a skill.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillDiagnostic {
    pub skill_name: String,
    pub path: String,
    pub issues: Vec<String>,
    pub healthy: bool,
}

/// Immutable point-in-time snapshot of the registry (for API responses).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegistrySnapshot {
    pub skills: Vec<SkillSnapshotEntry>,
    pub total: usize,
    pub taken_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillSnapshotEntry {
    pub name: String,
    pub version: String,
    pub description: String,
    pub capabilities: Vec<SkillCapability>,
    pub status: SkillStatus,
    pub path: String,
}

// ---------------------------------------------------------------------------
// SkillRegistry
// ---------------------------------------------------------------------------

/// Centralised registry of v2 skills with discovery, validation, and hot-reload.
pub struct SkillRegistry {
    skills: RwLock<HashMap<String, RegisteredSkill>>,
    discovery_paths: Vec<PathBuf>,
}

impl SkillRegistry {
    /// Create a new registry with custom discovery paths.
    pub fn new(discovery_paths: Vec<PathBuf>) -> Self {
        Self {
            skills: RwLock::new(HashMap::new()),
            discovery_paths,
        }
    }

    /// Build a registry from the standard LifeOS paths.
    pub fn from_defaults() -> Self {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
        let paths = vec![
            PathBuf::from(&home).join(".local/share/lifeos/skills"),
            PathBuf::from("/usr/share/lifeos/skills"),
        ];
        Self::new(paths)
    }

    // -- Discovery & loading ------------------------------------------------

    /// Scan all discovery paths, validate manifests, and populate the registry.
    pub async fn discover_and_load(&self) -> Result<usize> {
        let mut loaded = 0usize;
        let mut new_map: HashMap<String, RegisteredSkill> = HashMap::new();

        for dir in &self.discovery_paths {
            if !dir.exists() {
                debug!(
                    "[skill_registry_v2] Discovery path does not exist: {}",
                    dir.display()
                );
                continue;
            }

            let mut entries = match tokio::fs::read_dir(dir).await {
                Ok(e) => e,
                Err(e) => {
                    warn!(
                        "[skill_registry_v2] Cannot read {}: {}",
                        dir.display(),
                        e
                    );
                    continue;
                }
            };

            while let Ok(Some(entry)) = entries.next_entry().await {
                let path = entry.path();
                if !path.is_dir() {
                    continue;
                }

                let manifest_path = path.join("skill.json");
                if !manifest_path.exists() {
                    debug!(
                        "[skill_registry_v2] No skill.json in {}",
                        path.display()
                    );
                    continue;
                }

                let registered = match self.load_skill(&path, &manifest_path).await {
                    Ok(s) => s,
                    Err(e) => {
                        let name = path
                            .file_name()
                            .and_then(|n| n.to_str())
                            .unwrap_or("unknown")
                            .to_string();
                        warn!(
                            "[skill_registry_v2] Failed to load skill '{}': {}",
                            name, e
                        );
                        RegisteredSkill {
                            manifest: SkillManifest {
                                name: name.clone(),
                                version: String::new(),
                                description: String::new(),
                                author: String::new(),
                                capabilities: Vec::new(),
                                permissions: Vec::new(),
                                triggers: Vec::new(),
                                enabled: false,
                            },
                            path: path.clone(),
                            loaded_at: Utc::now(),
                            status: SkillStatus::Error(e.to_string()),
                        }
                    }
                };

                // User skills (first discovery path) take precedence over system skills.
                if !new_map.contains_key(&registered.manifest.name) {
                    loaded += 1;
                    new_map.insert(registered.manifest.name.clone(), registered);
                } else {
                    debug!(
                        "[skill_registry_v2] Duplicate skill '{}' at {} — skipped (earlier path wins)",
                        new_map.get(
                            path.file_name().and_then(|n| n.to_str()).unwrap_or("")
                        ).map(|s| s.manifest.name.as_str()).unwrap_or("?"),
                        path.display()
                    );
                }
            }
        }

        let mut skills = self.skills.write().await;
        *skills = new_map;

        info!("[skill_registry_v2] Loaded {} skills", loaded);
        Ok(loaded)
    }

    /// Load and validate a single skill directory.
    async fn load_skill(
        &self,
        skill_dir: &Path,
        manifest_path: &Path,
    ) -> Result<RegisteredSkill> {
        // 1. Check directory is not world-writable.
        check_not_world_writable(skill_dir)?;

        // 2. Read and parse manifest.
        let content = tokio::fs::read_to_string(manifest_path)
            .await
            .with_context(|| format!("Reading {}", manifest_path.display()))?;
        let manifest: SkillManifest = serde_json::from_str(&content)
            .with_context(|| format!("Parsing {}", manifest_path.display()))?;

        // 3. Validate manifest fields.
        validate_manifest(&manifest)?;

        // 4. Determine status.
        let status = if manifest.enabled {
            SkillStatus::Active
        } else {
            SkillStatus::Disabled
        };

        Ok(RegisteredSkill {
            manifest,
            path: skill_dir.to_path_buf(),
            loaded_at: Utc::now(),
            status,
        })
    }

    // -- Lookup -------------------------------------------------------------

    /// Get a registered skill by name.
    pub async fn get_skill(&self, name: &str) -> Option<RegisteredSkill> {
        let skills = self.skills.read().await;
        skills.get(name).cloned()
    }

    /// List all registered skills.
    pub async fn list_skills(&self) -> Vec<RegisteredSkill> {
        let skills = self.skills.read().await;
        skills.values().cloned().collect()
    }

    /// Hot-reload a single skill by name (re-reads its manifest from disk).
    pub async fn reload_skill(&self, name: &str) -> Result<()> {
        let path = {
            let skills = self.skills.read().await;
            match skills.get(name) {
                Some(s) => s.path.clone(),
                None => anyhow::bail!("Skill '{}' not found in registry", name),
            }
        };

        let manifest_path = path.join("skill.json");
        let registered = self.load_skill(&path, &manifest_path).await?;

        let mut skills = self.skills.write().await;
        skills.insert(name.to_string(), registered);
        info!("[skill_registry_v2] Reloaded skill '{}'", name);
        Ok(())
    }

    // -- Snapshot & diagnostics ---------------------------------------------

    /// Return an immutable snapshot of the current registry state.
    pub async fn snapshot(&self) -> RegistrySnapshot {
        let skills = self.skills.read().await;
        let entries: Vec<SkillSnapshotEntry> = skills
            .values()
            .map(|s| SkillSnapshotEntry {
                name: s.manifest.name.clone(),
                version: s.manifest.version.clone(),
                description: s.manifest.description.clone(),
                capabilities: s.manifest.capabilities.clone(),
                status: s.status.clone(),
                path: s.path.display().to_string(),
            })
            .collect();
        let total = entries.len();
        RegistrySnapshot {
            skills: entries,
            total,
            taken_at: Utc::now(),
        }
    }

    /// Run health diagnostics on all registered skills.
    pub async fn diagnose_skills(&self) -> Vec<SkillDiagnostic> {
        let skills = self.skills.read().await;
        let mut diagnostics = Vec::new();

        for (name, skill) in skills.iter() {
            let mut issues = Vec::new();

            // 1. skill.json exists and is valid
            let manifest_path = skill.path.join("skill.json");
            if !manifest_path.exists() {
                issues.push("skill.json missing".to_string());
            } else {
                match tokio::fs::read_to_string(&manifest_path).await {
                    Ok(content) => {
                        if serde_json::from_str::<SkillManifest>(&content).is_err() {
                            issues.push("skill.json is not valid JSON or has wrong schema".to_string());
                        }
                    }
                    Err(e) => {
                        issues.push(format!("Cannot read skill.json: {}", e));
                    }
                }
            }

            // 2. Directory permissions
            if check_not_world_writable(&skill.path).is_err() {
                issues.push("Directory is world-writable (security risk)".to_string());
            }

            // 3. Check for executable entry point
            let has_run_sh = skill.path.join("run.sh").exists();
            let has_main = skill.path.join("main.py").exists()
                || skill.path.join("main.sh").exists();
            if !has_run_sh && !has_main {
                issues.push("No executable entry point found (run.sh, main.py, main.sh)".to_string());
            } else if has_run_sh {
                // Check run.sh is executable
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    if let Ok(meta) = std::fs::metadata(skill.path.join("run.sh")) {
                        let mode = meta.permissions().mode();
                        if mode & 0o111 == 0 {
                            issues.push("run.sh exists but is not executable".to_string());
                        }
                    }
                }
            }

            // 4. Check current status for errors
            if let SkillStatus::Error(ref e) = skill.status {
                issues.push(format!("Load error: {}", e));
            }

            let healthy = issues.is_empty();
            diagnostics.push(SkillDiagnostic {
                skill_name: name.clone(),
                path: skill.path.display().to_string(),
                issues,
                healthy,
            });
        }

        diagnostics
    }
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

/// Validate a manifest's required fields.
pub fn validate_manifest(manifest: &SkillManifest) -> Result<()> {
    if manifest.name.is_empty() {
        anyhow::bail!("Skill name cannot be empty");
    }
    if manifest.name.len() > 128 {
        anyhow::bail!("Skill name too long (max 128 chars)");
    }
    // Name must be filesystem-safe: alphanumeric, hyphens, underscores
    if !manifest
        .name
        .chars()
        .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
    {
        anyhow::bail!(
            "Skill name '{}' contains invalid characters (allowed: alphanumeric, -, _)",
            manifest.name
        );
    }
    if manifest.version.is_empty() {
        anyhow::bail!("Skill version cannot be empty");
    }
    if manifest.description.is_empty() {
        anyhow::bail!("Skill description cannot be empty");
    }
    if manifest.author.is_empty() {
        anyhow::bail!("Skill author cannot be empty");
    }
    Ok(())
}

/// Check that a directory is not world-writable (o+w bit).
fn check_not_world_writable(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let meta = std::fs::metadata(path)
            .with_context(|| format!("Cannot stat {}", path.display()))?;
        let mode = meta.permissions().mode();
        if mode & 0o002 != 0 {
            anyhow::bail!(
                "Directory {} is world-writable (mode {:o}) — refusing to load skill",
                path.display(),
                mode
            );
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// Simple RAII temp directory.
    struct TmpDir(PathBuf);
    impl TmpDir {
        fn new(name: &str) -> Self {
            let dir = std::env::temp_dir()
                .join(format!("lifeos-test-sr-{}-{}", name, std::process::id()));
            fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }
        fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for TmpDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn make_valid_manifest() -> SkillManifest {
        SkillManifest {
            name: "test-skill".to_string(),
            version: "1.0.0".to_string(),
            description: "A test skill".to_string(),
            author: "tester".to_string(),
            capabilities: vec![SkillCapability::Tool],
            permissions: vec![SkillPermission::ShellExecute],
            triggers: vec!["test".to_string()],
            enabled: true,
        }
    }

    fn write_skill(dir: &Path, manifest: &SkillManifest) -> PathBuf {
        let skill_dir = dir.join(&manifest.name);
        fs::create_dir_all(&skill_dir).unwrap();
        let json = serde_json::to_string_pretty(manifest).unwrap();
        fs::write(skill_dir.join("skill.json"), json).unwrap();
        skill_dir
    }

    // -- Manifest validation ------------------------------------------------

    #[test]
    fn test_valid_manifest_accepted() {
        let manifest = make_valid_manifest();
        assert!(validate_manifest(&manifest).is_ok());
    }

    #[test]
    fn test_invalid_manifest_rejected_empty_name() {
        let mut manifest = make_valid_manifest();
        manifest.name = String::new();
        assert!(validate_manifest(&manifest).is_err());
    }

    #[test]
    fn test_invalid_manifest_rejected_bad_chars() {
        let mut manifest = make_valid_manifest();
        manifest.name = "has spaces".to_string();
        assert!(validate_manifest(&manifest).is_err());
    }

    #[test]
    fn test_invalid_manifest_rejected_empty_version() {
        let mut manifest = make_valid_manifest();
        manifest.version = String::new();
        assert!(validate_manifest(&manifest).is_err());
    }

    #[test]
    fn test_invalid_manifest_rejected_empty_author() {
        let mut manifest = make_valid_manifest();
        manifest.author = String::new();
        assert!(validate_manifest(&manifest).is_err());
    }

    #[test]
    fn test_invalid_manifest_rejected_empty_description() {
        let mut manifest = make_valid_manifest();
        manifest.description = String::new();
        assert!(validate_manifest(&manifest).is_err());
    }

    // -- Discovery ----------------------------------------------------------

    #[tokio::test]
    async fn test_discovery_finds_skills() {
        let tmp = TmpDir::new("discovery");

        let manifest = make_valid_manifest();
        write_skill(tmp.path(), &manifest);

        let registry = SkillRegistry::new(vec![tmp.path().to_path_buf()]);
        let loaded = registry.discover_and_load().await.unwrap();

        assert_eq!(loaded, 1);
        let skill = registry.get_skill("test-skill").await;
        assert!(skill.is_some());
        assert_eq!(skill.unwrap().manifest.version, "1.0.0");
    }

    #[tokio::test]
    async fn test_discovery_skips_dirs_without_manifest() {
        let tmp = TmpDir::new("no-manifest");

        // Create a directory without skill.json
        fs::create_dir_all(tmp.path().join("empty-dir")).unwrap();

        let registry = SkillRegistry::new(vec![tmp.path().to_path_buf()]);
        let loaded = registry.discover_and_load().await.unwrap();

        assert_eq!(loaded, 0);
    }

    // -- World-writable rejection -------------------------------------------

    #[cfg(unix)]
    #[tokio::test]
    async fn test_world_writable_rejected() {
        use std::os::unix::fs::PermissionsExt;

        let tmp = TmpDir::new("world-writable");

        let manifest = make_valid_manifest();
        let skill_dir = write_skill(tmp.path(), &manifest);

        // Make the skill directory world-writable
        let perms = std::fs::Permissions::from_mode(0o777);
        std::fs::set_permissions(&skill_dir, perms).unwrap();

        let registry = SkillRegistry::new(vec![tmp.path().to_path_buf()]);
        let loaded = registry.discover_and_load().await.unwrap();

        // It should still be "loaded" but with Error status
        assert_eq!(loaded, 1);
        let skill = registry.get_skill("test-skill").await.unwrap();
        assert!(
            matches!(skill.status, SkillStatus::Error(ref e) if e.contains("world-writable")),
            "Expected world-writable error, got: {:?}",
            skill.status
        );
    }

    // -- Snapshot -----------------------------------------------------------

    #[tokio::test]
    async fn test_snapshot_is_immutable() {
        let tmp = TmpDir::new("snapshot");

        let manifest = make_valid_manifest();
        write_skill(tmp.path(), &manifest);

        let registry = SkillRegistry::new(vec![tmp.path().to_path_buf()]);
        registry.discover_and_load().await.unwrap();

        let snap1 = registry.snapshot().await;
        assert_eq!(snap1.total, 1);

        // Add a second skill after the snapshot
        let mut m2 = make_valid_manifest();
        m2.name = "second-skill".to_string();
        write_skill(tmp.path(), &m2);
        registry.discover_and_load().await.unwrap();

        // Original snapshot should be unchanged
        assert_eq!(snap1.total, 1);
        assert_eq!(snap1.skills.len(), 1);

        // New snapshot has both
        let snap2 = registry.snapshot().await;
        assert_eq!(snap2.total, 2);
    }

    // -- Conflict resolution / precedence -----------------------------------

    #[tokio::test]
    async fn test_conflict_resolution_precedence() {
        let user_dir = TmpDir::new("user-skills");
        let system_dir = TmpDir::new("system-skills");

        // Both directories have a skill with the same name but different descriptions
        let mut user_manifest = make_valid_manifest();
        user_manifest.description = "User version".to_string();
        write_skill(user_dir.path(), &user_manifest);

        let mut sys_manifest = make_valid_manifest();
        sys_manifest.description = "System version".to_string();
        write_skill(system_dir.path(), &sys_manifest);

        // User dir listed first — should take precedence
        let registry = SkillRegistry::new(vec![
            user_dir.path().to_path_buf(),
            system_dir.path().to_path_buf(),
        ]);
        registry.discover_and_load().await.unwrap();

        let skill = registry.get_skill("test-skill").await.unwrap();
        assert_eq!(
            skill.manifest.description, "User version",
            "User skill should take precedence over system skill"
        );
    }

    // -- Reload -------------------------------------------------------------

    #[tokio::test]
    async fn test_reload_skill() {
        let tmp = TmpDir::new("reload");

        let manifest = make_valid_manifest();
        write_skill(tmp.path(), &manifest);

        let registry = SkillRegistry::new(vec![tmp.path().to_path_buf()]);
        registry.discover_and_load().await.unwrap();

        // Modify the manifest on disk
        let mut updated = manifest.clone();
        updated.version = "2.0.0".to_string();
        let json = serde_json::to_string_pretty(&updated).unwrap();
        fs::write(
            tmp.path().join("test-skill").join("skill.json"),
            json,
        )
        .unwrap();

        // Reload
        registry.reload_skill("test-skill").await.unwrap();

        let skill = registry.get_skill("test-skill").await.unwrap();
        assert_eq!(skill.manifest.version, "2.0.0");
    }

    // -- Diagnostics --------------------------------------------------------

    #[tokio::test]
    async fn test_diagnose_skills() {
        let tmp = TmpDir::new("diagnose");

        let manifest = make_valid_manifest();
        write_skill(tmp.path(), &manifest);

        let registry = SkillRegistry::new(vec![tmp.path().to_path_buf()]);
        registry.discover_and_load().await.unwrap();

        let diags = registry.diagnose_skills().await;
        assert_eq!(diags.len(), 1);
        // No run.sh so it should flag missing entry point
        assert!(!diags[0].healthy);
        assert!(diags[0].issues.iter().any(|i| i.contains("entry point")));
    }

    // -- Serde roundtrip ----------------------------------------------------

    #[test]
    fn test_manifest_serde_roundtrip() {
        let manifest = make_valid_manifest();
        let json = serde_json::to_string(&manifest).unwrap();
        let parsed: SkillManifest = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.name, manifest.name);
        assert_eq!(parsed.capabilities, manifest.capabilities);
        assert_eq!(parsed.permissions, manifest.permissions);
        assert!(parsed.enabled);
    }

    #[test]
    fn test_manifest_defaults_on_missing_fields() {
        let json = r#"{
            "name": "minimal",
            "version": "0.1.0",
            "description": "Minimal skill",
            "author": "test"
        }"#;
        let manifest: SkillManifest = serde_json::from_str(json).unwrap();
        assert!(manifest.capabilities.is_empty());
        assert!(manifest.permissions.is_empty());
        assert!(manifest.triggers.is_empty());
        assert!(manifest.enabled);
    }

    // -- list_skills --------------------------------------------------------

    #[tokio::test]
    async fn test_list_skills_empty() {
        let tmp = TmpDir::new("list-empty");
        let registry = SkillRegistry::new(vec![tmp.path().to_path_buf()]);
        registry.discover_and_load().await.unwrap();
        let list = registry.list_skills().await;
        assert!(list.is_empty());
    }

    // -- Disabled skill -----------------------------------------------------

    #[tokio::test]
    async fn test_disabled_skill_gets_disabled_status() {
        let tmp = TmpDir::new("disabled");

        let mut manifest = make_valid_manifest();
        manifest.enabled = false;
        write_skill(tmp.path(), &manifest);

        let registry = SkillRegistry::new(vec![tmp.path().to_path_buf()]);
        registry.discover_and_load().await.unwrap();

        let skill = registry.get_skill("test-skill").await.unwrap();
        assert_eq!(skill.status, SkillStatus::Disabled);
    }
}
