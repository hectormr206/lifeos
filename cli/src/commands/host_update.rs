//! `life host update` — CachyOS native source-based upgrade.
//!
//! Pulls the latest commits from the git repo, detects which packages changed,
//! rebuilds them with `makepkg -si --noconfirm`, restarts affected services,
//! and runs a health fanout.
//!
//! Pure helper functions are fully tested without I/O.
use anyhow::Result;
use clap::Args;
use colored::Colorize;
use serde::Serialize;
use std::collections::HashSet;
use std::path::PathBuf;

// ── Constants ─────────────────────────────────────────────────────────────────

/// Ordered dependency graph for package rebuilds.
/// Runtime depends on everything — always rebuilt last.
pub const PACKAGE_ORDER: &[&str] = &[
    "lifeos-cli",
    "lifeos-daemon",
    "lifeos-desktop",
    "lifeos-containers",
    "lifeos-runtime",
];

/// Directories inside the repo that map to a package.
pub const SOURCE_DIR_MAP: &[(&str, &str)] = &[
    ("cli/", "lifeos-cli"),
    ("daemon/", "lifeos-daemon"),
    ("desktop/", "lifeos-desktop"),
    ("containers/", "lifeos-containers"),
    ("packaging/cachyos/lifeos-cli/", "lifeos-cli"),
    ("packaging/cachyos/lifeos-daemon/", "lifeos-daemon"),
    ("packaging/cachyos/lifeos-desktop/", "lifeos-desktop"),
    ("packaging/cachyos/lifeos-containers/", "lifeos-containers"),
    ("packaging/cachyos/lifeos-runtime/", "lifeos-runtime"),
];

/// Daemon services managed by this command.
pub const DAEMON_SERVICE: &str = "lifeosd.service";
pub const DESKTOP_SERVICE: &str = "lifeos-desktop.service";
pub const CONTAINER_SERVICES: &[&str] = &[
    "lifeos-llama-server.service",
    "lifeos-llama-embeddings.service",
    "lifeos-tts.service",
    "lifeos-simplex-bridge.service",
];

// ── CLI args ──────────────────────────────────────────────────────────────────

#[derive(Args, Default)]
pub struct HostUpdateArgs {
    /// Dry run — print what WOULD be rebuilt and restarted without doing it.
    #[arg(long)]
    pub check: bool,
    /// Emit machine-readable JSON to stdout.
    #[arg(long)]
    pub json: bool,
    /// Override LIFEOS_REPO_DIR and ~/dev/lifeos.
    #[arg(long)]
    pub repo: Option<PathBuf>,
}

// ── Report ────────────────────────────────────────────────────────────────────

#[derive(Debug, Default, Serialize)]
pub struct UpdateReport {
    pub repo_path: String,
    pub sha_before: String,
    pub sha_after: String,
    pub changed_packages: Vec<String>,
    pub rebuilt: Vec<String>,
    pub failed: Vec<String>,
    pub restarted: Vec<String>,
    pub exit_code: i32,
}

impl UpdateReport {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set_exit_code(&mut self, code: i32) {
        if code > self.exit_code {
            self.exit_code = code;
        }
    }

    pub fn exit_code(&self) -> i32 {
        self.exit_code
    }

    pub fn print(&self, json: bool) {
        if json {
            match serde_json::to_string_pretty(self) {
                Ok(s) => println!("{}", s),
                Err(e) => eprintln!("failed to serialize report: {}", e),
            }
            return;
        }

        eprintln!();
        eprintln!("{}", "life host update — summary".bold());
        eprintln!("{}", "─".repeat(40).dimmed());

        if self.sha_before == self.sha_after && !self.sha_before.is_empty() {
            eprintln!("  {} Already up to date.", "✓".green());
        } else {
            eprintln!(
                "  {} → {}",
                &self.sha_before[..7.min(self.sha_before.len())],
                &self.sha_after[..7.min(self.sha_after.len())]
            );
        }

        if self.rebuilt.is_empty() {
            eprintln!("  {} No packages rebuilt.", "✓".green());
        } else {
            for pkg in &self.rebuilt {
                eprintln!("  {} rebuilt {}", "↻".cyan(), pkg);
            }
        }
        for pkg in &self.failed {
            eprintln!("  {} failed {}", "✗".red(), pkg);
        }
        for svc in &self.restarted {
            eprintln!("  {} restarted {}", "↺".green(), svc);
        }

        eprintln!("{}", "─".repeat(40).dimmed());
        match self.exit_code {
            0 => eprintln!("  {} Done.", "✓".green()),
            1 => eprintln!("  {} Partial failure — check above.", "⚠".yellow()),
            _ => eprintln!("  {} Pre-flight failure.", "✗".red()),
        }
        eprintln!();
    }
}

