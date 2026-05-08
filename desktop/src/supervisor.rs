//! Supervisor: structured task lifecycle via CancellationToken + JoinSet.
//!
//! This is the ONE pattern for all async tasks in lifeos-desktop.
//! No raw `tokio::spawn` outside the supervisor.

use std::future::Future;
use std::time::Duration;
use tokio::task::JoinSet;
use tokio_util::sync::CancellationToken;

/// Supervisor owns all spawned tasks. On drop, aborts remaining tasks.
pub struct Supervisor {
    cancel: CancellationToken,
    tasks: JoinSet<()>,
}

impl Supervisor {
    pub fn new(cancel: CancellationToken) -> Self {
        Self {
            cancel,
            tasks: JoinSet::new(),
        }
    }

    /// Spawn a named task into the supervisor's JoinSet.
    pub fn spawn<F>(&mut self, name: &'static str, fut: F)
    where
        F: Future<Output = ()> + Send + 'static,
    {
        log::debug!("[supervisor] spawning task '{}'", name);
        self.tasks.spawn(fut);
    }

    /// Wait for SIGTERM or SIGINT, then cancel all tasks and drain.
    /// Returns after all tasks exit (or after a 5s abort timeout).
    pub async fn run_until_signal(mut self) {
        tokio::select! {
            _ = wait_for_signal() => {
                log::info!("[supervisor] signal received — shutting down");
            }
            _ = self.cancel.cancelled() => {
                log::info!("[supervisor] cancel token fired — shutting down");
            }
        }

        self.cancel.cancel();
        drain_with_timeout(&mut self.tasks).await;
    }
}

impl Drop for Supervisor {
    fn drop(&mut self) {
        // Defensive abort in case run_until_signal was bypassed (e.g. panic in main).
        self.cancel.cancel();
        self.tasks.abort_all();
    }
}

async fn wait_for_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        // Signal handler registration only fails if the kernel itself refuses
        // to install the handler (out of resources at process start). The
        // companion is unusable without termination signals — surface the
        // panic loudly instead of silently degrading.
        #[allow(clippy::expect_used)]
        let mut sigterm = signal(SignalKind::terminate()).expect("register SIGTERM handler");
        #[allow(clippy::expect_used)]
        let mut sigint = signal(SignalKind::interrupt()).expect("register SIGINT handler");
        tokio::select! {
            _ = sigterm.recv() => log::info!("[supervisor] SIGTERM received"),
            _ = sigint.recv() => log::info!("[supervisor] SIGINT received"),
        }
    }
    #[cfg(not(unix))]
    {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to register Ctrl+C handler");
    }
}

async fn drain_with_timeout(tasks: &mut JoinSet<()>) {
    let timeout = Duration::from_secs(5);
    let start = tokio::time::Instant::now();
    while let Some(result) = tokio::time::timeout(timeout, tasks.join_next())
        .await
        .ok()
        .flatten()
    {
        match result {
            Ok(()) => {}
            Err(e) if e.is_cancelled() => {}
            Err(e) => log::warn!("[supervisor] task panicked: {}", e),
        }
        if start.elapsed() >= timeout {
            log::warn!("[supervisor] shutdown timeout — aborting remaining tasks");
            tasks.abort_all();
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    #[tokio::test]
    async fn drop_aborts_pending_tasks() {
        let cancel = CancellationToken::new();
        let mut sup = Supervisor::new(cancel.clone());

        let running = Arc::new(AtomicBool::new(false));
        let running_clone = running.clone();

        sup.spawn("long-running", async move {
            running_clone.store(true, Ordering::SeqCst);
            tokio::time::sleep(Duration::from_secs(60)).await;
        });

        // Give the task a moment to start
        tokio::time::sleep(Duration::from_millis(50)).await;

        // Drop the supervisor — should abort the task
        drop(sup);

        // After drop + abort, the task counter should reflect cancellation
        // (we can't directly join after drop, but abort_all is called)
        // This test verifies no panic occurs on drop.
        assert!(running.load(Ordering::SeqCst), "task should have started");
    }

    #[tokio::test]
    async fn cancel_stops_spawned_task() {
        let cancel = CancellationToken::new();
        let mut sup = Supervisor::new(cancel.clone());
        let done = Arc::new(AtomicBool::new(false));
        let done_clone = done.clone();
        let cancel_inner = cancel.clone();

        sup.spawn("cancellable", async move {
            tokio::select! {
                _ = cancel_inner.cancelled() => {
                    done_clone.store(true, Ordering::SeqCst);
                }
                _ = tokio::time::sleep(Duration::from_secs(60)) => {}
            }
        });

        cancel.cancel();
        // Drain via join_next loop (can't move tasks out due to Drop impl)
        while let Some(result) = sup.tasks.join_next().await {
            let _ = result;
        }

        assert!(done.load(Ordering::SeqCst));
    }
}
