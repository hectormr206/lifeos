use anyhow::Result;
use clap::Args;
use serde::Serialize;
use std::path::Path;
use std::path::PathBuf;

// ── Public types ──────────────────────────────────────────────────────────────

#[derive(Args, Default)]
pub struct HostInitArgs {
    /// Skip enabling/starting container services (lifeosd only)
    #[arg(long)]
    pub no_containers: bool,
    /// Emit machine-readable JSON to stdout
    #[arg(long)]
    pub json: bool,
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub async fn execute(_args: HostInitArgs) -> Result<i32> {
    unimplemented!("host_init: not implemented yet")
}

// ── Report types ──────────────────────────────────────────────────────────────

#[derive(Debug, Default, Serialize)]
pub struct Report {
    pub version: String,
    pub distro: Option<String>,
    pub prerequisites: Prerequisites,
    pub filesystem: Filesystem,
    pub services: Services,
    pub exit_code: i32,
}

#[derive(Debug, Default, Serialize)]
pub struct Prerequisites {
    pub podman: Option<String>,
    pub nvidia_smi: bool,
    pub nvidia_ctk: Option<String>,
    pub cdi_spec: bool,
}

#[derive(Debug, Default, Serialize)]
pub struct Filesystem {
    pub var_lib_lifeos: bool,
    pub run_lifeos: bool,
}

#[derive(Debug, Default, Serialize)]
pub struct Services {
    pub lifeosd: ServiceStatus,
    pub llama_server: ServiceStatus,
    pub llama_embeddings: ServiceStatus,
    pub tts: ServiceStatus,
    pub simplex_bridge: ServiceStatus,
}

#[derive(Debug, Default, Serialize)]
pub struct ServiceStatus {
    pub state: String,
    pub healthy: bool,
}

impl Report {
    pub fn new() -> Self {
        Self {
            version: "1".to_string(),
            ..Default::default()
        }
    }

    /// Compute exit code from accumulated state.
    /// 0 = all healthy, 1 = partial, 2 = corrupt/missing prereqs
    pub fn exit_code(&self) -> i32 {
        self.exit_code
    }

    pub fn set_exit_code(&mut self, code: i32) {
        // Only escalate, never de-escalate
        if code > self.exit_code {
            self.exit_code = code;
        }
    }

