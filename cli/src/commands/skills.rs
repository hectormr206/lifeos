use crate::daemon_client;
use clap::Subcommand;
use colored::Colorize;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Subcommand)]
pub enum SkillsCommands {
    /// Generate a scaffolded skill package (manifest + entrypoint)
    Generate {
        #[arg(long)]
        id: String,
        #[arg(long, default_value = "0.1.0")]
        version: String,
        #[arg(long, default_value = "community", value_parser = ["core", "verified", "community"])]
        trust: String,
        /// Output directory for generated skill folder
        #[arg(long, default_value = ".")]
        output_dir: String,
    },
    /// Sign/update manifest by hashing current entrypoint content
    Sign {
        /// Path to skill manifest JSON
        #[arg(long)]
        manifest: String,
    },
    /// Install a skill from manifest
    Install {
        /// Path to skill manifest JSON
        #[arg(long)]
        manifest: String,
    },
    /// List installed skills
    List {
        /// Optional trust filter (core|verified|community)
        #[arg(long)]
        trust: Option<String>,
    },
    /// Verify installed skill integrity
    Verify {
        skill_id: String,
        /// Optional explicit version
        #[arg(long)]
        version: Option<String>,
    },
    /// Run a skill entrypoint
    Run {
        skill_id: String,
        /// Optional explicit version
        #[arg(long)]
        version: Option<String>,
        /// Disable sandbox execution (blocked for community trust)
        #[arg(long)]
        unsafe_no_sandbox: bool,
        /// Args passed to skill entrypoint
        #[arg(last = true)]
        args: Vec<String>,
    },
    /// Remove an installed skill
    Remove {
        skill_id: String,
        /// Optional explicit version
        #[arg(long)]
        version: Option<String>,
    },
    /// Export installed skills as MCP-compatible tools manifest
    McpExport {
        /// Optional output file path (prints to stdout when omitted)
        #[arg(long)]
        output: Option<String>,
        /// Optional trust filter (core|verified|community)
        #[arg(long)]
        trust: Option<String>,
    },
    /// Run diagnostics on all loaded skills (daemon-side registry)
    Doctor {
        /// Output in JSON format
        #[arg(long)]
        json: bool,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum TrustLevel {
    Core,
    Verified,
    Community,
}

impl TrustLevel {
    fn from_filter(input: &str) -> Option<Self> {
        match input.trim().to_lowercase().as_str() {
            "core" => Some(Self::Core),
            "verified" => Some(Self::Verified),
            "community" => Some(Self::Community),
            _ => None,
        }
    }

    fn as_str(&self) -> &'static str {
        match self {
            Self::Core => "core",
            Self::Verified => "verified",
            Self::Community => "community",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SkillManifest {
    id: String,
    version: String,
    trust_level: TrustLevel,
    entrypoint: String,
    #[serde(default)]
    entrypoint_sha256: Option<String>,
    #[serde(default)]
    description: String,
    #[serde(default)]
    capabilities: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct InstalledSkill {
    id: String,
    version: String,
    trust_level: TrustLevel,
    installed_at: String,
    skill_dir: String,
    manifest_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct SkillsRegistry {
    skills: Vec<InstalledSkill>,
}

pub async fn execute(cmd: SkillsCommands) -> anyhow::Result<()> {
    match cmd {
        SkillsCommands::Generate {
            id,
            version,
            trust,
            output_dir,
        } => cmd_generate(&id, &version, &trust, &output_dir),
        SkillsCommands::Sign { manifest } => cmd_sign(&manifest),
        SkillsCommands::Install { manifest } => cmd_install(&manifest),
        SkillsCommands::List { trust } => cmd_list(trust.as_deref()),
        SkillsCommands::Verify { skill_id, version } => cmd_verify(&skill_id, version.as_deref()),
        SkillsCommands::Run {
            skill_id,
            version,
            unsafe_no_sandbox,
            args,
        } => cmd_run(&skill_id, version.as_deref(), unsafe_no_sandbox, &args),
        SkillsCommands::Remove { skill_id, version } => cmd_remove(&skill_id, version.as_deref()),
        SkillsCommands::McpExport { output, trust } => {
            cmd_mcp_export(output.as_deref(), trust.as_deref())
        }
        SkillsCommands::Doctor { json } => cmd_doctor(json).await,
    }
}

fn cmd_generate(id: &str, version: &str, trust: &str, output_dir: &str) -> anyhow::Result<()> {
    let trust_level = TrustLevel::from_filter(trust)
        .ok_or_else(|| anyhow::anyhow!("invalid trust level '{}'", trust))?;
    if id.trim().is_empty() {
        anyhow::bail!("id is required");
    }
    if version.trim().is_empty() {
        anyhow::bail!("version is required");
    }

    let skill_dir = PathBuf::from(output_dir).join(id);
    std::fs::create_dir_all(&skill_dir)?;
    let entrypoint = skill_dir.join("run.sh");
    if !entrypoint.exists() {
        std::fs::write(
            &entrypoint,
            "#!/usr/bin/env sh\n# LifeOS skill entrypoint\n\necho \"skill executed\"\n",
        )?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&entrypoint)?.permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&entrypoint, perms)?;
        }
    }

    let digest = sha256_file(&entrypoint)?;
    let manifest = SkillManifest {
        id: id.to_string(),
        version: version.to_string(),
        trust_level,
        entrypoint: "run.sh".to_string(),
        entrypoint_sha256: Some(digest),
        description: "Generated LifeOS skill scaffold".to_string(),
        capabilities: vec![],
    };
    let manifest_path = skill_dir.join("skill.json");
    std::fs::write(&manifest_path, serde_json::to_string_pretty(&manifest)?)?;

    println!("{}", "Skill scaffold generated".green().bold());
    println!("  dir: {}", skill_dir.display().to_string().cyan());
    println!("  manifest: {}", manifest_path.display().to_string().cyan());
    Ok(())
}

fn cmd_sign(manifest_path: &str) -> anyhow::Result<()> {
    let path = PathBuf::from(manifest_path);
    let mut manifest = read_manifest(&path)?;
    validate_manifest(&manifest)?;

    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("manifest path has no parent"))?;
    let entrypoint = parent.join(&manifest.entrypoint);
    if !entrypoint.exists() {
        anyhow::bail!("entrypoint not found: {}", entrypoint.display());
    }

    let digest = sha256_file(&entrypoint)?;
    manifest.entrypoint_sha256 = Some(digest);
    std::fs::write(&path, serde_json::to_string_pretty(&manifest)?)?;

    println!("{}", "Skill manifest signed".green().bold());
    println!("  manifest: {}", path.display().to_string().cyan());
    Ok(())
}

fn cmd_install(manifest_path: &str) -> anyhow::Result<()> {
    let installed = install_from_manifest(manifest_path)?;
    println!("{}", "Skill installed".green().bold());
    println!("  id: {}", installed.id.cyan());
    println!("  version: {}", installed.version.cyan());
    println!("  trust: {}", installed.trust_level.as_str().cyan());
    println!("  dir: {}", installed.skill_dir);
    Ok(())
}

fn cmd_list(trust: Option<&str>) -> anyhow::Result<()> {
    let registry = load_registry()?;
    let trust_filter = trust.and_then(TrustLevel::from_filter);
    println!("{}", "Installed skills".bold().blue());

    if registry.skills.is_empty() {
        println!("  {}", "No skills installed.".dimmed());
        return Ok(());
    }

    for skill in registry.skills {
        if let Some(ref filter) = trust_filter {
            if &skill.trust_level != filter {
                continue;
            }
        }
        println!(
            "  {}@{} [{}] {}",
            skill.id.cyan(),
            skill.version,
            skill.trust_level.as_str(),
            skill.installed_at.dimmed()
        );
    }
    Ok(())
}

fn cmd_verify(skill_id: &str, version: Option<&str>) -> anyhow::Result<()> {
    let registry = load_registry()?;
    let skill = find_installed_skill(&registry, skill_id, version)
        .ok_or_else(|| anyhow::anyhow!("Skill not found: {}", skill_id))?;
    let manifest = read_manifest(Path::new(&skill.manifest_path))?;
    verify_skill_integrity(&skill, &manifest)?;

    println!("{}", "Skill integrity OK".green().bold());
    println!("  id: {}", skill.id.cyan());
    println!("  version: {}", skill.version.cyan());
    println!("  trust: {}", skill.trust_level.as_str().cyan());
    Ok(())
}

fn cmd_run(
    skill_id: &str,
    version: Option<&str>,
    unsafe_no_sandbox: bool,
    args: &[String],
) -> anyhow::Result<()> {
    let registry = load_registry()?;
    let skill = find_installed_skill(&registry, skill_id, version)
        .ok_or_else(|| anyhow::anyhow!("Skill not found: {}", skill_id))?;
    let manifest = read_manifest(Path::new(&skill.manifest_path))?;
    verify_skill_integrity(&skill, &manifest)?;

    if unsafe_no_sandbox && skill.trust_level == TrustLevel::Community {
        anyhow::bail!("community skills cannot run with --unsafe-no-sandbox");
    }

    let entrypoint = PathBuf::from(&skill.skill_dir).join(&manifest.entrypoint);
    if !entrypoint.exists() {
        anyhow::bail!("entrypoint not found: {}", entrypoint.display());
    }

    let mut command = Command::new("sh");
    command.arg(entrypoint.as_os_str()).args(args);
    command.current_dir(&skill.skill_dir);
    command.stdin(Stdio::inherit());
    command.stdout(Stdio::inherit());
    command.stderr(Stdio::inherit());

    if !unsafe_no_sandbox {
        let sandbox_home = std::env::temp_dir().join(format!("lifeos-skill-{}", unique_suffix()));
        std::fs::create_dir_all(&sandbox_home)?;
        command.env_clear();
        command.env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin");
        command.env("HOME", &sandbox_home);
        command.env("LIFEOS_SKILL_SANDBOX", "1");
        command.env("LIFEOS_SKILL_ID", &skill.id);
        command.env("LIFEOS_SKILL_VERSION", &skill.version);
        command.env("LIFEOS_SKILL_TRUST_LEVEL", skill.trust_level.as_str());
    }

    let status = command.status()?;
    if status.success() {
        println!("{}", "Skill run completed".green().bold());
        Ok(())
    } else {
        anyhow::bail!(
            "Skill run failed with exit code {}",
            status.code().unwrap_or(1)
        )
    }
}

fn cmd_remove(skill_id: &str, version: Option<&str>) -> anyhow::Result<()> {
    let mut registry = load_registry()?;
    let before = registry.skills.len();
    let mut removed = Vec::new();

    registry.skills.retain(|skill| {
        let matches_id = skill.id == skill_id;
        let matches_version = version.map(|v| v == skill.version).unwrap_or(true);
        let remove = matches_id && matches_version;
        if remove {
            removed.push(skill.clone());
        }
        !remove
    });

    if removed.is_empty() {
        println!("{}", "No matching skill found".yellow().bold());
        return Ok(());
    }

    for item in &removed {
        let _ = std::fs::remove_dir_all(&item.skill_dir);
    }

    if registry.skills.len() != before {
        save_registry(&registry)?;
    }

    println!("{}", "Skill removed".green().bold());
    for item in removed {
        println!("  {}@{}", item.id.cyan(), item.version);
    }
    Ok(())
}

fn cmd_mcp_export(output: Option<&str>, trust: Option<&str>) -> anyhow::Result<()> {
    let registry = load_registry()?;
    let trust_filter = trust.and_then(TrustLevel::from_filter);

    let mut tools = Vec::new();
    for skill in registry.skills {
        if let Some(ref filter) = trust_filter {
            if &skill.trust_level != filter {
                continue;
            }
        }

        let manifest = read_manifest(Path::new(&skill.manifest_path))?;
        verify_skill_integrity(&skill, &manifest)?;
        let tool_name = sanitize_tool_name(&skill.id);
        let description = if manifest.description.trim().is_empty() {
            format!("Run skill {}@{}", skill.id, skill.version)
        } else {
            manifest.description.clone()
        };

        tools.push(serde_json::json!({
            "name": format!("skills.{}", tool_name),
            "description": description,
            "inputSchema": {
                "type": "object",
                "properties": {
                    "args": {
                        "type": "array",
                        "items": { "type": "string" }
                    }
                },
                "additionalProperties": false
            },
            "metadata": {
                "skill_id": skill.id,
                "version": skill.version,
                "trust_level": skill.trust_level.as_str(),
            },
            "run": {
                "type": "command",
                "argv_template": ["life", "skills", "run", skill.id, "--", "${args...}"]
            }
        }));
    }

    let payload = serde_json::json!({
        "protocol": "mcp-tools/v1",
        "server": "lifeos-skills",
        "generated_at": chrono::Utc::now().to_rfc3339(),
        "tools_count": tools.len(),
        "tools": tools,
    });

    let rendered = serde_json::to_string_pretty(&payload)?;
    if let Some(path) = output {
        std::fs::write(path, rendered)?;
        println!("{}", "MCP tools manifest exported".green().bold());
        println!("  output: {}", path.cyan());
        println!("  tools: {}", payload["tools_count"]);
    } else {
        println!("{}", rendered);
    }
    Ok(())
}

async fn cmd_doctor(json: bool) -> anyhow::Result<()> {
    let client = daemon_client::authenticated_client();
    let base = daemon_client::daemon_url();
    let url = format!("{}/api/v1/skills/diagnostics", base);

    if !json {
        println!(
            "{}",
            "LifeOS Skills Doctor - Registry Diagnostics".bold().blue()
        );
        println!();
    }

    match client.get(&url).send().await {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = r
                .json()
                .await
                .unwrap_or_else(|_| serde_json::json!({"diagnostics": {}}));

            if json {
                println!("{}", serde_json::to_string_pretty(&body)?);
            } else {
                if let Some(diag) = body.get("diagnostics") {
                    if let Some(obj) = diag.as_object() {
                        for (key, value) in obj {
                            println!("  {}: {}", key.bold(), value);
                        }
                    } else {
                        println!("  {}", diag);
                    }
                } else {
                    println!("  {}", "No diagnostics data returned.".dimmed());
                }
                println!();
                println!(
                    "  {}",
                    "Tip: use --json for machine-readable output.".dimmed()
                );
            }
        }
        Ok(r) => {
            let status = r.status();
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "error": format!("Daemon returned HTTP {}", status),
                    }))?
                );
            } else {
                println!("  {} Daemon returned HTTP {}", "!".yellow().bold(), status);
            }
        }
        Err(e) => {
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "error": format!("Cannot reach lifeosd: {}", e),
                    }))?
                );
            } else {
                println!(
                    "  {} Cannot reach lifeosd at {}",
                    "X".red().bold(),
                    base.dimmed()
                );
                println!("    Error: {}", format!("{e}").dimmed());
            }
        }
    }

    Ok(())
}

