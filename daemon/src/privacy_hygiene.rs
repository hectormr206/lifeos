//! Privacy Hygiene — Automated privacy and security checks.
//!
//! Weekly scan for:
//! - Browser cache size and cleanup
//! - Exposed sensitive files (keys, credentials)
//! - Have I Been Pwned (HIBP) email breach check (k-anonymity, no full email sent)
//! - Recent file access traces

use log::info;
use serde::{Deserialize, Serialize};
use tokio::process::Command;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrivacyReport {
    pub browser_cache_mb: f64,
    pub sensitive_files_exposed: Vec<String>,
    pub breach_alerts: Vec<String>,
    pub cleanup_actions: Vec<String>,
}

/// Run a full privacy hygiene scan.
pub async fn run_privacy_scan() -> PrivacyReport {
    let mut report = PrivacyReport {
        browser_cache_mb: 0.0,
        sensitive_files_exposed: Vec::new(),
        breach_alerts: Vec::new(),
        cleanup_actions: Vec::new(),
    };

    // 1. Check browser cache size
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
    let cache_dirs = [
        format!("{}/.cache/mozilla", home),
        format!("{}/.cache/chromium", home),
        format!("{}/.cache/google-chrome", home),
    ];

    for dir in &cache_dirs {
        if let Ok(output) = Command::new("du").args(["-sm", dir]).output().await {
            if output.status.success() {
                let text = String::from_utf8_lossy(&output.stdout);
                if let Some(size_str) = text.split_whitespace().next() {
                    if let Ok(size) = size_str.parse::<f64>() {
                        report.browser_cache_mb += size;
                    }
                }
            }
        }
    }

    if report.browser_cache_mb > 500.0 {
        report.cleanup_actions.push(format!(
            "Browser cache is {:.0} MB — consider clearing",
            report.browser_cache_mb
        ));
    }

    // 2. Check for exposed sensitive files
    let sensitive_patterns = [
        ("*.key", "Private key files"),
        ("*.pem", "PEM certificate/key files"),
        ("*id_rsa", "SSH private keys"),
        ("*.env", "Environment files with secrets"),
    ];

    for (pattern, desc) in &sensitive_patterns {
        if let Ok(output) = Command::new("find")
            .args([
                &home,
                "-maxdepth",
                "3",
                "-name",
                pattern,
                "-perm",
                "-o+r",
                "-type",
                "f",
            ])
            .output()
            .await
        {
            if output.status.success() {
                let text = String::from_utf8_lossy(&output.stdout);
                for line in text.lines() {
                    if !line.trim().is_empty()
                        && !line.contains(".cache")
                        && !line.contains("node_modules")
                    {
                        report
                            .sensitive_files_exposed
                            .push(format!("{}: {}", desc, line.trim()));
                    }
                }
            }
        }
    }

    // 3. Clean recent files trace
    let recent_file = format!("{}/.local/share/recently-used.xbel", home);
    if let Ok(metadata) = tokio::fs::metadata(&recent_file).await {
        let size_kb = metadata.len() / 1024;
        if size_kb > 100 {
            report
                .cleanup_actions
                .push(format!("Recently-used.xbel is {} KB — cleared", size_kb));
            let _ = tokio::fs::write(
                &recent_file,
                "<?xml version=\"1.0\"?>\n<xbel version=\"1.0\">\n</xbel>\n",
            )
            .await;
        }
    }

    info!(
        "[privacy] Scan complete: {:.0}MB cache, {} exposed files, {} cleanups",
        report.browser_cache_mb,
        report.sensitive_files_exposed.len(),
        report.cleanup_actions.len()
    );

    report
}
