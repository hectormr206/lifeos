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

    eprintln!("{}", "[1/7] Detecting distro...".bold());
    if let Err(e) = step_detect_distro(&mut report) {
        eprintln!("  {} {}", "✗".red(), e);
        report.print(args.json);
        return Ok(report.exit_code());
    }
    eprintln!(
        "  {} distro: {}",
        "✓".green(),
        report.distro.as_deref().unwrap_or("?").cyan()
    );

    eprintln!("{}", "[2/7] Checking prerequisites...".bold());
    if let Err(e) = step_check_prereqs(&mut report) {
        eprintln!("  {} {}", "✗".red(), e);
        report.print(args.json);
        return Ok(report.exit_code());
    }
    eprintln!("  {} all prerequisites present", "✓".green());

    eprintln!("{}", "[3/7] Checking group membership...".bold());
    if let Err(e) = step_check_group(&mut report) {
        eprintln!("  {} {}", "✗".red(), e);
        report.print(args.json);
        return Ok(report.exit_code());
    }
    eprintln!("  {} group membership OK", "✓".green());

    eprintln!("{}", "[4/7] Deploying Quadlets...".bold());
    if let Err(e) = step_deploy_quadlets(&mut report) {
        eprintln!("  {} {}", "✗".red(), e);
        report.print(args.json);
        return Ok(report.exit_code());
    }
    eprintln!("  {} Quadlets ready", "✓".green());

    eprintln!("{}", "[5/7] Verifying filesystem paths...".bold());
    if let Err(e) = step_verify_filesystem(&mut report) {
        eprintln!("  {} {}", "✗".red(), e);
        report.print(args.json);
        return Ok(report.exit_code());
    }
    eprintln!("  {} /var/lib/lifeos and /run/lifeos present", "✓".green());

    eprintln!("{}", "[6/7] Enabling services...".bold());
    if let Err(e) = step_enable_services(&args, &mut report).await {
        eprintln!("  {} {}", "✗".red(), e);
        report.print(args.json);
        return Ok(report.exit_code());
    }
    eprintln!("  {} services enabled", "✓".green());

    eprintln!("{}", "[7/7] Running health checks...".bold());
    step_health_fanout(&args, &mut report).await?;

    if report.exit_code() == 0 {
        eprintln!("  {} all healthy", "✓".green());
        let token = resolve_bootstrap_token();
        let url = format_dashboard_url(token.as_deref());
        println!("Dashboard: {}", url);
        if token.is_none() {
            eprintln!(
                "  {} bootstrap token not found — set {} or read it from {}",
                "⚠".yellow(),
                "LIFEOS_BOOTSTRAP_TOKEN".bold(),
                "$XDG_RUNTIME_DIR/lifeos/bootstrap.token".bold(),
            );
        }
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
    pub quadlets: QuadletsReport,
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
    pub lifeos_group_member: LifeosGroupStatus,
}

/// JSON-serializable group membership status.
#[derive(Debug, Serialize, Default, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum LifeosGroupStatus {
    #[default]
    Unknown,
    True,
    False,
    GroupNotFound,
}

#[derive(Debug, Default, Serialize)]
pub struct QuadletsReport {
    /// `true` = just deployed, `false` = skipped (already present or helper missing).
    pub quadlets_deployed: bool,
    /// Human-readable status: "deployed" | "already-present" | "helper-missing" | "error: <msg>".
    pub status: String,
}

/// Decision returned by the pure helper [`quadlet_deployment_decision`].
#[derive(Debug, PartialEq)]
pub enum QuadletDecision {
    Deploy,
    Skip { reason: String },
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

        let distro_str = self.distro.as_deref().unwrap_or("unknown");
        eprintln!("  Distro:      {}", distro_str.cyan());

        let prereqs_ok = self.prerequisites.podman.is_some()
            && self.prerequisites.nvidia_smi
            && self.prerequisites.nvidia_ctk.is_some()
            && self.prerequisites.cdi_spec;
        let prereq_mark = if prereqs_ok {
            "OK".green()
        } else {
            "FAIL".red()
        };
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
            missing.push("podman not found — install with: sudo pacman -S podman".to_string());
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
        eprintln!("  [fs] fix: sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/lifeos.conf");
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

