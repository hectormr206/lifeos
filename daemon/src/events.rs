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
        always_on: Option<bool>,
        tts: Option<bool>,
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
    /// A calendar reminder became due. Channel bridges (Telegram, SimpleX,
    /// dashboard) subscribe to this and route the message back to the chat
    /// whose `chat_id` matches the reminder. Desktop widgets ignore this.
    ReminderDue {
        /// The channel's chat_id that created the reminder (encoded in the
        /// event's description field as `__chat:<id>`).
        chat_id: i64,
        title: String,
        event_id: String,
        start_time: String,
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
        // `recording_path` removed from the event payload — it leaked
        // the absolute on-disk location of the mic recording to every
        // event-bus subscriber (ws_gateway clients, sensory_memory,
        // future plugins). Consumers that need the path should query
        // meeting state directly via MeetingAssistant. Hearing audit C-12.
    },
    MeetingRecordingStopped {
        // `recording_path` removed for the same reason as Started.
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
    /// Privacy Mode toggle changed. Emitted from the dashboard POST handler
    /// and the tray click handler so both surfaces stay in sync.
    /// JSON shape: `{"type": "privacy_mode_changed", "data": {"enabled": true}}`.
    PrivacyModeChanged {
        enabled: bool,
    },
}
