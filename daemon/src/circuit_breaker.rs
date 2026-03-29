//! Circuit Breaker — blocks self-modification after repeated failures.
//!
//! States:
//! - Closed: modifications proceed normally
//! - Open: ALL modifications blocked (after FAILURE_THRESHOLD failures)
//! - HalfOpen: allows 1 test modification (after COOLDOWN)
//!
//! Used by the supervisor and agent runtime to gate self-modification attempts.
//! The daemon exposes circuit breaker status via the `/api/v1/health` endpoint
//! and the event bus emits `CircuitBreakerStateChange` events.

use log::{info, warn};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};
use tokio::sync::RwLock;

const FAILURE_THRESHOLD: u32 = 3;
const COOLDOWN_SECS: u64 = 6 * 3600; // 6 hours
const MAX_COOLDOWN_SECS: u64 = 48 * 3600; // 48 hours

#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize)]
pub enum CircuitState {
    Closed,   // Normal operation
    Open,     // Blocked
    HalfOpen, // Testing one modification
}

impl std::fmt::Display for CircuitState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CircuitState::Closed => write!(f, "closed"),
            CircuitState::Open => write!(f, "open"),
            CircuitState::HalfOpen => write!(f, "half-open"),
        }
    }
}

pub struct CircuitBreaker {
    state: RwLock<CircuitState>,
    failure_count: AtomicU32,
    last_failure: RwLock<Option<Instant>>,
    cooldown_multiplier: AtomicU32,
}

impl CircuitBreaker {
    pub fn new() -> Self {
        Self {
            state: RwLock::new(CircuitState::Closed),
            failure_count: AtomicU32::new(0),
            last_failure: RwLock::new(None),
            cooldown_multiplier: AtomicU32::new(1),
        }
    }

    /// Check if a self-modification is allowed.
    pub async fn allow_modification(&self) -> bool {
        let state = *self.state.read().await;
        match state {
            CircuitState::Closed => true,
            CircuitState::Open => {
                // Check if cooldown has elapsed
                let cooldown = Duration::from_secs(
                    COOLDOWN_SECS * self.cooldown_multiplier.load(Ordering::Relaxed) as u64,
                );
                let last = self.last_failure.read().await;
                if let Some(t) = *last {
                    if t.elapsed() >= cooldown {
                        // Transition to half-open
                        drop(last);
                        *self.state.write().await = CircuitState::HalfOpen;
                        info!("[circuit_breaker] Cooldown elapsed, entering half-open state");
                        true
                    } else {
                        false
                    }
                } else {
                    false
                }
            }
            CircuitState::HalfOpen => true, // Allow one test
        }
    }

    /// Record a successful modification.
    pub async fn record_success(&self) {
        let state = *self.state.read().await;
        if state == CircuitState::HalfOpen {
            *self.state.write().await = CircuitState::Closed;
            self.failure_count.store(0, Ordering::Relaxed);
            self.cooldown_multiplier.store(1, Ordering::Relaxed);
            info!("[circuit_breaker] Modification succeeded, circuit CLOSED");
        }
    }

    /// Record a failed modification.
    pub async fn record_failure(&self) {
        let count = self.failure_count.fetch_add(1, Ordering::Relaxed) + 1;
        *self.last_failure.write().await = Some(Instant::now());

        if count >= FAILURE_THRESHOLD {
            let prev_state = *self.state.read().await;
            *self.state.write().await = CircuitState::Open;

            // Exponential backoff on cooldown
            if prev_state == CircuitState::HalfOpen {
                let mult = self.cooldown_multiplier.load(Ordering::Relaxed);
                let new_mult = (mult * 2).min((MAX_COOLDOWN_SECS / COOLDOWN_SECS) as u32);
                self.cooldown_multiplier.store(new_mult, Ordering::Relaxed);
            }

            let cooldown_hrs = COOLDOWN_SECS
                * self.cooldown_multiplier.load(Ordering::Relaxed) as u64
                / 3600;
            warn!(
                "[circuit_breaker] {} failures — circuit OPEN (cooldown: {}h)",
                count, cooldown_hrs
            );
        }
    }

    /// Get current state for monitoring/API.
    pub async fn status(&self) -> CircuitBreakerStatus {
        let state = *self.state.read().await;
        let failures = self.failure_count.load(Ordering::Relaxed);
        let cooldown_secs =
            COOLDOWN_SECS * self.cooldown_multiplier.load(Ordering::Relaxed) as u64;
        let remaining_cooldown = if state == CircuitState::Open {
            let last = self.last_failure.read().await;
            if let Some(t) = *last {
                let cooldown = Duration::from_secs(cooldown_secs);
                cooldown.checked_sub(t.elapsed()).map(|d| d.as_secs())
            } else {
                None
            }
        } else {
            None
        };

        CircuitBreakerStatus {
            state,
            failure_count: failures,
            cooldown_secs,
            remaining_cooldown_secs: remaining_cooldown,
        }
    }
}

/// Serializable status for API responses.
#[derive(Debug, Clone, serde::Serialize)]
pub struct CircuitBreakerStatus {
    pub state: CircuitState,
    pub failure_count: u32,
    pub cooldown_secs: u64,
    pub remaining_cooldown_secs: Option<u64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_circuit_starts_closed() {
        let cb = CircuitBreaker::new();
        assert!(cb.allow_modification().await);
        let status = cb.status().await;
        assert_eq!(status.state, CircuitState::Closed);
        assert_eq!(status.failure_count, 0);
    }

    #[tokio::test]
    async fn test_circuit_opens_after_threshold() {
        let cb = CircuitBreaker::new();
        // Record FAILURE_THRESHOLD failures
        for _ in 0..FAILURE_THRESHOLD {
            cb.record_failure().await;
        }
        let status = cb.status().await;
        assert_eq!(status.state, CircuitState::Open);
        assert!(!cb.allow_modification().await);
    }

    #[tokio::test]
    async fn test_success_resets_half_open() {
        let cb = CircuitBreaker::new();
        // Force into half-open state
        *cb.state.write().await = CircuitState::HalfOpen;
        cb.record_success().await;
        let status = cb.status().await;
        assert_eq!(status.state, CircuitState::Closed);
        assert_eq!(status.failure_count, 0);
    }

    #[tokio::test]
    async fn test_below_threshold_stays_closed() {
        let cb = CircuitBreaker::new();
        // Record fewer than threshold failures
        for _ in 0..(FAILURE_THRESHOLD - 1) {
            cb.record_failure().await;
        }
        assert!(cb.allow_modification().await);
        let status = cb.status().await;
        assert_eq!(status.state, CircuitState::Closed);
    }
}
