//! Ergonomics Monitor — Track computer usage patterns and remind breaks.
//!
//! Monitors keyboard/mouse activity to detect continuous usage and
//! reminds the user to take breaks at appropriate intervals:
//! - Microbreak: 30 seconds every 25 minutes of typing
//! - Short break: 5-10 minutes every 60 minutes
//! - Long break: 15-30 minutes every 2-3 hours

use log::info;
use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErgonomicsState {
    pub active_minutes_today: u64,
    pub last_break_minutes_ago: u64,
    pub continuous_typing_minutes: u64,
    pub breaks_taken_today: u32,
    pub reminder_due: Option<String>,
}

pub struct ErgonomicsMonitor {
    session_start: Instant,
    last_activity: Instant,
    last_microbreak: Instant,
    last_short_break: Instant,
    last_long_break: Instant,
    active_minutes: u64,
    breaks_taken: u32,
    continuous_active_start: Instant,
    idle_threshold: Duration,
}

impl ErgonomicsMonitor {
    pub fn new() -> Self {
        let now = Instant::now();
        Self {
            session_start: now,
            last_activity: now,
            last_microbreak: now,
            last_short_break: now,
            last_long_break: now,
            active_minutes: 0,
            breaks_taken: 0,
            continuous_active_start: now,
            idle_threshold: Duration::from_secs(120), // 2 min idle = break detected
        }
    }

    /// Call this periodically (every ~60s) to update state.
    /// Returns a break reminder message if one is due.
    pub fn tick(&mut self) -> Option<String> {
        let now = Instant::now();
        let since_last = now.duration_since(self.last_activity);

        // If user has been idle for >2 min, count it as a break
        if since_last >= self.idle_threshold {
            self.record_break();
            return None;
        }

        // User is active
        self.active_minutes = now.duration_since(self.session_start).as_secs() / 60;
        let continuous = now.duration_since(self.continuous_active_start).as_secs() / 60;

        // Microbreak: every 25 minutes
        if now.duration_since(self.last_microbreak) >= Duration::from_secs(25 * 60) {
            self.last_microbreak = now;
            return Some(
                "Microbreak: Mira a 6 metros de distancia por 20 segundos. Tus ojos te lo agradecen."
                    .into(),
            );
        }

        // Short break: every 60 minutes
        if now.duration_since(self.last_short_break) >= Duration::from_secs(60 * 60) {
            self.last_short_break = now;
            return Some(
                "Descanso: Llevas 1 hora activo. Levantate, estira, hidratate. 5 minutos hacen la diferencia."
                    .into(),
            );
        }

        // Long break: every 3 hours
        if now.duration_since(self.last_long_break) >= Duration::from_secs(3 * 3600) {
            self.last_long_break = now;
            return Some(format!(
                "Descanso largo: Llevas {} horas frente a la pantalla. Toma 15-30 minutos de descanso real.",
                continuous / 60
            ));
        }

        None
    }

    /// Record that user activity was detected (keyboard/mouse).
    pub fn record_activity(&mut self) {
        let now = Instant::now();
        if now.duration_since(self.last_activity) >= self.idle_threshold {
            // Was idle, now active again — reset continuous counter
            self.continuous_active_start = now;
        }
        self.last_activity = now;
    }

    /// Record that a break was taken.
    pub fn record_break(&mut self) {
        let now = Instant::now();
        self.breaks_taken += 1;
        self.last_microbreak = now;
        self.last_short_break = now;
        self.continuous_active_start = now;
        info!("[ergonomics] Break detected (#{} today)", self.breaks_taken);
    }

    /// Get current state for display.
    pub fn state(&self) -> ErgonomicsState {
        let now = Instant::now();
        let continuous = now.duration_since(self.continuous_active_start).as_secs() / 60;
        let since_short = now.duration_since(self.last_short_break).as_secs() / 60;

        let reminder = if continuous >= 25 && since_short >= 25 {
            Some("Recuerda tomar un descanso pronto".into())
        } else {
            None
        };

        ErgonomicsState {
            active_minutes_today: self.active_minutes,
            last_break_minutes_ago: since_short,
            continuous_typing_minutes: continuous,
            breaks_taken_today: self.breaks_taken,
            reminder_due: reminder,
        }
    }
}
