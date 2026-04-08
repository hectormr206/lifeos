//! Eye Health — Blue light filter and break reminders for eye protection.
//!
//! Integrates with wlsunset (Wayland) for automatic night mode at sunset,
//! and implements the 20-20-20 rule (every 20 min, look 20 feet away for 20s).

use anyhow::Result;
use log::info;
use tokio::process::Command;

/// Start night mode using wlsunset with appropriate color temperature.
/// Default: 4500K during transition, 3500K at night.
pub async fn enable_night_mode(temp_day: u32, temp_night: u32) -> Result<()> {
    // Kill any existing wlsunset
    let _ = Command::new("pkill").arg("wlsunset").output().await;
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;

    Command::new("wlsunset")
        .args(["-T", &temp_day.to_string(), "-t", &temp_night.to_string()])
        .spawn()
        .map_err(|e| anyhow::anyhow!("Failed to start wlsunset: {}", e))?;

    info!(
        "[eye_health] Night mode enabled ({}K → {}K)",
        temp_day, temp_night
    );
    Ok(())
}

/// Check if it's after sunset (simple heuristic: after 19:00 local time).
pub fn is_evening() -> bool {
    let hour = chrono::Local::now().hour();
    !(7..19).contains(&hour)
}

/// Check if the 20-20-20 rule reminder should fire.
/// Returns true if it's been more than `interval_mins` since last break.
pub fn should_remind_20_20_20(
    last_reminder: &Option<std::time::Instant>,
    interval_mins: u64,
) -> bool {
    match last_reminder {
        None => true,
        Some(last) => last.elapsed() >= std::time::Duration::from_secs(interval_mins * 60),
    }
}

use chrono::Timelike;