fn install_from_manifest(manifest_path: &str) -> anyhow::Result<InstalledSkill> {
    let manifest_path = PathBuf::from(manifest_path);
    let manifest = read_manifest(&manifest_path)?;
    validate_manifest(&manifest)?;

    let manifest_parent = manifest_path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("manifest path has no parent"))?;
    let entry_source = manifest_parent.join(&manifest.entrypoint);
    if !entry_source.exists() {
        anyhow::bail!("entrypoint not found: {}", entry_source.display());
    }

    if let Some(expected) = &manifest.entrypoint_sha256 {
        let digest = sha256_file(&entry_source)?;
        if &digest != expected {
            anyhow::bail!(
                "entrypoint_sha256 mismatch: expected {}, got {}",
                expected,
                digest
            );
        }
    }

    let skill_dir = skills_root_dir()
        .join("installed")
        .join(&manifest.id)
        .join(&manifest.version);
    std::fs::create_dir_all(&skill_dir)?;

    let entry_dest = skill_dir.join("entrypoint.sh");
    std::fs::copy(&entry_source, &entry_dest)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&entry_dest)?.permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&entry_dest, perms)?;
    }

    let mut installed_manifest = manifest.clone();
    installed_manifest.entrypoint = "entrypoint.sh".to_string();
    let manifest_dest = skill_dir.join("manifest.json");
    std::fs::write(
        &manifest_dest,
        serde_json::to_string_pretty(&installed_manifest)?,
    )?;

    let mut registry = load_registry()?;
    registry
        .skills
        .retain(|s| !(s.id == installed_manifest.id && s.version == installed_manifest.version));
    let installed = InstalledSkill {
        id: installed_manifest.id.clone(),
        version: installed_manifest.version.clone(),
        trust_level: installed_manifest.trust_level.clone(),
        installed_at: chrono::Utc::now().to_rfc3339(),
        skill_dir: skill_dir.to_string_lossy().to_string(),
        manifest_path: manifest_dest.to_string_lossy().to_string(),
    };
    registry.skills.push(installed.clone());
    save_registry(&registry)?;

    Ok(installed)
}

