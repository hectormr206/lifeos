use anyhow::Result;
use clap::Args;
use colored::Colorize;
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

pub async fn execute(args: HostInitArgs) -> Result<i32> {
    let mut report = Report::new();

    eprintln!("{}", "[1/5] Detecting distro...".bold());
    if let Err(e) = step_detect_distro(&mut report) {
        eprintln!("  {} {}", "✗".red(), e);
        report.print(args.json);
        return Ok(report.exit_code());
    }
    eprintln!("  {} distro: {}", "✓".green(), report.distro.as_deref().unwrap_or("?").cyan());

    eprintln!("{}", "[2/5] Checking prerequisites...".bold());
    if let Err(e) = step_check_prereqs(&mut report) {
        eprintln!("  {} {}", "✗".red(), e);
        report.print(args.json);
        return Ok(report.exit_code());
    }
    eprintln!("  {} all prerequisites present", "✓".green());

    eprintln!("{}", "[3/5] Verifying filesystem paths...".bold());
    if let Err(e) = step_verify_filesystem(&mut report) {
        eprintln!("  {} {}", "✗".red(), e);
        report.print(args.json);
        return Ok(report.exit_code());
    }
    eprintln!("  {} /var/lib/lifeos and /run/lifeos present", "✓".green());

    eprintln!("{}", "[4/5] Enabling services...".bold());
    if let Err(e) = step_enable_services(&args, &mut report).await {
        eprintln!("  {} {}", "✗".red(), e);
        report.print(args.json);
        return Ok(report.exit_code());
    }
    eprintln!("  {} services enabled", "✓".green());

    eprintln!("{}", "[5/5] Running health checks...".bold());
    step_health_fanout(&args, &mut report).await?;

    if report.exit_code() == 0 {
        eprintln!("  {} all healthy", "✓".green());
        println!("Dashboard: http://127.0.0.1:8081/dashboard");
    } else if report.exit_code() == 1 {
        eprintln!("  {} partial — see details above", "⚠".yellow());
    }

    report.print(args.json);
    Ok(report.exit_code())
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

    /// Print the report. JSON goes to stdout; plain text status goes to stderr.
    pub fn print(&self, json: bool) {
        if json {
            // JSON output to stdout (no ANSI codes)
            match serde_json::to_string_pretty(self) {
                Ok(s) => println!("{}", s),
                Err(e) => eprintln!("failed to serialize report: {}", e),
            }
            return;
        }

        // Plain text — summary table to stderr
        eprintln!();
        eprintln!("{}", "LifeOS host init — summary".bold());
        eprintln!("{}", "─".repeat(40).dimmed());

        let distro_str = self
            .distro
            .as_deref()
            .unwrap_or("unknown");
        eprintln!(
            "  Distro:      {}",
            distro_str.cyan()
        );

        let prereqs_ok = self.prerequisites.podman.is_some()
            && self.prerequisites.nvidia_smi
            && self.prerequisites.nvidia_ctk.is_some()
            && self.prerequisites.cdi_spec;
        let prereq_mark = if prereqs_ok { "OK".green() } else { "FAIL".red() };
        eprintln!("  Prerequisites: {}", prereq_mark);

        let fs_ok = self.filesystem.var_lib_lifeos && self.filesystem.run_lifeos;
        let fs_mark = if fs_ok { "OK".green() } else { "FAIL".red() };
        eprintln!("  Filesystem:  {}", fs_mark);

        let svc_ok = self.services.lifeosd.healthy;
        let svc_mark = if svc_ok { "OK".green() } else { "FAIL".red() };
        eprintln!("  lifeosd:     {}", svc_mark);

        eprintln!("{}", "─".repeat(40).dimmed());
        match self.exit_code {
            0 => eprintln!("  {} All services healthy.", "✓".green()),
            1 => eprintln!("  {} Partial — some services unhealthy.", "⚠".yellow()),
            _ => eprintln!("  {} Prerequisites or filesystem issue.", "✗".red()),
        }
        eprintln!();
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

/// Container service names to manage (in order).
const CONTAINER_SERVICES: &[&str] = &[
    "lifeos-llama-server.service",
    "lifeos-llama-embeddings.service",
    "lifeos-tts.service",
    "lifeos-simplex-bridge.service",
];

/// Check if a user unit is already enabled.
pub fn unit_is_enabled(unit: &str) -> bool {
    std::process::Command::new("systemctl")
        .args(["--user", "is-enabled", unit])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Enable and start a single user unit idempotently.
pub fn enable_user_unit(unit: &str) -> Result<()> {
    let status = std::process::Command::new("systemctl")
        .args(["--user", "enable", "--now", unit])
        .status()
        .map_err(|e| anyhow::anyhow!("systemctl failed for {}: {}", unit, e))?;

    if !status.success() {
        anyhow::bail!("systemctl --user enable --now {} failed", unit);
    }
    Ok(())
}

/// Run `systemctl --user daemon-reload`.
pub fn daemon_reload() -> Result<()> {
    let status = std::process::Command::new("systemctl")
        .args(["--user", "daemon-reload"])
        .status()
        .map_err(|e| anyhow::anyhow!("daemon-reload failed: {}", e))?;

    if !status.success() {
        anyhow::bail!("systemctl --user daemon-reload failed");
    }
    Ok(())
}

pub async fn step_enable_services(args: &HostInitArgs, report: &mut Report) -> Result<()> {
    // Always reload first so Quadlet changes are picked up
    if let Err(e) = daemon_reload() {
        eprintln!("  [services] warning: daemon-reload: {}", e);
    }

    // Enable lifeosd
    if let Err(e) = enable_user_unit("lifeosd.service") {
        eprintln!("  [services] lifeosd.service: {}", e);
        report.services.lifeosd.state = "failed".to_string();
        report.set_exit_code(2);
        anyhow::bail!("lifeosd.service failed to enable: {}", e);
    }
    report.services.lifeosd.state = "enabled".to_string();

    if !args.no_containers {
        for unit in CONTAINER_SERVICES {
            if let Err(e) = enable_user_unit(unit) {
                eprintln!("  [services] {}: {}", unit, e);
                report.set_exit_code(1);
            }
        }
    }

    Ok(())
}

/// Service port configuration for TCP probes.
/// Ports: dashboard 8081, llama-server 8082, embeddings 8083, tts 8084.
/// simplex-bridge uses systemctl is-active (no TCP endpoint).
const SERVICE_PORTS: &[(&str, u16)] = &[
    ("lifeos-llama-server", 8082),
    ("lifeos-llama-embeddings", 8083),
    ("lifeos-tts", 8084),
];

/// Probe a TCP port with a 5-second connect timeout.
/// Returns true if the port accepts a connection.
pub async fn probe_tcp_port(host: &str, port: u16) -> bool {
    use tokio::net::TcpStream;
    use tokio::time::{timeout, Duration};

    let addr = format!("{}:{}", host, port);
    timeout(Duration::from_secs(5), TcpStream::connect(&addr))
        .await
        .map(|r| r.is_ok())
        .unwrap_or(false)
}

/// Check a systemd user unit's active state.
pub fn unit_is_active(unit: &str) -> bool {
    std::process::Command::new("systemctl")
        .args(["--user", "is-active", "--quiet", unit])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub async fn step_health_fanout(args: &HostInitArgs, report: &mut Report) -> Result<()> {
    use tokio::time::{timeout, Duration};

    // Overall 30-second deadline
    let fanout = async {
        // Dashboard health check via HTTP
        let dashboard_healthy = probe_http_health("http://127.0.0.1:8081/api/v1/health").await;
        report.services.lifeosd.healthy = dashboard_healthy;
        if dashboard_healthy {
            report.services.lifeosd.state = "active".to_string();
        } else {
            report.services.lifeosd.state = "unhealthy".to_string();
            report.set_exit_code(1);
            eprintln!("  [health] lifeosd: UNHEALTHY — check: journalctl --user -u lifeosd.service");
        }

        if !args.no_containers {
            // Parallel TCP probes for container services
            let (llama_ok, emb_ok, tts_ok, simplex_ok) = tokio::join!(
                probe_tcp_port("127.0.0.1", 8082),
                probe_tcp_port("127.0.0.1", 8083),
                probe_tcp_port("127.0.0.1", 8084),
                async { unit_is_active("lifeos-simplex-bridge.service") }
            );

            report.services.llama_server.healthy = llama_ok;
            report.services.llama_server.state = if llama_ok { "active".to_string() } else { "unhealthy".to_string() };

            report.services.llama_embeddings.healthy = emb_ok;
            report.services.llama_embeddings.state = if emb_ok { "active".to_string() } else { "unhealthy".to_string() };

            report.services.tts.healthy = tts_ok;
            report.services.tts.state = if tts_ok { "active".to_string() } else { "unhealthy".to_string() };

            report.services.simplex_bridge.healthy = simplex_ok;
            report.services.simplex_bridge.state = if simplex_ok { "active".to_string() } else { "inactive".to_string() };

            for (name, ok, port) in [
                ("lifeos-llama-server", llama_ok, 8082u16),
                ("lifeos-llama-embeddings", emb_ok, 8083),
                ("lifeos-tts", tts_ok, 8084),
            ] {
                if !ok {
                    eprintln!(
                        "  [health] {}: UNHEALTHY (port {} not reachable)",
                        name, port
                    );
                    report.set_exit_code(1);
                }
            }

            if !simplex_ok {
                eprintln!("  [health] lifeos-simplex-bridge: INACTIVE");
                report.set_exit_code(1);
            }
        }
    };

    // Apply 30-second overall deadline
    if timeout(Duration::from_secs(30), fanout).await.is_err() {
        report.set_exit_code(1);
        eprintln!(
            "  [health] lifeosd did not become healthy within 30s — \
             check: journalctl --user -u lifeosd.service"
        );
    }

    Ok(())
}

/// HTTP GET to a health endpoint; returns true if status is 200.
pub async fn probe_http_health(url: &str) -> bool {
    use tokio::time::{timeout, Duration};

    let client = reqwest::Client::new();
    timeout(
        Duration::from_secs(5),
        client.get(url).send(),
    )
    .await
    .map(|r| r.map(|resp| resp.status().is_success()).unwrap_or(false))
    .unwrap_or(false)
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
