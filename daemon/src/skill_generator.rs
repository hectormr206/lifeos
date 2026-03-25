//! Skill Generator — Axi learns from interactions and creates reusable skills.
//!
//! When Axi successfully completes a task, it can analyze the execution pattern
//! and generate a reusable skill (script + metadata) that can be invoked later
//! without re-planning. Skills are stored in ~/.local/share/lifeos/skills/.
//!
//! Skill format:
//! - manifest.json: name, description, trigger patterns, risk level
//! - run.sh: executable entrypoint
//! - README.md: human-readable documentation

use anyhow::{Context, Result};
use log::info;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::fs;

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
            Ok(stdout.to_string())
        } else {
            anyhow::bail!("Skill failed: {}{}", stdout, stderr)
        }
    }
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