fn verify_skill_integrity(skill: &InstalledSkill, manifest: &SkillManifest) -> anyhow::Result<()> {
    let entrypoint = PathBuf::from(&skill.skill_dir).join(&manifest.entrypoint);
    if !entrypoint.exists() {
        anyhow::bail!("entrypoint file missing: {}", entrypoint.display());
    }
    if let Some(expected) = &manifest.entrypoint_sha256 {
        let digest = sha256_file(&entrypoint)?;
        if &digest != expected {
            anyhow::bail!(
                "entrypoint_sha256 mismatch for {}@{}",
                skill.id,
                skill.version
            );
        }
    }
    Ok(())
}

fn validate_manifest(manifest: &SkillManifest) -> anyhow::Result<()> {
    if manifest.id.trim().is_empty() {
        anyhow::bail!("manifest.id is required");
    }
    if manifest.version.trim().is_empty() {
        anyhow::bail!("manifest.version is required");
    }
    if manifest.entrypoint.trim().is_empty() {
        anyhow::bail!("manifest.entrypoint is required");
    }
    if Path::new(&manifest.entrypoint).is_absolute() {
        anyhow::bail!("manifest.entrypoint must be a relative path");
    }
    if let Some(sum) = &manifest.entrypoint_sha256 {
        let normalized = sum.trim();
        if normalized.len() != 64 || !normalized.chars().all(|c| c.is_ascii_hexdigit()) {
            anyhow::bail!("manifest.entrypoint_sha256 must be a 64-char hex digest");
        }
    }
    Ok(())
}

