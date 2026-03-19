//! Daemon event bus for real-time UI updates (SSE, mini-widget).

use serde::Serialize;

/// Events broadcast to SSE subscribers and the GTK4 mini-widget.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", content = "data")]
#[serde(rename_all = "snake_case")]
pub enum DaemonEvent {
    AxiStateChanged {
        state: String,
        aura: String,
        reason: Option<String>,
    },
    SensorChanged {
        mic: bool,
        camera: bool,
        screen: bool,
        kill_switch: bool,
    },
    FeedbackUpdate {
        stage: Option<String>,
        tokens_per_second: Option<f32>,
        eta_ms: Option<u64>,
        audio_level: Option<f32>,
    },
    WindowChanged {
        app: String,
        title: String,
    },
    WakeWordDetected {
        word: String,
    },
    VoiceSessionStart,
    VoiceSessionEnd {
        transcript: Option<String>,
        response: Option<String>,
        latency_ms: Option<u64>,
    },
    ScreenCapture {
        app: Option<String>,
        summary: Option<String>,
    },
    MeetingStateChanged {
        active: bool,
        app: Option<String>,
    },
    PresenceUpdate {
        present: bool,
        user_state: Option<String>,
        people_count: Option<u8>,
    },
    Notification {
        priority: String,
        message: String,
    },
}