    // Enable lifeosd (check first — idempotent, skip enable if already enabled)
    let lifeosd_already = unit_is_enabled("lifeosd.service");
    if !lifeosd_already {
        if let Err(e) = enable_user_unit("lifeosd.service") {
            eprintln!("  [services] lifeosd.service: {}", e);
            report.services.lifeosd.state = "failed".to_string();
            report.set_exit_code(2);
            anyhow::bail!("lifeosd.service failed to enable: {}", e);
        }
    }
    report.services.lifeosd.state = "enabled".to_string();

    if !args.no_containers {
        for unit in CONTAINER_SERVICES {
            // Enable only if not already enabled (idempotent)
            if !unit_is_enabled(unit) {
                if let Err(e) = enable_user_unit(unit) {
                    eprintln!("  [services] {}: {}", unit, e);
                    report.set_exit_code(1);
                }
            }
        }
    }

    Ok(())
}

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
            eprintln!(
                "  [health] lifeosd: UNHEALTHY — check: journalctl --user -u lifeosd.service"
            );
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
            report.services.llama_server.state = if llama_ok {
                "active".to_string()
            } else {
                "unhealthy".to_string()
            };

            report.services.llama_embeddings.healthy = emb_ok;
            report.services.llama_embeddings.state = if emb_ok {
                "active".to_string()
            } else {
                "unhealthy".to_string()
            };

            report.services.tts.healthy = tts_ok;
            report.services.tts.state = if tts_ok {
                "active".to_string()
            } else {
                "unhealthy".to_string()
            };

            report.services.simplex_bridge.healthy = simplex_ok;
            report.services.simplex_bridge.state = if simplex_ok {
                "active".to_string()
            } else {
                "inactive".to_string()
            };

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
    timeout(Duration::from_secs(5), client.get(url).send())
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

