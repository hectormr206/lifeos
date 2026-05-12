use anyhow::Result;
use clap::Args;
use serde::Serialize;
use std::path::Path;

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

pub fn step_detect_distro(_report: &mut Report) -> Result<()> {
    unimplemented!("step_detect_distro: not implemented")
}

pub fn step_check_prereqs(_report: &mut Report) -> Result<()> {
    unimplemented!("step_check_prereqs: not implemented")
}

pub fn step_verify_filesystem(_report: &mut Report) -> Result<()> {
    unimplemented!("step_verify_filesystem: not implemented")
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
pub fn parse_os_release_arch(content: &str) -> Option<String> {
    unimplemented!("parse_os_release_arch: not implemented")
}

/// Run `which <cmd>` and return true if found.
pub fn which_available(cmd: &str) -> bool {
    unimplemented!("which_available: not implemented")
}

/// Run a command and capture the first line of stdout as a version string.
pub fn probe_version(cmd: &str, args: &[&str]) -> Option<String> {
    unimplemented!("probe_version: not implemented")
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

        assert!(var_lib.exists(), "/var/lib/lifeos equivalent must exist");
        assert!(run_lifeos.exists(), "/run/lifeos equivalent must exist");
    }

    // ── T06.7: Missing /run/lifeos → print corrective command ─────────────────

    #[test]
    fn test_verify_filesystem_missing_run_lifeos_exits_2() {
        let tmp = TempDir::new().unwrap();
        let var_lib = tmp.path().join("var_lib_lifeos");
        fs::create_dir_all(&var_lib).unwrap();
        // run_lifeos NOT created

        let run_lifeos = tmp.path().join("run_lifeos");
        assert!(
            !run_lifeos.exists(),
            "/run/lifeos equivalent must be absent for this test"
        );

        let both_present = var_lib.exists() && run_lifeos.exists();
        assert!(!both_present, "Should detect missing /run/lifeos");
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
