//! Battery Manager — Charge threshold control + power profile management.
//!
//! Automatically detects laptop vendor and applies optimal charge thresholds
//! to extend battery lifespan. Integrates with tuned-ppd for power profiles.

use anyhow::Result;
use log::{info, warn};
use serde::{Deserialize, Serialize};
use tokio::process::Command;

const SYSFS_BAT: &str = "/sys/class/power_supply/BAT0";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatteryStatus {
    pub present: bool,
    pub status: String,    // Charging, Discharging, Full, Not charging
    pub capacity_pct: u32, // Current charge %
    pub health_pct: u32,   // energy_full / energy_full_design * 100
    pub cycle_count: u32,
    pub energy_full_wh: f64,
    pub energy_design_wh: f64,
    pub temperature_c: Option<f64>,
    pub charge_threshold: Option<u32>,
    pub power_profile: String,
    pub vendor_detected: Option<String>,
}

/// Read full battery status from sysfs.
pub async fn read_battery_status() -> Result<BatteryStatus> {
    let present = read_sysfs("present").await.unwrap_or_default() == "1";
    if !present {
        anyhow::bail!("No battery found");
    }

    let status = read_sysfs("status")
        .await
        .unwrap_or_else(|_| "Unknown".into());
    let capacity = read_sysfs_u64("capacity").await.unwrap_or(0) as u32;
    let energy_full = read_sysfs_u64("energy_full").await.unwrap_or(0) as f64 / 1_000_000.0;
    let energy_design =
        read_sysfs_u64("energy_full_design").await.unwrap_or(1) as f64 / 1_000_000.0;
    let cycles = read_sysfs_u64("cycle_count").await.unwrap_or(0) as u32;
    let temp = read_sysfs_u64("temp").await.ok().map(|t| t as f64 / 10.0);
    let threshold = read_sysfs_u64("charge_control_end_threshold")
        .await
        .ok()
        .map(|t| t as u32);

    let health = if energy_design > 0.0 {
        (energy_full / energy_design * 100.0) as u32
    } else {
        100
    };

    let vendor = detect_vendor().await;
    let profile = get_power_profile()
        .await
        .unwrap_or_else(|_| "unknown".into());

    Ok(BatteryStatus {
        present,
        status,
        capacity_pct: capacity,
        health_pct: health,
        cycle_count: cycles,
        energy_full_wh: energy_full,
        energy_design_wh: energy_design,
        temperature_c: temp,
        charge_threshold: threshold,
        power_profile: profile,
        vendor_detected: vendor,
    })
}

/// Set charge threshold (0-100). Detects vendor and uses appropriate sysfs path.
pub async fn set_charge_threshold(threshold: u32) -> Result<()> {
    let threshold = threshold.clamp(40, 100);
    info!("[battery] Setting charge threshold to {}%", threshold);

    // Try standard sysfs path first
    let path = format!("{}/charge_control_end_threshold", SYSFS_BAT);
    let result = tokio::fs::write(&path, threshold.to_string()).await;

    match result {
        Ok(()) => {
            info!("[battery] Threshold set to {}% via sysfs", threshold);
            Ok(())
        }
        Err(e) => {
            warn!(
                "[battery] Direct sysfs write failed ({}), trying vendor-specific",
                e
            );

            // Try Lenovo IdeaPad conservation mode (fixed ~60%)
            let conservation =
                "/sys/bus/platform/drivers/ideapad_acpi/VPC2004:00/conservation_mode";
            if tokio::fs::metadata(conservation).await.is_ok() {
                let value = if threshold <= 80 { "1" } else { "0" };
                tokio::fs::write(conservation, value).await?;
                info!("[battery] Lenovo conservation mode: {}", value);
                return Ok(());
            }

            anyhow::bail!("Could not set charge threshold: {}", e)
        }
    }
}

/// Get current power profile via powerprofilesctl or tuned-adm.
pub async fn get_power_profile() -> Result<String> {
    // Try powerprofilesctl first (tuned-ppd on Fedora 42)
    let output = Command::new("powerprofilesctl").arg("get").output().await;

    if let Ok(o) = output {
        if o.status.success() {
            return Ok(String::from_utf8_lossy(&o.stdout).trim().to_string());
        }
    }

    // Fallback: tuned-adm
    let output = Command::new("tuned-adm").arg("active").output().await;

    if let Ok(o) = output {
        if o.status.success() {
            let text = String::from_utf8_lossy(&o.stdout);
            if let Some(profile) = text
                .lines()
                .find_map(|l| l.strip_prefix("Current active profile: "))
            {
                return Ok(profile.trim().to_string());
            }
        }
    }

    Ok("unknown".into())
}

/// Set power profile: "power-saver", "balanced", "performance"
pub async fn set_power_profile(profile: &str) -> Result<()> {
    info!("[battery] Setting power profile: {}", profile);

    let output = Command::new("powerprofilesctl")
        .args(["set", profile])
        .output()
        .await;

    if let Ok(o) = output {
        if o.status.success() {
            return Ok(());
        }
    }

    // Fallback: tuned-adm
    let tuned_profile = match profile {
        "power-saver" => "powersave",
        "performance" => "throughput-performance",
        _ => "balanced",
    };

    Command::new("tuned-adm")
        .args(["profile", tuned_profile])
        .output()
        .await
        .map_err(|e| anyhow::anyhow!("Failed to set power profile: {}", e))?;

    Ok(())
}

/// Configure NVIDIA RTD3 for maximum power savings on battery.
pub async fn configure_nvidia_rtd3() -> Result<()> {
    let conf_path = "/etc/modprobe.d/nvidia-power.conf";
    let content = "options nvidia \"NVreg_DynamicPowerManagement=0x02\"\n";

    match tokio::fs::write(conf_path, content).await {
        Ok(()) => {
            info!("[battery] NVIDIA RTD3 configured (fine-grained power management)");
            Ok(())
        }
        Err(e) => {
            warn!("[battery] Could not write RTD3 config ({}), needs root", e);
            anyhow::bail!("RTD3 config requires root: {}", e)
        }
    }
}

/// Detect laptop vendor from DMI data.
async fn detect_vendor() -> Option<String> {
    let vendor = tokio::fs::read_to_string("/sys/class/dmi/id/sys_vendor")
        .await
        .ok()?;
    Some(vendor.trim().to_string())
}

async fn read_sysfs(attr: &str) -> Result<String> {
    let path = format!("{}/{}", SYSFS_BAT, attr);
    let content = tokio::fs::read_to_string(&path).await?;
    Ok(content.trim().to_string())
}

async fn read_sysfs_u64(attr: &str) -> Result<u64> {
    let text = read_sysfs(attr).await?;
    text.parse::<u64>()
        .map_err(|e| anyhow::anyhow!("parse {} failed: {}", attr, e))
}