fn find_installed_skill(
    registry: &SkillsRegistry,
    skill_id: &str,
    version: Option<&str>,
) -> Option<InstalledSkill> {
    let mut candidates = registry
        .skills
        .iter()
        .filter(|s| s.id == skill_id && version.map(|v| s.version == v).unwrap_or(true))
        .cloned()
        .collect::<Vec<_>>();
    candidates.sort_by(|a, b| a.installed_at.cmp(&b.installed_at));
    candidates.pop()
}

fn read_manifest(path: &Path) -> anyhow::Result<SkillManifest> {
    let raw = std::fs::read_to_string(path)?;
    let manifest: SkillManifest = serde_json::from_str(&raw)
        .map_err(|e| anyhow::anyhow!("Invalid manifest JSON '{}': {}", path.display(), e))?;
    Ok(manifest)
}

fn registry_path() -> PathBuf {
    skills_root_dir().join("registry.json")
}

fn skills_root_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("LIFEOS_SKILLS_DIR") {
        let path = PathBuf::from(dir);
        if !path.as_os_str().is_empty() {
            return path;
        }
    }

    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("lifeos")
        .join("skills")
}

fn load_registry() -> anyhow::Result<SkillsRegistry> {
    let path = registry_path();
    if !path.exists() {
        return Ok(SkillsRegistry::default());
    }
    let raw = std::fs::read_to_string(&path)?;
    let parsed = serde_json::from_str::<SkillsRegistry>(&raw)
        .map_err(|e| anyhow::anyhow!("Invalid skills registry '{}': {}", path.display(), e))?;
    Ok(parsed)
}

