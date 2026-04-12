//! Reactive CPU Thermal Manager
//!
//! Monitors real CPU temperature and dynamically adjusts the performance cap
//! to prevent thermal throttling. Works with Intel pstate, AMD pstate, and
//! generic cpufreq drivers.
//!
//! Instead of applying a blind fixed cap, this module reacts to actual
//! temperature readings with hysteresis to avoid oscillation:
//!
//! - **Cool** (<72°C): 100% — no cap needed
//! - **Warm** (72-80°C): 95% — slight reduction, barely noticeable
//! - **Hot** (80-87°C): 85% — meaningful reduction, still responsive
//! - **Critical** (87-92°C): 75% — aggressive cap to pull temps down
//! - **Emergency** (>92°C): 65% — protect hardware at all costs
//!
//! Gaming mode shifts all thresholds UP by 5°C (accepts hotter temps during
//! gaming because the GPU fan ramps up and CPU can sustain higher loads).
//!
//! Desktops are left at 100% — they have adequate cooling by design.

use anyhow::{Context, Result};
use log::{debug, info, warn};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;
use std::sync::Arc;
use tokio::sync::RwLock;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// How often to read temperature and adjust (seconds).
const POLL_INTERVAL_SECS: u64 = 5;

/// Hysteresis in millidegrees — temperature must drop this much below a
/// threshold before we step UP to a higher performance cap. Prevents rapid
/// oscillation at boundary temperatures.
const HYSTERESIS_MC: i64 = 5_000; // 5°C

/// Gaming mode shifts all temperature thresholds UP by this amount (millideg).
/// Accepts hotter temps because gaming workloads benefit from CPU headroom
/// and the GPU fan usually ramps up, improving overall airflow.
const GAMING_SHIFT_MC: i64 = 5_000; // 5°C

// ---------------------------------------------------------------------------
// Temperature thresholds (millidegrees Celsius)
//
// Each entry: (temp_threshold_mc, max_perf_pct)
// Evaluated top-to-bottom when HEATING (first match wins).
// When COOLING, we require temp < threshold - HYSTERESIS before stepping up.
// ---------------------------------------------------------------------------

const THERMAL_STEPS: &[(i64, u32)] = &[
    (92_000, 65),  // Emergency: protect hardware
    (87_000, 75),  // Critical: aggressive reduction
    (80_000, 85),  // Hot: meaningful but tolerable reduction
    (72_000, 95),  // Warm: barely noticeable
    (0, 100),      // Cool: no cap
];

// ---------------------------------------------------------------------------
// CPU driver abstraction
// ---------------------------------------------------------------------------

/// Detected CPU frequency scaling driver.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CpuDriver {
    /// Intel Performance and Energy Bias Hint driver (has max_perf_pct)
    IntelPstate,
    /// AMD P-State EPP driver (has scaling_max_freq per policy)
    AmdPstate,
    /// Generic cpufreq governor (has scaling_max_freq per policy)
    GenericCpufreq,
}

/// Detect which CPU frequency driver is active.
fn detect_cpu_driver() -> Option<CpuDriver> {
    // Check intel_pstate first (single global knob)
    if Path::new("/sys/devices/system/cpu/intel_pstate/status").exists() {
        if let Ok(status) = fs::read_to_string("/sys/devices/system/cpu/intel_pstate/status") {
            if status.trim() == "active" {
                return Some(CpuDriver::IntelPstate);
            }
        }
    }

    // Check amd-pstate
    if Path::new("/sys/devices/system/cpu/amd_pstate").exists() {
        return Some(CpuDriver::AmdPstate);
    }

    // Check generic cpufreq (scaling_max_freq on policy0)
    if Path::new("/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq").exists() {
        return Some(CpuDriver::GenericCpufreq);
    }

    None
}

// ---------------------------------------------------------------------------
// Temperature reading
// ---------------------------------------------------------------------------