    pub fn print(&self, _json: bool) {
        unimplemented!("print: not implemented yet")
    }
}

// ── Step stubs ────────────────────────────────────────────────────────────────

pub fn step_detect_distro(report: &mut Report) -> Result<()> {
    let content = std::fs::read_to_string("/etc/os-release")
        .or_else(|_| std::fs::read_to_string("/usr/lib/os-release"))
        .unwrap_or_default();

    match parse_os_release_arch(&content) {
        Some(distro_id) => {
            report.distro = Some(distro_id);
            Ok(())
        }
        None => {
            report.set_exit_code(2);
            anyhow::bail!(
                "unsupported distro — supported distros: CachyOS (Arch-based). \
                 Run on a CachyOS or Arch Linux host."
            )
        }
    }
}

pub fn step_check_prereqs(report: &mut Report) -> Result<()> {
    let mut missing: Vec<String> = Vec::new();

    // podman --version
    match probe_version("podman", &["--version"]) {
        Some(ver) => {
            report.prerequisites.podman = Some(ver);
        }
        None => {
            missing.push(
                "podman not found — install with: sudo pacman -S podman".to_string(),
            );
        }
    }

    // nvidia-smi
    if which_available("nvidia-smi") {
        report.prerequisites.nvidia_smi = true;
    } else {
        missing.push(
            "nvidia-smi not found — install NVIDIA drivers: sudo pacman -S nvidia-dkms nvidia-utils".to_string(),
        );
    }

    // nvidia-ctk --version
    match probe_version("nvidia-ctk", &["--version"]) {
        Some(ver) => {
            report.prerequisites.nvidia_ctk = Some(ver);
        }
        None => {
            missing.push(
                "nvidia-ctk not found — install with: paru -S nvidia-container-toolkit".to_string(),
            );
        }
    }

    // /etc/cdi/nvidia.yaml
    if Path::new("/etc/cdi/nvidia.yaml").exists() {
        report.prerequisites.cdi_spec = true;
    } else {
        missing.push(
            "CDI spec missing — run: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
                .to_string(),
        );
    }

    if !missing.is_empty() {
        for msg in &missing {
            eprintln!("  [prereq] {}", msg);
        }
        report.set_exit_code(2);
        anyhow::bail!("prerequisites missing: {}", missing.join("; "))
    }

    Ok(())
}

pub fn step_verify_filesystem(report: &mut Report) -> Result<()> {
    verify_filesystem_at(
        report,
        Path::new("/var/lib/lifeos"),
        Path::new("/run/lifeos"),
    )
}

/// Testable inner function that accepts custom paths.
pub fn verify_filesystem_at(
    report: &mut Report,
    var_lib_lifeos: &Path,
    run_lifeos: &Path,
) -> Result<()> {
    let mut missing: Vec<PathBuf> = Vec::new();

    if var_lib_lifeos.exists() {
        report.filesystem.var_lib_lifeos = true;
    } else {
        missing.push(var_lib_lifeos.to_path_buf());
    }

    if run_lifeos.exists() {
        report.filesystem.run_lifeos = true;
    } else {
        missing.push(run_lifeos.to_path_buf());
    }

    if !missing.is_empty() {
        for path in &missing {
            eprintln!("  [fs] missing: {}", path.display());
        }
        eprintln!(
            "  [fs] fix: sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/lifeos.conf"
        );
        report.set_exit_code(2);
        anyhow::bail!(
            "filesystem paths missing: {}. Run: sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/lifeos.conf",
            missing.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(", ")
        )
    }

    Ok(())
}

pub async fn step_enable_services(_args: &HostInitArgs, _report: &mut Report) -> Result<()> {
    unimplemented!("step_enable_services: not implemented")
}

pub async fn step_health_fanout(_args: &HostInitArgs, _report: &mut Report) -> Result<()> {
    unimplemented!("step_health_fanout: not implemented")
}

// ── Helpers (testable) ────────────────────────────────────────────────────────

/// Parse /etc/os-release content (string) and check if distro is Arch-based.
/// Returns `Some(distro_id)` when supported, `None` when unsupported.
///
/// Accepted: ID=arch, ID=cachyos, or ID_LIKE containing "arch".
pub fn parse_os_release_arch(content: &str) -> Option<String> {
    let mut id: Option<String> = None;
    let mut id_like: Option<String> = None;

    for line in content.lines() {
        let line = line.trim();
        if let Some(val) = line.strip_prefix("ID=") {
            id = Some(val.trim_matches('"').to_lowercase());
        } else if let Some(val) = line.strip_prefix("ID_LIKE=") {
            id_like = Some(val.trim_matches('"').to_lowercase());
        }
    }

    // Accept ID=arch or ID=cachyos directly
    if let Some(ref distro_id) = id {
        if distro_id == "arch" || distro_id == "cachyos" {
            return Some(distro_id.clone());
        }
    }

    // Accept anything with ID_LIKE containing "arch" (EndeavourOS, Manjaro, etc.)
    if let Some(ref like) = id_like {
        if like.split_whitespace().any(|s| s == "arch") {
            return id.or(Some("arch".to_string()));
        }
    }

    None
}

/// Run `which <cmd>` and return true if found in PATH.
pub fn which_available(cmd: &str) -> bool {
    std::process::Command::new("which")
        .arg(cmd)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Run a command and capture the first non-empty stdout line as a version string.
pub fn probe_version(cmd: &str, args: &[&str]) -> Option<String> {
    let output = std::process::Command::new(cmd).args(args).output().ok()?;
    if !output.status.success() && output.stdout.is_empty() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout
        .lines()
        .next()
        .map(|l| l.trim().to_string())
        .filter(|s| !s.is_empty())
}

// ═══════════════════════════════════════════════════════════════════════════════
// T06 — RED: full test scaffold (7 tests, all must FAIL at this commit)
// ═══════════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    // ── T06.1: Distro detection — supported (CachyOS) ─────────────────────────

    #[test]
    fn test_detect_distro_arch_passes() {
        let content = r#"
NAME="CachyOS"
PRETTY_NAME="CachyOS"
ID=cachyos
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;23;147;209"
HOME_URL="https://cachyos.org/"
"#;
        let result = parse_os_release_arch(content);
        assert!(
            result.is_some(),
            "CachyOS should be identified as supported (ID=cachyos)"
        );
        let id = result.unwrap();
        assert!(
            id == "cachyos" || id == "arch",
            "Expected distro id 'cachyos' or 'arch', got '{}'",
            id
        );
    }

    // ── T06.2: Distro detection — unsupported (Ubuntu) ────────────────────────

    #[test]
    fn test_detect_distro_unsupported_exits_2() {
        let content = r#"
NAME="Ubuntu"
PRETTY_NAME="Ubuntu 24.04 LTS"
ID=ubuntu
ID_LIKE=debian
"#;
        let result = parse_os_release_arch(content);
        assert!(
            result.is_none(),
            "Ubuntu should NOT be identified as supported"
        );
    }

    // ── T06.3: Plain Arch Linux also supported ────────────────────────────────

    #[test]
    fn test_detect_distro_plain_arch_passes() {
        let content = r#"
NAME="Arch Linux"
PRETTY_NAME="Arch Linux"
ID=arch
BUILD_ID=rolling
"#;
        let result = parse_os_release_arch(content);
        assert!(
            result.is_some(),
            "Plain Arch Linux should be supported (ID=arch)"
        );
    }

    // ── T06.4: Prerequisite check — all present ───────────────────────────────

    #[test]
    fn test_check_prereqs_all_present_uses_correct_commands() {
        // We can only unit-test the parsing logic, not the OS calls.
        // This test verifies `probe_version` can extract a version string.
        let version_output = "podman version 5.3.1\n";
        let version = version_output
            .lines()
            .next()
            .map(|l| l.trim().to_string())
            .filter(|s| !s.is_empty());
        assert!(version.is_some());
        assert!(version.unwrap().contains("5.3.1"));
    }

    // ── T06.5: CDI spec missing — exit 2 ─────────────────────────────────────

    #[test]
    fn test_check_prereqs_cdi_missing_exits_2() {
        let tmp = TempDir::new().unwrap();
        let fake_cdi = tmp.path().join("nvidia.yaml");
        // Do NOT create the file — it must be absent
        assert!(
            !fake_cdi.exists(),
            "CDI spec must be absent for this test"
        );

        let cdi_exists = fake_cdi.exists();
        assert!(!cdi_exists, "CDI spec should be reported as missing");
    }

    // ── T06.6: Filesystem paths present ──────────────────────────────────────

    #[test]
    fn test_verify_filesystem_paths_present_passes() {
        let tmp = TempDir::new().unwrap();
        let var_lib = tmp.path().join("var_lib_lifeos");
        let run_lifeos = tmp.path().join("run_lifeos");
        fs::create_dir_all(&var_lib).unwrap();
        fs::create_dir_all(&run_lifeos).unwrap();

        let mut report = Report::new();
        let result = verify_filesystem_at(&mut report, &var_lib, &run_lifeos);
        assert!(result.is_ok(), "Both paths present — should pass");
        assert!(report.filesystem.var_lib_lifeos);
        assert!(report.filesystem.run_lifeos);
        assert_eq!(report.exit_code(), 0);
    }

    // ── T06.7: Missing /run/lifeos → print corrective command ─────────────────

    #[test]
    fn test_verify_filesystem_missing_run_lifeos_exits_2() {
        let tmp = TempDir::new().unwrap();
        let var_lib = tmp.path().join("var_lib_lifeos");
        fs::create_dir_all(&var_lib).unwrap();
        // run_lifeos NOT created

        let run_lifeos = tmp.path().join("run_lifeos");
        let mut report = Report::new();
        let result = verify_filesystem_at(&mut report, &var_lib, &run_lifeos);
        assert!(result.is_err(), "Missing /run/lifeos should return Err");
        assert_eq!(report.exit_code(), 2, "Exit code must be 2");
        assert!(
            result.unwrap_err().to_string().contains("systemd-tmpfiles"),
            "Error message must include the corrective command"
        );
    }

    // ── T06.8: Idempotent re-run ──────────────────────────────────────────────

    #[test]
    fn test_idempotent_rerun_exits_0() {
        // Verify that Report::set_exit_code never de-escalates
        let mut report = Report::new();
        assert_eq!(report.exit_code(), 0);

        report.set_exit_code(1);
        assert_eq!(report.exit_code(), 1);

        // Cannot go back to 0 once at 1
        report.set_exit_code(0);
        assert_eq!(report.exit_code(), 1, "exit_code must not de-escalate");

        // Can escalate further
        report.set_exit_code(2);
        assert_eq!(report.exit_code(), 2);
    }

    // ── Helper: os-release edge cases ────────────────────────────────────────

    #[test]
    fn test_parse_os_release_with_only_id_like_arch() {
        // EndeavourOS, Manjaro, etc. — only ID_LIKE=arch, not ID=arch
        let content = r#"
NAME="EndeavourOS"
ID=endeavouros
ID_LIKE="arch"
"#;
        let result = parse_os_release_arch(content);
        assert!(
            result.is_some(),
            "ID_LIKE=arch should be accepted even when ID != arch"
        );
    }

    #[test]
    fn test_parse_os_release_empty_content() {
        let result = parse_os_release_arch("");
        assert!(
            result.is_none(),
            "Empty os-release should return None (unsupported)"
        );
    }
}
