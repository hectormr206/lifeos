//! Safe Mode — prevents death spirals by detecting repeated crashes.
//!
//! A boot counter in /var/lib/lifeos/boot_count tracks how many times the
//! daemon has started. If it exceeds SAFE_MODE_THRESHOLD within a short
//! window (counter not reset), the daemon enters safe mode.
//!
//! Safe mode disables:
//! - Self-improvement (prompt tuning, skill generation)
//! - Autonomous actions (proactive tasks)
//! - Self-modification (config changes by the agent)
//!
//! Safe mode keeps alive:
//! - API server, Telegram (respond-only), health checks, basic commands

use anyhow::Result;
use log::{info, warn};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

const SAFE_MODE_THRESHOLD: u32 = 5;
const BOOT_COUNT_FILE: &str = "boot_count";
// 30 seconds: a daemon that has been up for 30s is clearly past its crash
// window. The old value of 600s (10 min) meant that every routine restart
// during dev work (daemon-reload, unit edit, binary swap) accumulated
// toward the threshold forever, and boot_count grew into the thousands
// without ever resetting — eventually tripping SAFE MODE on a perfectly
// healthy system.
const STABLE_WINDOW_SECS: u64 = 30;

static SAFE_MODE_ACTIVE: AtomicBool = AtomicBool::new(false);

/// Check if safe mode is currently active (callable from anywhere)
pub fn is_safe_mode() -> bool {
    SAFE_MODE_ACTIVE.load(Ordering::Relaxed)
}

/// Initialize boot counter and determine if safe mode should activate.
/// Call this at daemon startup before spawning background tasks.
pub async fn init(data_dir: &Path) -> Result<bool> {
    let counter_path = data_dir.join(BOOT_COUNT_FILE);

    // Read current count
    let count = if counter_path.exists() {
        tokio::fs::read_to_string(&counter_path)
            .await
            .ok()
            .and_then(|s| s.trim().parse::<u32>().ok())
            .unwrap_or(0)
    } else {
        0
    };

    let new_count = count + 1;

    // Ensure parent directory exists
    if let Some(parent) = counter_path.parent() {
        tokio::fs::create_dir_all(parent).await.ok();
    }

    // Write incremented count
    tokio::fs::write(&counter_path, new_count.to_string()).await?;

    if new_count > SAFE_MODE_THRESHOLD {
        warn!(
            "[safe_mode] Boot count {} exceeds threshold {} — entering SAFE MODE",
            new_count, SAFE_MODE_THRESHOLD
        );
        SAFE_MODE_ACTIVE.store(true, Ordering::Relaxed);
        return Ok(true);
    }

    info!(
        "[safe_mode] Boot count: {}/{}",
        new_count, SAFE_MODE_THRESHOLD
    );

    // Schedule reset after stable window
    let reset_path = counter_path.clone();
    tokio::spawn(async move {
        tokio::time::sleep(tokio::time::Duration::from_secs(STABLE_WINDOW_SECS)).await;
        // If we got here, daemon has been stable for 10 minutes — reset counter
        if let Err(e) = tokio::fs::write(&reset_path, "0").await {
            warn!("[safe_mode] Failed to reset boot counter: {}", e);
        } else {
            info!(
                "[safe_mode] Daemon stable for {}s — boot counter reset to 0",
                STABLE_WINDOW_SECS
            );
        }
    });

    Ok(false)
}

/// Exit safe mode manually (e.g., user says "exit safe mode" in Telegram)
pub fn exit_safe_mode() {
    if SAFE_MODE_ACTIVE.load(Ordering::Relaxed) {
        SAFE_MODE_ACTIVE.store(false, Ordering::Relaxed);
        info!("[safe_mode] Safe mode deactivated by user");
    }
}

/// Reset boot counter (call when user explicitly exits safe mode)
pub async fn reset_counter(data_dir: &Path) -> Result<()> {
    let counter_path = data_dir.join(BOOT_COUNT_FILE);
    tokio::fs::write(&counter_path, "0").await?;
    Ok(())
}