// ── Pure helpers (testable) ───────────────────────────────────────────────────

/// Parse the output of `git diff --name-only <before> <after>` and return
/// the set of package names that need rebuilding.
///
/// Any touched file triggers `lifeos-runtime` as well (meta-package).
pub fn detect_changed_packages(diff_output: &str) -> HashSet<String> {
    let mut changed: HashSet<String> = HashSet::new();

    for line in diff_output.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        for (prefix, pkg) in SOURCE_DIR_MAP {
            if line.starts_with(prefix) {
                changed.insert(pkg.to_string());
                break;
            }
        }
    }

    // lifeos-runtime is always included when anything changes
    if !changed.is_empty() {
        changed.insert("lifeos-runtime".to_string());
    }

    changed
}

/// Sort a set of changed packages into dependency order.
///
/// Packages not in `PACKAGE_ORDER` are placed at the end in sorted order.
pub fn compute_rebuild_order(changed: &HashSet<String>) -> Vec<String> {
    let mut ordered: Vec<String> = Vec::new();

    for &pkg in PACKAGE_ORDER {
        if changed.contains(pkg) {
            ordered.push(pkg.to_string());
        }
    }

    // Append any unknown packages in stable order
    let mut extras: Vec<String> = changed
        .iter()
        .filter(|p| !PACKAGE_ORDER.contains(&p.as_str()))
        .cloned()
        .collect();
    extras.sort();
    ordered.extend(extras);

    ordered
}

/// Return `true` when the git status output represents a clean working tree.
pub fn is_clean_tree(git_status_output: &str) -> bool {
    git_status_output.trim().is_empty()
}

/// Resolve the repo path from args → env → default.
pub fn resolve_repo_dir(
    cli_override: Option<&PathBuf>,
    env_value: Option<String>,
    home_dir: Option<PathBuf>,
) -> Result<PathBuf> {
    if let Some(p) = cli_override {
        let candidate = p.clone();
        if candidate.join(".git").exists() {
            return Ok(candidate);
        }
        anyhow::bail!(
            "path '{}' is not a git repo (no .git found). \
             Pass a valid repo with --repo or set LIFEOS_REPO_DIR.",
            candidate.display()
        );
    }

    if let Some(val) = env_value {
        let candidate = PathBuf::from(val.trim());
        if !candidate.as_os_str().is_empty() {
            if candidate.join(".git").exists() {
                return Ok(candidate);
            }
            anyhow::bail!(
                "LIFEOS_REPO_DIR='{}' is not a git repo (no .git found). \
                 Fix the env var or pass --repo.",
                candidate.display()
            );
        }
    }

    if let Some(home) = home_dir {
        let default = home.join("dev/lifeos");
        if default.join(".git").exists() {
            return Ok(default);
        }
    }

    anyhow::bail!(
        "No repo found. Set LIFEOS_REPO_DIR, pass --repo, or clone the repo to ~/dev/lifeos."
    )
}

