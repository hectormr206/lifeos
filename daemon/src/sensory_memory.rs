//! Sensory Memory — Persists significant sensory events to MemoryPlane.
//!
//! Listens to DaemonEvent bus and stores:
//! - Visual: screen captures with OCR text and app context
//! - Auditory: voice session transcriptions with responses
//! - Context: app/window changes, meeting state, presence changes
//!
//! Only persists *significant* events (not every keystroke or screen refresh).

use log::{info, warn};
use std::sync::Arc;
use tokio::sync::{broadcast, RwLock};

use crate::events::DaemonEvent;
use crate::memory_plane::MemoryPlaneManager;

/// Minimum time between persisting screen captures (avoid spam).
const VISUAL_COOLDOWN_SECS: i64 = 300; // 5 minutes
/// Minimum transcript length to persist.
const MIN_TRANSCRIPT_LEN: usize = 20;

/// Run the sensory memory listener. Subscribes to the event bus and
/// persists significant sensory events to MemoryPlane.
pub async fn run_sensory_memory_listener(
    mut event_rx: broadcast::Receiver<DaemonEvent>,
    memory: Arc<RwLock<MemoryPlaneManager>>,
) {
    info!("[sensory_memory] Listener started");

    let mut last_visual_save = chrono::Utc::now() - chrono::Duration::seconds(VISUAL_COOLDOWN_SECS);
    let mut last_app = String::new();
    let mut meeting_active = false;

    loop {
        let event = match event_rx.recv().await {
            Ok(e) => e,
            Err(broadcast::error::RecvError::Lagged(n)) => {
                warn!("[sensory_memory] Lagged {} events", n);
                continue;
            }
            Err(broadcast::error::RecvError::Closed) => break,
        };

        match event {
            // ----- Visual Memory: Screen captures with context -----
            DaemonEvent::ScreenCapture { app, summary } => {
                let now = chrono::Utc::now();
                let elapsed = now.signed_duration_since(last_visual_save).num_seconds();

                // Only persist if enough time has passed (cooldown)
                if elapsed >= VISUAL_COOLDOWN_SECS {
                    if let Some(ref sum) = summary {
                        if !sum.trim().is_empty() {
                            let mem = memory.read().await;
                            let content = format!(
                                "What: Screen capture. App: {}. Summary: {}",
                                app.as_deref().unwrap_or("unknown"),
                                sum
                            );
                            let tags = vec![
                                "sensory".to_string(),
                                "visual".to_string(),
                                app.clone().unwrap_or_else(|| "unknown".to_string()),
                            ];
                            if let Err(e) = mem
                                .add_entry(
                                    "visual",
                                    "system",
                                    &tags,
                                    Some("sensory_pipeline"),
                                    30,
                                    &content,
                                )
                                .await
                            {
                                warn!("[sensory_memory] Failed to save visual: {}", e);
                            } else {
                                last_visual_save = now;
                            }
                        }
                    }
                }
            }

            // ----- Auditory Memory: Voice sessions -----
            DaemonEvent::VoiceSessionEnd {
                transcript: Some(ref t),
                ref response,
                latency_ms,
            } if t.len() >= MIN_TRANSCRIPT_LEN => {
                let mem = memory.read().await;
                let content = format!(
                    "What: Voice conversation. User said: {}. Axi responded: {}. Latency: {}ms",
                    t,
                    response.as_deref().unwrap_or("(no response)"),
                    latency_ms.unwrap_or(0)
                );
                let tags = vec![
                    "sensory".to_string(),
                    "auditory".to_string(),
                    "voice".to_string(),
                ];
                if let Err(e) = mem
                    .add_entry(
                        "auditory",
                        "system",
                        &tags,
                        Some("voice_session"),
                        40,
                        &content,
                    )
                    .await
                {
                    warn!("[sensory_memory] Failed to save auditory: {}", e);
                }
            }

            // ----- Context Memory: App/window changes -----
            DaemonEvent::WindowChanged { app, title } => {
                // Only persist when the app actually changes (not just window title)
                if app != last_app && !app.is_empty() {
                    let mem = memory.read().await;
                    let content = format!("What: User switched to {}. Window: {}", app, title);
                    let tags = vec!["sensory".to_string(), "context".to_string(), app.clone()];
                    mem.add_entry(
                        "context",
                        "system",
                        &tags,
                        Some("window_change"),
                        15,
                        &content,
                    )
                    .await
                    .ok();
                    last_app = app;
                }
            }

            // ----- Context Memory: Meeting state changes -----
            DaemonEvent::MeetingStateChanged { active, app } => {
                if active != meeting_active {
                    meeting_active = active;
                    let mem = memory.read().await;
                    let content = if active {
                        format!(
                            "What: Meeting started. App: {}",
                            app.as_deref().unwrap_or("unknown")
                        )
                    } else {
                        "What: Meeting ended.".to_string()
                    };
                    let tags = vec![
                        "sensory".to_string(),
                        "context".to_string(),
                        "meeting".to_string(),
                    ];
                    mem.add_entry("context", "system", &tags, Some("meeting"), 50, &content)
                        .await
                        .ok();
                }
            }

            // ----- Context Memory: Presence changes -----
            DaemonEvent::PresenceUpdate {
                present,
                user_state,
                ..
            } => {
                let state =
                    user_state
                        .as_deref()
                        .unwrap_or(if present { "present" } else { "absent" });
                // Only persist significant presence changes
                let mem = memory.read().await;
                let content = format!("What: User is now {}.", state);
                let tags = vec![
                    "sensory".to_string(),
                    "context".to_string(),
                    "presence".to_string(),
                ];
                mem.add_entry("context", "system", &tags, Some("presence"), 10, &content)
                    .await
                    .ok();
            }

            // ----- Wake word detected -----
            DaemonEvent::WakeWordDetected { word } => {
                let mem = memory.read().await;
                let content = format!("What: Wake word '{}' detected.", word);
                let tags = vec![
                    "sensory".to_string(),
                    "auditory".to_string(),
                    "wake_word".to_string(),
                ];
                mem.add_entry("auditory", "system", &tags, Some("wake_word"), 10, &content)
                    .await
                    .ok();
            }

            _ => {} // Ignore other events
        }
    }

    info!("[sensory_memory] Listener stopped");
}