/// Preferred thermal zone types for CPU package temperature, in priority order.
/// We pick the first zone whose type matches one of these.
const CPU_THERMAL_ZONE_TYPES: &[&str] = &[
    "x86_pkg_temp", // Intel package temp (most representative)
    "TCPU_PCI",     // Intel ACPI CPU temp
    "k10temp",      // AMD Zen family
    "zenpower",     // Alternative AMD driver
    "coretemp",     // Older Intel per-core (still useful as fallback)
];

/// Find the best thermal zone for CPU temperature.
fn find_cpu_thermal_zone() -> Option<String> {
    let zones = match fs::read_dir("/sys/class/thermal") {
        Ok(entries) => entries,
        Err(_) => return None,
    };

    let mut candidates: Vec<(usize, String)> = Vec::new();

    for entry in zones.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.starts_with("thermal_zone") {
            continue;
        }
        let type_path = format!("/sys/class/thermal/{}/type", name);
        if let Ok(zone_type) = fs::read_to_string(&type_path) {
            let zone_type = zone_type.trim();
            if let Some(priority) = CPU_THERMAL_ZONE_TYPES
                .iter()
                .position(|&t| t == zone_type)
            {
                candidates.push((priority, name));
            }
        }
    }

    // Pick the highest-priority (lowest index) match
    candidates.sort_by_key(|(priority, _)| *priority);
    candidates.into_iter().next().map(|(_, name)| name)
}

/// Read the current CPU temperature in millidegrees Celsius.
fn read_cpu_temp(zone: &str) -> Result<i64> {
    let path = format!("/sys/class/thermal/{}/temp", zone);
    let raw = fs::read_to_string(&path)
        .with_context(|| format!("failed to read {}", path))?;
    raw.trim()
        .parse::<i64>()
        .with_context(|| format!("failed to parse temperature from {}: '{}'", path, raw.trim()))
}

// ---------------------------------------------------------------------------
// Performance cap application
// ---------------------------------------------------------------------------

/// Apply a performance cap percentage via the detected CPU driver.
fn apply_perf_cap(driver: CpuDriver, pct: u32) -> Result<()> {
    match driver {
        CpuDriver::IntelPstate => {
            let path = "/sys/devices/system/cpu/intel_pstate/max_perf_pct";
            fs::write(path, format!("{}", pct))
                .with_context(|| format!("failed to write {} to {}", pct, path))?;
        }
        CpuDriver::AmdPstate | CpuDriver::GenericCpufreq => {
            // For AMD and generic: set scaling_max_freq on each policy to pct% of max
            apply_scaling_max_freq_pct(pct)?;
        }
    }
    Ok(())
}