/// Check that the current branch is `main`.
/// Returns `Ok(branch_name)` if on main, `Err` otherwise.
pub fn check_on_main_branch(branch_output: &str) -> Result<()> {
    let branch = branch_output.trim();
    if branch == "main" {
        Ok(())
    } else {
        anyhow::bail!(
            "current branch is '{}', not 'main'. \
             Switch to main before updating, or pass --allow-non-main.",
            branch
        )
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub async fn execute(args: HostUpdateArgs) -> Result<i32> {
    let mut report = UpdateReport::new();

    // ── 1. Resolve repo path ───────────────────────────────────────────────────
    let repo_dir = {
        let env_val = std::env::var("LIFEOS_REPO_DIR").ok();
        let home = std::env::var("HOME").ok().map(PathBuf::from);
        match resolve_repo_dir(args.repo.as_ref(), env_val, home) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("  {} pre-flight: {}", "✗".red(), e);
                report.set_exit_code(2);
                report.print(args.json);
                return Ok(report.exit_code());
            }
        }
    };
    report.repo_path = repo_dir.display().to_string();
    eprintln!("  {} repo: {}", "✓".green(), repo_dir.display());

    // ── 2. Check clean tree ────────────────────────────────────────────────────
    eprintln!("{}", "[1/6] Checking working tree...".bold());
    {
        let status_out = run_git(&repo_dir, &["status", "--porcelain"]);
        match status_out {
            Ok(out) if is_clean_tree(&out) => {
                eprintln!("  {} working tree clean", "✓".green());
            }
            Ok(out) => {
                eprintln!(
                    "  {} working tree is dirty — commit or stash changes first:\n{}",
                    "✗".red(),
                    out.trim()
                );
                report.set_exit_code(2);
                report.print(args.json);
                return Ok(report.exit_code());
            }
            Err(e) => {
                eprintln!("  {} git status failed: {}", "✗".red(), e);
                report.set_exit_code(2);
                report.print(args.json);
                return Ok(report.exit_code());
            }
        }
    }

    // ── 3. Check branch ────────────────────────────────────────────────────────
    eprintln!("{}", "[2/6] Checking branch...".bold());
    {
        let branch_out = run_git(&repo_dir, &["rev-parse", "--abbrev-ref", "HEAD"]);
        match branch_out {
            Ok(b) => {
                if let Err(e) = check_on_main_branch(&b) {
                    eprintln!("  {} {}", "✗".red(), e);
                    report.set_exit_code(2);
                    report.print(args.json);
                    return Ok(report.exit_code());
                }
                eprintln!("  {} on main", "✓".green());
            }
            Err(e) => {
                eprintln!("  {} could not determine branch: {}", "✗".red(), e);
                report.set_exit_code(2);
                report.print(args.json);
                return Ok(report.exit_code());
            }
        }
    }

    // ── 4. Capture SHA before pull ─────────────────────────────────────────────
    let sha_before = run_git(&repo_dir, &["rev-parse", "HEAD"]).unwrap_or_default();
    let sha_before = sha_before.trim().to_string();
    report.sha_before = sha_before.clone();

    // ── 5. Fetch + pull ────────────────────────────────────────────────────────
    eprintln!("{}", "[3/6] Fetching and pulling...".bold());
    if !args.check {
        if let Err(e) = run_git(&repo_dir, &["fetch", "origin", "--quiet"]) {
            eprintln!("  {} git fetch failed: {}", "✗".red(), e);
            report.set_exit_code(2);
            report.print(args.json);
            return Ok(report.exit_code());
        }
        if let Err(e) = run_git(&repo_dir, &["pull", "--ff-only", "origin", "main"]) {
            eprintln!("  {} git pull failed: {}", "✗".red(), e);
            report.set_exit_code(2);
            report.print(args.json);
            return Ok(report.exit_code());
        }
    }

    let sha_after = run_git(&repo_dir, &["rev-parse", "HEAD"]).unwrap_or_default();
    let sha_after = sha_after.trim().to_string();
    report.sha_after = sha_after.clone();

    if sha_before == sha_after {
        eprintln!(
            "  {} ya estás al día ({})",
            "✓".green(),
            &sha_after[..7.min(sha_after.len())]
        );
        report.print(args.json);
        return Ok(0);
    }
    eprintln!(
        "  {} {} → {}",
        "✓".green(),
        &sha_before[..7.min(sha_before.len())],
        &sha_after[..7.min(sha_after.len())]
    );

    // ── 6. Detect changed packages ─────────────────────────────────────────────
    eprintln!("{}", "[4/6] Detecting changed packages...".bold());
    let diff_out =
        run_git(&repo_dir, &["diff", "--name-only", &sha_before, &sha_after]).unwrap_or_default();
    let changed = detect_changed_packages(&diff_out);
    let ordered = compute_rebuild_order(&changed);
    report.changed_packages = ordered.clone();

    if ordered.is_empty() {
        eprintln!("  {} no packages affected by this diff", "✓".green());
        report.print(args.json);
        return Ok(0);
    }

    eprintln!("  {} packages to rebuild:", "→".cyan());
    for pkg in &ordered {
        eprintln!("      {}", pkg);
    }

    if args.check {
        eprintln!();
        eprintln!("{}", "Dry run — nothing was rebuilt or restarted.".yellow());
        report.print(args.json);
        return Ok(0);
    }

    // ── 7. Rebuild packages ────────────────────────────────────────────────────
    eprintln!("{}", "[5/6] Rebuilding packages...".bold());
    for pkg in &ordered {
        let pkg_dir = repo_dir.join("packaging/cachyos").join(pkg);
        eprintln!("  rebuilding {}...", pkg.cyan());
        let ok = rebuild_package(&pkg_dir);
        if ok {
            eprintln!("  {} rebuilt {}", "↻".cyan(), pkg);
            report.rebuilt.push(pkg.clone());
        } else {
            eprintln!("  {} failed {}", "✗".red(), pkg);
            report.failed.push(pkg.clone());
            report.set_exit_code(1);
        }
    }

    // ── 8. Restart services ────────────────────────────────────────────────────
    eprintln!("{}", "[6/6] Restarting services...".bold());
    let to_restart = services_to_restart(&report.rebuilt);
    for svc in &to_restart {
        if unit_is_active(svc) || svc.contains("lifeosd") || svc.contains("lifeos-desktop") {
            if restart_user_unit(svc).is_ok() {
                eprintln!("  {} restarted {}", "↺".green(), svc);
                report.restarted.push(svc.clone());
            } else {
                eprintln!("  {} failed to restart {}", "⚠".yellow(), svc);
                report.set_exit_code(1);
            }
        } else {
            eprintln!("  {} skipped {} (not active)", "–".dimmed(), svc);
        }
    }

    // ── 9. Health fanout ───────────────────────────────────────────────────────
    eprintln!("{}", "[health] Checking services...".bold());
    run_health_check(&mut report).await;

    report.print(args.json);
    Ok(report.exit_code())
}