fn save_registry(registry: &SkillsRegistry) -> anyhow::Result<()> {
    let path = registry_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, serde_json::to_string_pretty(registry)?)?;
    Ok(())
}

fn sha256_file(path: &Path) -> anyhow::Result<String> {
    let bytes = std::fs::read(path)?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

fn unique_suffix() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos().to_string())
        .unwrap_or_else(|_| "0".to_string())
}

fn sanitize_tool_name(value: &str) -> String {
    let mut out = String::new();
    for c in value.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if c == '.' || c == '-' || c == '_' {
            out.push('_');
        }
    }
    if out.is_empty() {
        "skill".to_string()
    } else {
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(())).lock().unwrap()
    }

    fn temp_dir(prefix: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("{}-{}", prefix, unique_suffix()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn install_and_verify_skill_manifest() {
        let _guard = env_lock();
        let base = temp_dir("life-skills-install");
        std::env::set_var("LIFEOS_SKILLS_DIR", &base);

        let source = base.join("source");
        std::fs::create_dir_all(&source).unwrap();
        let entrypoint = source.join("run.sh");
        std::fs::write(&entrypoint, "#!/usr/bin/env sh\necho hello\n").unwrap();
        let digest = sha256_file(&entrypoint).unwrap();
        let manifest = serde_json::json!({
            "id": "demo.skill",
            "version": "1.0.0",
            "trust_level": "verified",
            "entrypoint": "run.sh",
            "entrypoint_sha256": digest
        });
        let manifest_path = source.join("skill.json");
        std::fs::write(
            &manifest_path,
            serde_json::to_string_pretty(&manifest).unwrap(),
        )
        .unwrap();

        let installed = install_from_manifest(manifest_path.to_str().unwrap()).unwrap();
        assert_eq!(installed.id, "demo.skill");
        assert_eq!(installed.version, "1.0.0");
        let registry = load_registry().unwrap();
        assert!(registry
            .skills
            .iter()
            .any(|s| s.id == "demo.skill" && s.version == "1.0.0"));

        let manifest = read_manifest(Path::new(&installed.manifest_path)).unwrap();
        verify_skill_integrity(&installed, &manifest).unwrap();

        std::env::remove_var("LIFEOS_SKILLS_DIR");
        std::fs::remove_dir_all(base).ok();
    }

    #[test]
    fn rejects_invalid_checksum_manifest() {
        let manifest = SkillManifest {
            id: "bad.skill".to_string(),
            version: "1.0.0".to_string(),
            trust_level: TrustLevel::Community,
            entrypoint: "run.sh".to_string(),
            entrypoint_sha256: Some("abc".to_string()),
            description: String::new(),
            capabilities: vec![],
        };
        assert!(validate_manifest(&manifest).is_err());
    }

    #[test]
    fn generate_and_sign_skill_scaffold() {
        let base = temp_dir("life-skills-generate");
        let dir = base.to_string_lossy().to_string();

        cmd_generate("gen.skill", "0.2.0", "community", &dir).unwrap();
        let manifest_path = base.join("gen.skill").join("skill.json");
        assert!(manifest_path.exists());

        std::fs::write(
            base.join("gen.skill").join("run.sh"),
            "#!/usr/bin/env sh\necho hi\n",
        )
        .unwrap();
        cmd_sign(manifest_path.to_str().unwrap()).unwrap();
        let manifest = read_manifest(&manifest_path).unwrap();
        assert!(manifest.entrypoint_sha256.is_some());

        std::fs::remove_dir_all(base).ok();
    }

    #[test]
    fn exports_installed_skills_as_mcp_tools() {
        let _guard = env_lock();
        let base = temp_dir("life-skills-mcp-export");
        std::env::set_var("LIFEOS_SKILLS_DIR", &base);

        let source = base.join("source");
        std::fs::create_dir_all(&source).unwrap();
        let entrypoint = source.join("run.sh");
        std::fs::write(&entrypoint, "#!/usr/bin/env sh\necho mcp\n").unwrap();
        let digest = sha256_file(&entrypoint).unwrap();
        let manifest = serde_json::json!({
            "id": "demo.mcp.skill",
            "version": "1.0.0",
            "trust_level": "verified",
            "entrypoint": "run.sh",
            "entrypoint_sha256": digest,
            "description": "MCP test skill"
        });
        let manifest_path = source.join("skill.json");
        std::fs::write(
            &manifest_path,
            serde_json::to_string_pretty(&manifest).unwrap(),
        )
        .unwrap();
        install_from_manifest(manifest_path.to_str().unwrap()).unwrap();

        let output = base.join("tools.json");
        cmd_mcp_export(Some(output.to_str().unwrap()), Some("verified")).unwrap();
        let raw = std::fs::read_to_string(output).unwrap();
        assert!(raw.contains("mcp-tools/v1"));
        assert!(raw.contains("skills.demo_mcp_skill"));

        std::env::remove_var("LIFEOS_SKILLS_DIR");
        std::fs::remove_dir_all(base).ok();
    }
}