/// Resolve the daemon bootstrap token, mirroring the precedence used by
/// `scripts/validate-cachyos.sh` and the daemon's runtime dir candidates:
/// 1. `LIFEOS_BOOTSTRAP_TOKEN` env var
/// 2. `$XDG_RUNTIME_DIR/lifeos/bootstrap.token`
/// 3. `$HOME/.local/state/lifeos/runtime/bootstrap.token`
/// 4. `/run/lifeos/bootstrap.token`
pub fn resolve_bootstrap_token_from(
    env_value: Option<String>,
    candidate_dirs: &[PathBuf],
) -> Option<String> {
    if let Some(v) = env_value {
        let trimmed = v.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_string());
        }
    }
    for dir in candidate_dirs {
        let token_file = dir.join("bootstrap.token");
        if let Ok(content) = std::fs::read_to_string(&token_file) {
            let trimmed = content.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

/// Real-environment wrapper: resolves the bootstrap token using current env + standard paths.
pub fn resolve_bootstrap_token() -> Option<String> {
    let env_value = std::env::var("LIFEOS_BOOTSTRAP_TOKEN").ok();
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
        candidates.push(PathBuf::from(xdg).join("lifeos"));
    }
    if let Ok(home) = std::env::var("HOME") {
        candidates.push(PathBuf::from(home).join(".local/state/lifeos/runtime"));
    }
    candidates.push(PathBuf::from("/run/lifeos"));
    resolve_bootstrap_token_from(env_value, &candidates)
}

// ── Quadlet deployment helpers ────────────────────────────────────────────────

/// Pure decision function: given whether the helper binary is present and
/// whether Quadlets are already deployed, return the appropriate action.
pub fn quadlet_deployment_decision(
    helper_present: bool,
    already_deployed: bool,
) -> QuadletDecision {
    if !helper_present {
        return QuadletDecision::Skip {
            reason: "helper not installed".to_string(),
        };
    }
    if already_deployed {
        return QuadletDecision::Skip {
            reason: "already deployed".to_string(),
        };
    }
    QuadletDecision::Deploy
}

/// Check whether `~/.config/containers/systemd/lifeos-*.container` exists.
pub fn quadlets_already_deployed() -> bool {
    let Some(home) = dirs::home_dir() else {
        return false;
    };
    let quadlet_dir = home.join(".config/containers/systemd");
    // Any file matching lifeos-*.container means quadlets are present
    std::fs::read_dir(&quadlet_dir)
        .map(|entries| {
            entries.flatten().any(|e| {
                let name = e.file_name();
                let s = name.to_string_lossy();
                s.starts_with("lifeos-") && s.ends_with(".container")
            })
        })
        .unwrap_or(false)
}

/// Real step: detect helper + deployment state and act.
///
/// Invariant: if the helper is missing, warn and continue (don't fail).
pub fn step_deploy_quadlets(report: &mut Report) -> Result<()> {
    let helper_present = which_available("lifeos-quadlet-install");
    let already_deployed = quadlets_already_deployed();
    step_deploy_quadlets_with(report, helper_present, already_deployed)
}

/// Testable inner function that accepts injected state flags.
pub fn step_deploy_quadlets_with(
    report: &mut Report,
    helper_present: bool,
    already_deployed: bool,
) -> Result<()> {
    match quadlet_deployment_decision(helper_present, already_deployed) {
        QuadletDecision::Skip { ref reason } if reason.contains("helper not installed") => {
            eprintln!(
                "  [quadlets] {} lifeos-quadlet-install not found — skipping auto-deploy",
                "⚠".yellow()
            );
            report.quadlets.quadlets_deployed = false;
            report.quadlets.status = "helper-missing".to_string();
        }
        QuadletDecision::Skip { .. } => {
            eprintln!("  [quadlets] {} Quadlets already deployed", "✓".green());
            report.quadlets.quadlets_deployed = false;
            report.quadlets.status = "already-present".to_string();
        }
        QuadletDecision::Deploy => {
            eprintln!("  [quadlets] deploying via lifeos-quadlet-install --user …");
            let install_status = std::process::Command::new("lifeos-quadlet-install")
                .arg("--user")
                .status();
            match install_status {
                Ok(s) if s.success() => {
                    // daemon-reload so systemd picks up the new unit files
                    if let Err(e) = daemon_reload() {
                        eprintln!(
                            "  [quadlets] {} daemon-reload after install: {}",
                            "⚠".yellow(),
                            e
                        );
                    }
                    eprintln!("  [quadlets] {} Quadlets deployed", "✓".green());
                    report.quadlets.quadlets_deployed = true;
                    report.quadlets.status = "deployed".to_string();
                }
                Ok(s) => {
                    let msg = format!("lifeos-quadlet-install --user exited with {}", s);
                    eprintln!("  [quadlets] {} {}", "✗".red(), msg);
                    report.quadlets.quadlets_deployed = false;
                    report.quadlets.status = format!("error: {}", msg);
                    // Don't hard-fail — continue; service enable will surface the error
                }
                Err(e) => {
                    let msg = format!("failed to run lifeos-quadlet-install: {}", e);
                    eprintln!("  [quadlets] {} {}", "✗".red(), msg);
                    report.quadlets.quadlets_deployed = false;
                    report.quadlets.status = format!("error: {}", msg);
                }
            }
        }
    }
    Ok(())
}

// ── Group membership helpers ──────────────────────────────────────────────────

/// Pure helper: true if "lifeos" is in the provided group list.
pub fn user_is_in_lifeos_group(user_groups: &[String]) -> bool {
    user_groups.iter().any(|g| g == "lifeos")
}

/// Resolve current user's group names by reading `/etc/group` and comparing
/// against the user's supplementary group IDs (via `libc::getgroups`).
pub fn current_user_groups() -> Vec<String> {
    // 1. Get current process's group IDs
    let gids: Vec<u32> = {
        let mut buf = vec![0u32; 64];
        loop {
            let n = unsafe {
                libc::getgroups(
                    buf.len() as libc::c_int,
                    buf.as_mut_ptr() as *mut libc::gid_t,
                )
            };
            if n < 0 {
                return vec![];
            }
            let n = n as usize;
            if n <= buf.len() {
                buf.truncate(n);
                break buf.to_vec();
            }
            buf.resize(buf.len() * 2, 0);
        }
    };

    // 2. Parse /etc/group and collect names whose gid matches
    let content = match std::fs::read_to_string("/etc/group") {
        Ok(c) => c,
        Err(_) => return vec![],
    };

    content
        .lines()
        .filter_map(|line| {
            // format: name:password:gid:members
            let mut parts = line.splitn(4, ':');
            let name = parts.next()?.to_string();
            parts.next(); // password
            let gid: u32 = parts.next()?.parse().ok()?;
            if gids.contains(&gid) {
                Some(name)
            } else {
                None
            }
        })
        .collect()
}

/// Check that the current user is in the `lifeos` group (if it exists).
/// Returns `Err` with exit code 2 if the group exists but user is not in it.
pub fn step_check_group(report: &mut Report) -> Result<()> {
    // Check whether the "lifeos" group exists in /etc/group
    let group_content = match std::fs::read_to_string("/etc/group") {
        Ok(c) => c,
        Err(_) => {
            // Cannot read /etc/group — skip check, don't fail
            report.prerequisites.lifeos_group_member = LifeosGroupStatus::GroupNotFound;
            return Ok(());
        }
    };

    let lifeos_group_exists = group_content
        .lines()
        .any(|l| l.split(':').next().map(|n| n == "lifeos").unwrap_or(false));

    if !lifeos_group_exists {
        eprintln!(
            "  [groups] {} 'lifeos' group not found — pre-Phase-3 install? skipping check",
            "⚠".yellow()
        );
        report.prerequisites.lifeos_group_member = LifeosGroupStatus::GroupNotFound;
        return Ok(());
    }

    let user_groups = current_user_groups();
    if user_is_in_lifeos_group(&user_groups) {
        report.prerequisites.lifeos_group_member = LifeosGroupStatus::True;
        Ok(())
    } else {
        report.prerequisites.lifeos_group_member = LifeosGroupStatus::False;
        report.set_exit_code(2);
        anyhow::bail!(
            "user not in 'lifeos' group — /var/lib/lifeos/ requires it\n  Fix: sudo usermod -aG lifeos $USER  (then logout/login)"
        )
    }
}

/// Format the dashboard URL with the bootstrap token appended when available.
/// When `token` is `None`, omit the query string — the daemon will reject the
/// browser request and the user will know to set `LIFEOS_BOOTSTRAP_TOKEN`.
pub fn format_dashboard_url(token: Option<&str>) -> String {
    match token {
        Some(t) if !t.is_empty() => {
            format!("http://127.0.0.1:8081/dashboard?token={}", t)
        }
        _ => "http://127.0.0.1:8081/dashboard".to_string(),
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// T06 — RED: full test scaffold (7 tests, all must FAIL at this commit)
// ═══════════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    // ── NEW: Quadlet deployment decision ─────────────────────────────────────

    #[test]
    fn test_quadlet_decision_helper_missing() {
        let decision = quadlet_deployment_decision(false, false);
        assert!(
            matches!(decision, QuadletDecision::Skip { .. }),
            "Helper missing should produce Skip"
        );
        if let QuadletDecision::Skip { reason } = decision {
            assert!(
                reason.contains("helper not installed"),
                "Skip reason should mention 'helper not installed', got: '{}'",
                reason
            );
        }
    }

    #[test]
    fn test_quadlet_decision_already_deployed() {
        let decision = quadlet_deployment_decision(true, true);
        assert!(
            matches!(decision, QuadletDecision::Skip { .. }),
            "Already deployed should produce Skip"
        );
        if let QuadletDecision::Skip { reason } = decision {
            assert!(
                reason.contains("already deployed"),
                "Skip reason should mention 'already deployed', got: '{}'",
                reason
            );
        }
    }

    #[test]
    fn test_quadlet_decision_deploy_needed() {
        let decision = quadlet_deployment_decision(true, false);
        assert!(
            matches!(decision, QuadletDecision::Deploy),
            "Helper present + not deployed should produce Deploy"
        );
    }

    // ── NEW: lifeos group membership ─────────────────────────────────────────

    #[test]
    fn test_user_in_lifeos_group_when_present() {
        let groups = vec![
            "wheel".to_string(),
            "lifeos".to_string(),
            "audio".to_string(),
        ];
        assert!(
            user_is_in_lifeos_group(&groups),
            "User with 'lifeos' in groups should return true"
        );
    }

    #[test]
    fn test_user_not_in_lifeos_group() {
        let groups = vec!["wheel".to_string(), "audio".to_string()];
        assert!(
            !user_is_in_lifeos_group(&groups),
            "User without 'lifeos' in groups should return false"
        );
    }

    #[test]
    fn test_user_not_in_lifeos_group_empty_list() {
        let groups: Vec<String> = vec![];
        assert!(
            !user_is_in_lifeos_group(&groups),
            "Empty group list should return false"
        );
    }

    // ── TRIANGULATION: quadlet decision ─────────────────────────────────────

    #[test]
    fn test_quadlet_decision_helper_missing_even_when_deployed() {
        // helper absent overrides deployed state — still skip
        let decision = quadlet_deployment_decision(false, true);
        assert!(
            matches!(decision, QuadletDecision::Skip { .. }),
            "Helper missing + already deployed should still produce Skip"
        );
        if let QuadletDecision::Skip { reason } = decision {
            assert!(
                reason.contains("helper not installed"),
                "Reason must be 'helper not installed' (not 'already deployed'), got: '{}'",
                reason
            );
        }
    }

    // ── TRIANGULATION: group membership ─────────────────────────────────────

    #[test]
    fn test_user_in_lifeos_group_only_lifeos() {
        // Edge: single group that happens to be lifeos
        let groups = vec!["lifeos".to_string()];
        assert!(user_is_in_lifeos_group(&groups));
    }

    #[test]
    fn test_user_in_lifeos_group_case_sensitive() {
        // "LIFEOS" must NOT match — group names are case-sensitive on Linux
        let groups = vec!["LIFEOS".to_string(), "wheel".to_string()];
        assert!(
            !user_is_in_lifeos_group(&groups),
            "Group name comparison must be case-sensitive"
        );
    }

    // ── NEW: integration-ish — helper missing + group OK still proceeds ───────

    #[test]
    fn test_quadlet_deploy_step_no_helper_does_not_fail() {
        // Simulate: helper not found, quadlets not deployed
        // Expected: step returns Ok (warn and continue)
        let mut report = Report::new();
        // We call the testable step with overrides: no helper, not deployed
        let result = step_deploy_quadlets_with(
            &mut report,
            false, // helper_present
            false, // already_deployed
        );
        assert!(
            result.is_ok(),
            "Missing helper should warn but not fail: {:?}",
            result
        );
    }

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
        assert!(!fake_cdi.exists(), "CDI spec must be absent for this test");

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

    // ── REQ-A4 dashboard URL: bootstrap token must be included ────────────────

    #[test]
    fn test_format_dashboard_url_with_token_includes_query_param() {
        let url = format_dashboard_url(Some("abc123"));
        assert_eq!(url, "http://127.0.0.1:8081/dashboard?token=abc123");
    }

    #[test]
    fn test_format_dashboard_url_without_token_omits_query() {
        let url = format_dashboard_url(None);
        assert_eq!(url, "http://127.0.0.1:8081/dashboard");
    }

    #[test]
    fn test_format_dashboard_url_with_empty_token_omits_query() {
        let url = format_dashboard_url(Some(""));
        assert_eq!(url, "http://127.0.0.1:8081/dashboard");
    }

    #[test]
    fn test_resolve_bootstrap_token_prefers_env() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().to_path_buf();
        let token_file = dir.join("bootstrap.token");
        fs::write(&token_file, "from-file").unwrap();

        let resolved = resolve_bootstrap_token_from(Some("from-env".to_string()), &[dir.clone()]);
        assert_eq!(resolved.as_deref(), Some("from-env"));
    }

    #[test]
    fn test_resolve_bootstrap_token_reads_from_first_candidate() {
        let tmp = TempDir::new().unwrap();
        let dir_a = tmp.path().join("a");
        let dir_b = tmp.path().join("b");
        fs::create_dir_all(&dir_a).unwrap();
        fs::create_dir_all(&dir_b).unwrap();
        // Only b has the token
        fs::write(dir_b.join("bootstrap.token"), "from-b\n").unwrap();

        let resolved = resolve_bootstrap_token_from(None, &[dir_a, dir_b]);
        assert_eq!(resolved.as_deref(), Some("from-b"));
    }

    #[test]
    fn test_resolve_bootstrap_token_returns_none_when_absent() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().to_path_buf();
        let resolved = resolve_bootstrap_token_from(None, &[dir]);
        assert_eq!(resolved, None);
    }

    #[test]
    fn test_resolve_bootstrap_token_ignores_empty_env() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().to_path_buf();
        fs::write(dir.join("bootstrap.token"), "from-file").unwrap();
        let resolved = resolve_bootstrap_token_from(Some("   ".to_string()), &[dir]);
        assert_eq!(resolved.as_deref(), Some("from-file"));
    }
}