/// Set scaling_max_freq to `pct`% of cpuinfo_max_freq on all CPU policies.
fn apply_scaling_max_freq_pct(pct: u32) -> Result<()> {
    let cpufreq = Path::new("/sys/devices/system/cpu/cpufreq");
    if !cpufreq.exists() {
        anyhow::bail!("cpufreq sysfs not available");
    }

    for entry in fs::read_dir(cpufreq)?.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.starts_with("policy") {
            continue;
        }
        let max_path = format!(
            "/sys/devices/system/cpu/cpufreq/{}/cpuinfo_max_freq",
            name
        );
        let target_path = format!(
            "/sys/devices/system/cpu/cpufreq/{}/scaling_max_freq",
            name
        );

        let max_freq: u64 = fs::read_to_string(&max_path)
            .unwrap_or_default()
            .trim()
            .parse()
            .unwrap_or(0);

        if max_freq == 0 {
            continue;
        }

        let target_freq = max_freq * u64::from(pct) / 100;
        if let Err(e) = fs::write(&target_path, format!("{}", target_freq)) {
            warn!(
                "[thermal] failed to write {} to {}: {}",
                target_freq, target_path, e
            );
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Operating mode for the thermal manager. Game Guard sets this.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThermalMode {
    /// Normal reactive management — full temperature-based algorithm
    Normal,
    /// Gaming — shifts thresholds up by GAMING_SHIFT_MC to allow more headroom
    Gaming,
    /// Full — no thermal cap at all (desktop default, or manual override)
    Full,
}

/// Snapshot of thermal manager state (for API/status).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ThermalState {
    /// Whether the thermal manager is actively monitoring
    pub active: bool,
    /// Detected CPU frequency driver
    pub cpu_driver: Option<CpuDriver>,
    /// Thermal zone being monitored
    pub thermal_zone: Option<String>,
    /// Current CPU temperature in °C (None if reading failed)
    pub current_temp_c: Option<f64>,
    /// Current performance cap percentage
    pub current_perf_pct: u32,
    /// Active operating mode
    pub mode: ThermalMode,
    /// Whether this machine is a laptop
    pub is_laptop: bool,
}

// ---------------------------------------------------------------------------
// ThermalManager
// ---------------------------------------------------------------------------

struct ThermalManagerInner {
    mode: ThermalMode,
    current_pct: u32,
    cpu_driver: Option<CpuDriver>,
    thermal_zone: Option<String>,
    is_laptop: bool,
    last_temp_mc: i64,
}

/// Reactive CPU thermal manager.
pub struct ThermalManager {
    inner: Arc<RwLock<ThermalManagerInner>>,
}

impl ThermalManager {
    /// Create a new thermal manager. Call `run_loop` to start monitoring.
    pub fn new() -> Self {
        let is_laptop = crate::game_guard::is_laptop();
        let cpu_driver = detect_cpu_driver();
        let thermal_zone = find_cpu_thermal_zone();

        info!(
            "[thermal] init: laptop={}, driver={:?}, zone={:?}",
            is_laptop, cpu_driver, thermal_zone
        );

        let initial_mode = if is_laptop {
            ThermalMode::Normal
        } else {
            ThermalMode::Full
        };

        Self {
            inner: Arc::new(RwLock::new(ThermalManagerInner {
                mode: initial_mode,
                current_pct: 100,
                cpu_driver,
                thermal_zone,
                is_laptop,
                last_temp_mc: 0,
            })),
        }
    }

    /// Set the operating mode (called by Game Guard).
    pub async fn set_mode(&self, mode: ThermalMode) {
        let mut inner = self.inner.write().await;
        if inner.mode != mode {
            info!("[thermal] mode changed: {:?} -> {:?}", inner.mode, mode);
            inner.mode = mode;
        }
    }

    /// Get a snapshot of the current thermal state.
    pub async fn state(&self) -> ThermalState {
        let inner = self.inner.read().await;
        ThermalState {
            active: inner.is_laptop && inner.cpu_driver.is_some() && inner.thermal_zone.is_some(),
            cpu_driver: inner.cpu_driver,
            thermal_zone: inner.thermal_zone.clone(),
            current_temp_c: if inner.last_temp_mc > 0 {
                Some(inner.last_temp_mc as f64 / 1000.0)
            } else {
                None
            },
            current_perf_pct: inner.current_pct,
            mode: inner.mode,
            is_laptop: inner.is_laptop,
        }
    }

    /// Run the thermal monitoring loop. Blocks forever.
    pub async fn run_loop(&self) {
        // Initial checks
        {
            let inner = self.inner.read().await;
            if !inner.is_laptop {
                info!("[thermal] desktop detected — thermal manager inactive (100%% cap)");
                return;
            }
            if inner.cpu_driver.is_none() {
                warn!("[thermal] no supported CPU driver found — thermal manager inactive");
                return;
            }
            if inner.thermal_zone.is_none() {
                warn!("[thermal] no CPU thermal zone found — thermal manager inactive");
                return;
            }
        }

        info!(
            "[thermal] reactive monitoring started (poll={}s, hysteresis={}°C)",
            POLL_INTERVAL_SECS,
            HYSTERESIS_MC / 1000
        );

        let mut interval = tokio::time::interval(std::time::Duration::from_secs(POLL_INTERVAL_SECS));

        loop {
            interval.tick().await;
            if let Err(e) = self.tick().await {
                warn!("[thermal] tick error: {}", e);
            }
        }
    }

    /// Single monitoring tick: read temp, compute target, apply if changed.
    async fn tick(&self) -> Result<()> {
        let mut inner = self.inner.write().await;

        // Full mode = no management
        if inner.mode == ThermalMode::Full {
            if inner.current_pct != 100 {
                if let Some(driver) = inner.cpu_driver {
                    let _ = apply_perf_cap(driver, 100);
                }
                inner.current_pct = 100;
            }
            return Ok(());
        }

        let zone = match &inner.thermal_zone {
            Some(z) => z.clone(),
            None => return Ok(()),
        };
        let driver = match inner.cpu_driver {
            Some(d) => d,
            None => return Ok(()),
        };

        // Read temperature
        let temp_mc = read_cpu_temp(&zone)?;
        inner.last_temp_mc = temp_mc;

        // Compute temperature shift for gaming mode
        let shift = if inner.mode == ThermalMode::Gaming {
            GAMING_SHIFT_MC
        } else {
            0
        };

        // Determine target performance cap
        let target_pct = compute_target_pct(temp_mc, inner.current_pct, shift);

        if target_pct != inner.current_pct {
            let direction = if target_pct < inner.current_pct {
                "throttling"
            } else {
                "releasing"
            };
            info!(
                "[thermal] {} {}% -> {}% (temp={:.1}°C, mode={:?})",
                direction,
                inner.current_pct,
                target_pct,
                temp_mc as f64 / 1000.0,
                inner.mode
            );
            apply_perf_cap(driver, target_pct)?;
            inner.current_pct = target_pct;
        } else {
            debug!(
                "[thermal] steady at {}% (temp={:.1}°C)",
                inner.current_pct,
                temp_mc as f64 / 1000.0
            );
        }

        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Reactive algorithm
// ---------------------------------------------------------------------------

/// Compute the target performance percentage based on current temperature,
/// the current cap, and a mode-dependent threshold shift.
///
/// When heating up: step DOWN as soon as we cross a threshold.
/// When cooling down: only step UP when temp drops below threshold - hysteresis.
/// This prevents oscillation at boundary temperatures.
fn compute_target_pct(temp_mc: i64, current_pct: u32, shift_mc: i64) -> u32 {
    // Find what pct the current temperature maps to (heating direction)
    let mut heating_pct = 100u32;
    for &(threshold, pct) in THERMAL_STEPS {
        if temp_mc >= threshold + shift_mc {
            heating_pct = pct;
            break;
        }
    }

    // If we need to step DOWN (hotter), do it immediately
    if heating_pct < current_pct {
        return heating_pct;
    }

    // If we could step UP (cooler), apply hysteresis — find the threshold
    // for the CURRENT cap and only release if we're below it minus hysteresis.
    let current_threshold = THERMAL_STEPS
        .iter()
        .find(|&&(_, pct)| pct == current_pct)
        .map(|&(threshold, _)| threshold + shift_mc);

    if let Some(threshold) = current_threshold {
        if temp_mc < threshold - HYSTERESIS_MC {
            // Cool enough to step up — but only one step at a time
            return next_step_up(current_pct);
        }
    }

    // Stay where we are
    current_pct
}

/// Find the next step UP from the current cap (one step, not jumping to 100%).
fn next_step_up(current_pct: u32) -> u32 {
    // THERMAL_STEPS is sorted descending by threshold.
    // Find current pct, return the pct of the entry AFTER it (lower threshold = more perf).
    let mut found = false;
    for &(_, pct) in THERMAL_STEPS {
        if found {
            return pct;
        }
        if pct == current_pct {
            found = true;
        }
    }
    // Already at the bottom (100%), stay there
    current_pct
}

// ---------------------------------------------------------------------------
// Boot-time default (called before daemon loop starts)
// ---------------------------------------------------------------------------

/// Apply a safe boot-time default. This is a one-shot that runs before the
/// reactive loop starts. On laptops: set 95% (gentle, barely noticeable).
/// The reactive loop will adjust within seconds once it starts.
pub fn apply_boot_default() {
    let is_laptop = crate::game_guard::is_laptop();
    if !is_laptop {
        info!("[thermal] desktop — skipping boot default");
        return;
    }

    let driver = match detect_cpu_driver() {
        Some(d) => d,
        None => {
            info!("[thermal] no CPU driver — skipping boot default");
            return;
        }
    };

    // 95% is a gentle default — the reactive loop will tighten if needed
    if let Err(e) = apply_perf_cap(driver, 95) {
        warn!("[thermal] boot default failed: {}", e);
    } else {
        info!("[thermal] boot default applied: 95% (reactive loop will take over)");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compute_target_cool_cpu() {
        // 50°C, currently at 100% — should stay at 100%
        assert_eq!(compute_target_pct(50_000, 100, 0), 100);
    }

    #[test]
    fn test_compute_target_warm_cpu() {
        // 75°C, currently at 100% — should drop to 95%
        assert_eq!(compute_target_pct(75_000, 100, 0), 95);
    }

    #[test]
    fn test_compute_target_hot_cpu() {
        // 83°C, currently at 95% — should drop to 85%
        assert_eq!(compute_target_pct(83_000, 95, 0), 85);
    }

    #[test]
    fn test_compute_target_critical_cpu() {
        // 90°C, currently at 85% — should drop to 75%
        assert_eq!(compute_target_pct(90_000, 85, 0), 75);
    }

    #[test]
    fn test_compute_target_emergency() {
        // 95°C, currently at 75% — should drop to 65%
        assert_eq!(compute_target_pct(95_000, 75, 0), 65);
    }

    #[test]
    fn test_hysteresis_prevents_oscillation() {
        // At 80°C with current cap 85% — should NOT step up (need to drop below 72-5=67°C)
        // Wait, let me re-check: current_pct=85, threshold for 85% is 80_000.
        // To step up, need temp < 80_000 - 5_000 = 75_000.
        // At 78°C (78_000) — still above 75_000, should stay at 85%
        assert_eq!(compute_target_pct(78_000, 85, 0), 85);

        // At 74°C (74_000) — below 75_000, should step up to 95%
        assert_eq!(compute_target_pct(74_000, 85, 0), 95);
    }

    #[test]
    fn test_gaming_mode_shifts_thresholds() {
        // 75°C in normal mode → 95% (crosses 72°C threshold)
        assert_eq!(compute_target_pct(75_000, 100, 0), 95);

        // 75°C in gaming mode (shift=5000) → 100% (threshold shifted to 77°C, not crossed)
        assert_eq!(compute_target_pct(75_000, 100, GAMING_SHIFT_MC), 100);

        // 78°C in gaming mode → 95% (crosses shifted threshold of 77°C)
        assert_eq!(compute_target_pct(78_000, 100, GAMING_SHIFT_MC), 95);
    }

    #[test]
    fn test_next_step_up() {
        assert_eq!(next_step_up(65), 75);
        assert_eq!(next_step_up(75), 85);
        assert_eq!(next_step_up(85), 95);
        assert_eq!(next_step_up(95), 100);
        assert_eq!(next_step_up(100), 100); // already at top
    }

    #[test]
    fn test_step_down_is_immediate() {
        // Jump from 100% all the way to 65% if temp is 95°C — no gradual stepping
        assert_eq!(compute_target_pct(95_000, 100, 0), 65);
    }

    #[test]
    fn test_step_up_is_gradual() {
        // At 65% and temp drops to 50°C — should only go to 75%, not jump to 100%
        // Wait: threshold for 65% is 92_000. To step up, need < 92_000 - 5_000 = 87_000.
        // 50°C is well below that, so it steps up to 75%.
        assert_eq!(compute_target_pct(50_000, 65, 0), 75);
    }
}
