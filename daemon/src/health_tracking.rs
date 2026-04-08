//! Health tracking — Monitors user wellbeing from presence and activity data.
//!
//! Uses webcam presence detection, session duration, and activity patterns
//! to provide wellness reminders and health insights.

use chrono::{DateTime, Local};
use log::info;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthState {
    pub session_start: Option<DateTime<Local>>,
    pub last_break: Option<DateTime<Local>>,
    pub total_active_minutes: u64,
    pub break_count: u32,
    pub hydration_reminder_count: u32,
    pub posture_alerts: u32,
    pub eye_strain_alerts: u32,
}

impl Default for HealthState {
    fn default() -> Self {
        Self {
            session_start: Some(Local::now()),
            last_break: None,
            total_active_minutes: 0,
            break_count: 0,
            hydration_reminder_count: 0,
            posture_alerts: 0,
            eye_strain_alerts: 0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthReminder {
    pub reminder_type: ReminderType,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReminderType {
    TakeBreak,
    Hydrate,
    Stretch,
    EyeRest,
    PostureCheck,
    EndOfDay,
}

pub struct HealthTracker {
    state: HealthState,
    break_interval_minutes: u64,
}

impl Default for HealthTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl HealthTracker {
    pub fn new() -> Self {
        Self {
            state: HealthState::default(),
            break_interval_minutes: 45,
        }
    }

    /// Check if any health reminders are due.
    pub fn check_reminders(&mut self) -> Vec<HealthReminder> {
        let now = Local::now();
        let mut reminders = Vec::new();

        // Check if break is needed
        let minutes_since_break = self
            .state
            .last_break
            .map(|lb| (now - lb).num_minutes() as u64)
            .unwrap_or_else(|| {
                self.state
                    .session_start
                    .map(|ss| (now - ss).num_minutes() as u64)
                    .unwrap_or(0)
            });

        if minutes_since_break >= self.break_interval_minutes {
            reminders.push(HealthReminder {
                reminder_type: ReminderType::TakeBreak,
                message: format!(
                    "Llevas {} minutos sin descanso. Levantate, estira y camina un poco.",
                    minutes_since_break
                ),
            });
        }

        // Hydration reminder
        let hours_active = self.state.total_active_minutes / 60;
        let expected_hydration = hours_active as u32;
        if self.state.hydration_reminder_count < expected_hydration {
            reminders.push(HealthReminder {
                reminder_type: ReminderType::Hydrate,
                message: "Recuerda beber agua. La hidratacion mejora la concentracion.".into(),
            });
            self.state.hydration_reminder_count = expected_hydration;
        }

        // Eye rest (20-20-20 rule: every 20 min, look 20 feet away for 20 sec)
        if minutes_since_break >= 20 && minutes_since_break % 20 < 2 {
            reminders.push(HealthReminder {
                reminder_type: ReminderType::EyeRest,
                message: "Regla 20-20-20: Mira algo a 6 metros de distancia durante 20 segundos."
                    .into(),
            });
        }

        reminders
    }

    /// Record that a break was taken.
    pub fn record_break(&mut self) {
        self.state.last_break = Some(Local::now());
        self.state.break_count += 1;
        info!("Break recorded (total: {})", self.state.break_count);
    }

    /// Update active time.
    pub fn tick_active(&mut self) {
        self.state.total_active_minutes += 1;
    }

    /// Get current health state.
    pub fn state(&self) -> &HealthState {
        &self.state
    }

    /// Generate end-of-day health summary.
    pub fn daily_summary(&self) -> String {
        format!(
            "Resumen de salud del dia:\n\
             - Tiempo activo: {} horas {} minutos\n\
             - Descansos tomados: {}\n\
             - Recordatorios de hidratacion: {}\n\
             - Alertas de postura: {}\n\
             - Alertas de fatiga visual: {}",
            self.state.total_active_minutes / 60,
            self.state.total_active_minutes % 60,
            self.state.break_count,
            self.state.hydration_reminder_count,
            self.state.posture_alerts,
            self.state.eye_strain_alerts,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_tracker_has_session() {
        let tracker = HealthTracker::new();
        assert!(tracker.state().session_start.is_some());
    }

    #[test]
    fn record_break_increments() {
        let mut tracker = HealthTracker::new();
        tracker.record_break();
        assert_eq!(tracker.state().break_count, 1);
        tracker.record_break();
        assert_eq!(tracker.state().break_count, 2);
    }

    #[test]
    fn daily_summary_format() {
        let tracker = HealthTracker::new();
        let summary = tracker.daily_summary();
        assert!(summary.contains("Resumen de salud"));
    }
}