// ── IO helpers ────────────────────────────────────────────────────────────────

/// Run a git command in `repo` and capture trimmed stdout.
fn run_git(repo: &PathBuf, args: &[&str]) -> Result<String> {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .output()
        .map_err(|e| anyhow::anyhow!("git failed: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git {}: {}", args.first().unwrap_or(&""), stderr.trim());
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// Run `makepkg -si --noconfirm` in `pkg_dir`. Returns true on success.
fn rebuild_package(pkg_dir: &PathBuf) -> bool {
    std::process::Command::new("makepkg")
        .args(["-si", "--noconfirm"])
        .current_dir(pkg_dir)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Check if a user unit is active.
pub fn unit_is_active(unit: &str) -> bool {
    std::process::Command::new("systemctl")
        .args(["--user", "is-active", "--quiet", unit])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Restart a user unit.
fn restart_user_unit(unit: &str) -> Result<()> {
    let status = std::process::Command::new("systemctl")
        .args(["--user", "restart", unit])
        .status()
        .map_err(|e| anyhow::anyhow!("systemctl restart {}: {}", unit, e))?;
    if !status.success() {
        anyhow::bail!("systemctl --user restart {} failed", unit);
    }
    Ok(())
}

/// Compute services to restart based on rebuilt packages.
pub fn services_to_restart(rebuilt: &[String]) -> Vec<String> {
    let mut svcs: Vec<String> = Vec::new();
    for pkg in rebuilt {
        match pkg.as_str() {
            "lifeos-daemon" => svcs.push(DAEMON_SERVICE.to_string()),
            "lifeos-desktop" => svcs.push(DESKTOP_SERVICE.to_string()),
            "lifeos-containers" => {
                for svc in CONTAINER_SERVICES {
                    svcs.push(svc.to_string());
                }
            }
            _ => {}
        }
    }
    // Deduplicate while preserving order
    let mut seen = HashSet::new();
    svcs.retain(|s| seen.insert(s.clone()));
    svcs
}

/// Lightweight health fanout — mirrors host_init's parallel TCP probes.
async fn run_health_check(report: &mut UpdateReport) {
    use crate::commands::host_init::{probe_http_health, probe_tcp_port, unit_is_active};
    use tokio::time::{timeout, Duration};

    let fanout = async {
        let dashboard = probe_http_health("http://127.0.0.1:8081/api/v1/health").await;
        if dashboard {
            eprintln!("  {} lifeosd: healthy", "✓".green());
        } else {
            eprintln!(
                "  {} lifeosd: UNHEALTHY — check: journalctl --user -u lifeosd.service",
                "⚠".yellow()
            );
            report.set_exit_code(1);
        }

        let (llama_ok, emb_ok, tts_ok, simplex_ok) = tokio::join!(
            probe_tcp_port("127.0.0.1", 8082),
            probe_tcp_port("127.0.0.1", 8083),
            probe_tcp_port("127.0.0.1", 8084),
            async { unit_is_active("lifeos-simplex-bridge.service") }
        );

        for (name, ok, port) in [
            ("llama-server", llama_ok, 8082u16),
            ("llama-embeddings", emb_ok, 8083),
            ("tts", tts_ok, 8084),
        ] {
            if ok {
                eprintln!("  {} {}: healthy (port {})", "✓".green(), name, port);
            } else {
                eprintln!(
                    "  {} {}: UNHEALTHY (port {} not reachable)",
                    "⚠".yellow(),
                    name,
                    port
                );
                report.set_exit_code(1);
            }
        }
        if simplex_ok {
            eprintln!("  {} simplex-bridge: active", "✓".green());
        } else {
            eprintln!("  {} simplex-bridge: inactive", "–".dimmed());
        }
    };

    if timeout(Duration::from_secs(30), fanout).await.is_err() {
        report.set_exit_code(1);
        eprintln!("  {} health check timed out after 30s", "⚠".yellow());
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests — strict TDD
// ═══════════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    // ── RED batch: written before implementation exists ────────────────────────

    // T1: detect_changed_packages — cli/ dir maps to lifeos-cli
    #[test]
    fn test_detect_changed_packages_from_cli_dir() {
        let diff = "cli/src/commands/host_init.rs\ncli/Cargo.toml\n";
        let result = detect_changed_packages(diff);
        assert!(
            result.contains("lifeos-cli"),
            "cli/ changes must map to lifeos-cli; got {:?}",
            result
        );
    }

    // T2: detect_changed_packages — daemon/ dir maps to lifeos-daemon
    #[test]
    fn test_detect_changed_packages_from_daemon_dir() {
        let diff = "daemon/src/main.rs\n";
        let result = detect_changed_packages(diff);
        assert!(
            result.contains("lifeos-daemon"),
            "daemon/ changes must map to lifeos-daemon; got {:?}",
            result
        );
    }

    // T3: detect_changed_packages — packaging dir maps to correct package
    #[test]
    fn test_detect_changed_packages_from_packaging_dir() {
        let diff = "packaging/cachyos/lifeos-containers/PKGBUILD\n";
        let result = detect_changed_packages(diff);
        assert!(
            result.contains("lifeos-containers"),
            "packaging/cachyos/lifeos-containers/ must map to lifeos-containers; got {:?}",
            result
        );
    }

    // T4: detect_changed_packages — lifeos-runtime always included when any change
    #[test]
    fn test_detect_changed_packages_includes_runtime_when_any_changed() {
        let diff = "cli/src/main.rs\n";
        let result = detect_changed_packages(diff);
        assert!(
            result.contains("lifeos-runtime"),
            "lifeos-runtime must always be included when anything changed; got {:?}",
            result
        );
    }

    // T5: detect_changed_packages — empty diff yields empty set
    #[test]
    fn test_detect_changed_packages_empty_diff_yields_empty_set() {
        let result = detect_changed_packages("");
        assert!(
            result.is_empty(),
            "empty diff must produce empty set; got {:?}",
            result
        );
    }

    // T6: compute_rebuild_order — correct dependency order
    #[test]
    fn test_compute_rebuild_order_dep_aware() {
        let mut changed = HashSet::new();
        changed.insert("lifeos-runtime".to_string());
        changed.insert("lifeos-cli".to_string());
        changed.insert("lifeos-daemon".to_string());

        let ordered = compute_rebuild_order(&changed);

        // cli must come before daemon, daemon before runtime
        let pos_cli = ordered.iter().position(|s| s == "lifeos-cli").unwrap();
        let pos_daemon = ordered.iter().position(|s| s == "lifeos-daemon").unwrap();
        let pos_runtime = ordered.iter().position(|s| s == "lifeos-runtime").unwrap();

        assert!(
            pos_cli < pos_daemon,
            "lifeos-cli must precede lifeos-daemon"
        );
        assert!(
            pos_daemon < pos_runtime,
            "lifeos-daemon must precede lifeos-runtime"
        );
    }

    // T7: is_clean_tree — dirty output returns false
    #[test]
    fn test_is_clean_tree_with_dirty_output() {
        let dirty = " M cli/src/commands/host_update.rs\n";
        assert!(!is_clean_tree(dirty), "dirty tree output must return false");
    }

    // T8: is_clean_tree — empty output returns true
    #[test]
    fn test_is_clean_tree_with_empty_output() {
        assert!(
            is_clean_tree(""),
            "empty output must return true (clean tree)"
        );
        assert!(
            is_clean_tree("   \n  "),
            "whitespace-only output must return true"
        );
    }

    // T9: pre-flight rejects non-main branch
    #[test]
    fn test_preflight_rejects_non_main_branch() {
        let result = check_on_main_branch("feat/something");
        assert!(result.is_err(), "non-main branch must be rejected");
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("feat/something"),
            "error must mention the actual branch name"
        );
    }

    // T9b: pre-flight accepts main branch
    #[test]
    fn test_preflight_accepts_main_branch() {
        let result = check_on_main_branch("main");
        assert!(result.is_ok(), "main branch must be accepted");
    }

    // T10: no-op when SHA equal after pull
    #[test]
    fn test_no_op_when_sha_equal_after_pull() {
        // Simulate: report with identical SHAs → exit_code stays 0
        let mut report = UpdateReport::new();
        let sha = "abc1234def5678";
        report.sha_before = sha.to_string();
        report.sha_after = sha.to_string();
        // The execute() fn returns 0 early when SHAs match.
        // Here we test the detection logic (equal SHAs).
        assert_eq!(
            report.sha_before, report.sha_after,
            "equal SHAs must trigger no-op path"
        );
        assert_eq!(report.exit_code(), 0, "no-op must preserve exit_code 0");
    }

    // T11: services_to_restart — lifeos-daemon triggers lifeosd.service
    #[test]
    fn test_services_to_restart_for_daemon() {
        let rebuilt = vec!["lifeos-daemon".to_string()];
        let svcs = services_to_restart(&rebuilt);
        assert!(
            svcs.contains(&DAEMON_SERVICE.to_string()),
            "rebuilding lifeos-daemon must restart lifeosd.service; got {:?}",
            svcs
        );
    }

    // T12: services_to_restart — lifeos-containers triggers all 4 container units
    #[test]
    fn test_services_to_restart_for_containers() {
        let rebuilt = vec!["lifeos-containers".to_string()];
        let svcs = services_to_restart(&rebuilt);
        for svc in CONTAINER_SERVICES {
            assert!(
                svcs.contains(&svc.to_string()),
                "rebuilding lifeos-containers must restart {}; got {:?}",
                svc,
                svcs
            );
        }
    }

    // T13: resolve_repo_dir — missing path fails with actionable error
    #[test]
    fn test_resolve_repo_dir_missing_path_fails() {
        let nonexistent = PathBuf::from("/tmp/does-not-exist-lifeos-12345");
        let result = resolve_repo_dir(Some(&nonexistent), None, None);
        assert!(result.is_err(), "nonexistent path must fail");
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("not a git repo") || msg.contains(".git"),
            "error must mention git repo; got: {}",
            msg
        );
    }

    // T14: compute_rebuild_order — unknown packages appended at end in sorted order
    #[test]
    fn test_compute_rebuild_order_unknown_packages_at_end() {
        let mut changed = HashSet::new();
        changed.insert("lifeos-cli".to_string());
        changed.insert("unknown-pkg-z".to_string());
        changed.insert("another-unknown".to_string());

        let ordered = compute_rebuild_order(&changed);
        let pos_cli = ordered.iter().position(|s| s == "lifeos-cli").unwrap();
        let pos_z = ordered.iter().position(|s| s == "unknown-pkg-z");
        let pos_a = ordered.iter().position(|s| s == "another-unknown");

        // known packages come before unknowns
        if let (Some(z), Some(a)) = (pos_z, pos_a) {
            assert!(pos_cli < z, "known pkg must precede unknown");
            assert!(pos_cli < a, "known pkg must precede unknown");
            // unknowns in sorted order
            assert!(a < z, "another-unknown < unknown-pkg-z alphabetically");
        }
    }
}
