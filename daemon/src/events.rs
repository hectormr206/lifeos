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
    MiniWidgetVisibilityChanged {
        visible: bool,
    },
    GameGuardChanged {
        game_detected: bool,
        game_name: Option<String>,
        llm_mode: String,
    },
    MeetingRecordingStarted {
        app_name: String,
        recording_path: String,
    },
    MeetingRecordingStopped {
        recording_path: Option<String>,
        duration_secs: u64,
    },
    // -- Events consumed by the dashboard (Fix AL / AP) ----------------------
    TaskCompleted {
        task_id: String,
        objective: String,
        result: String,
    },
    TaskFailed {
        task_id: String,
        objective: String,
        error: String,
    },
    SafeModeEntered {
        reason: String,
    },
    SafeModeExited,
    HealthCheck {
        status: String,
        issues: Vec<String>,
    },
    TelegramMessage {
        text: String,
        from: String,
    },
    WorkerStarted {
        id: String,
        task: String,
        started_at: String,
    },
    WorkerProgress {
        id: String,
        progress: f32,
        message: Option<String>,
    },
    WorkerCompleted {
        id: String,
        task: String,
        result: Option<String>,
    },
    WorkerFailed {
        id: String,
        task: String,
        error: String,
    },
}
