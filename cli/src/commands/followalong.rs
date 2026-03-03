//! FollowAlong Commands for LifeOS CLI
//!
//! Provides commands for managing FollowAlong:
//! - Enable/disable monitoring
//! - Consent management
//! - Activity summaries
//! - Translation and explanation
//! - Event statistics

use anyhow::Result;
use clap::Subcommand;
use log::{error, info, warn};
use reqwest::Client;
use serde::{Deserialize, Serialize};

use crate::daemon_client;

#[derive(Subcommand)]
#[clap(name = "followalong")]
#[clap(about = "Manage FollowAlong contextual AI assistant")]
pub enum FollowAlongCommands {
    /// Show FollowAlong status and configuration
    Status {
        #[clap(short, long)]
        json: bool,
    },

    /// Enable or disable FollowAlong
    Enable {
        #[clap(short, long)]
        disable: bool,
    },

    /// Grant or revoke consent for monitoring
    Consent {
        #[clap(short, long)]
        revoke: bool,
    },

    /// Get current context state
    Context {
        #[clap(short, long)]
        json: bool,
    },

    /// Get event statistics
    Stats {
        #[clap(short, long)]
        json: bool,
    },

    /// Generate activity summary
    Summary {
        #[clap(short, long)]
        json: bool,
    },

    /// Translate activity summary
    Translate {
        /// Target language (e.g., es, fr, de)
        language: String,

        #[clap(short, long)]
        json: bool,
    },

    /// Explain current activity
    Explain {
        /// Question to ask about current activity
        question: String,

        #[clap(short, long)]
        json: bool,
    },

    /// Clear events buffer
    Clear {
        #[clap(short, long)]
        force: bool,
    },

    /// Configure FollowAlong settings
    Config {
        #[clap(short = 's', long)]
        auto_summarize: Option<bool>,

        #[clap(short = 't', long)]
        auto_translate: Option<bool>,

        #[clap(short = 'e', long)]
        auto_explain: Option<bool>,

        #[clap(short, long)]
        interval: Option<u64>,
    },
}

// ==================== API RESPONSE STRUCTS ====================

#[derive(Debug, Deserialize, Serialize)]
struct FollowAlongConfigResponse {
    pub enabled: bool,
    #[serde(alias = "consentStatus")]
    pub consent_status: String,
    #[serde(alias = "autoSummarize")]
    pub auto_summarize: bool,
    #[serde(alias = "autoTranslate")]
    pub auto_translate: bool,
    #[serde(alias = "autoExplain")]
    pub auto_explain: bool,
    #[serde(alias = "summaryIntervalSeconds")]
    pub summary_interval_seconds: u64,
    #[serde(alias = "maxEventsBuffer")]
    pub max_events_buffer: usize,
}

#[derive(Debug, Deserialize, Serialize)]
struct ContextStateResponse {
    #[serde(alias = "currentApplication")]
    pub current_application: Option<String>,
    #[serde(alias = "currentWindow")]
    pub current_window: Option<String>,
    #[serde(alias = "activePattern")]
    pub active_pattern: Option<String>,
    #[serde(alias = "sessionDurationMinutes")]
    pub session_duration_minutes: i64,
    #[serde(alias = "lastEvent")]
    pub last_event: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
struct EventStatsResponse {
    #[serde(alias = "totalEvents")]
    pub total_events: usize,
    #[serde(alias = "eventCounts")]
    pub event_counts: Vec<EventCountInfo>,
    #[serde(alias = "currentApplication")]
    pub current_application: Option<String>,
    #[serde(alias = "currentWindow")]
    pub current_window: Option<String>,
    #[serde(alias = "sessionDurationMinutes")]
    pub session_duration_minutes: i64,
}

#[derive(Debug, Deserialize, Serialize)]
struct EventCountInfo {
    #[serde(alias = "eventType")]
    pub event_type: String,
    pub count: usize,
}

#[derive(Debug, Deserialize, Serialize)]
struct SummaryResponse {
    pub summary: String,
    pub timestamp: String,
    #[serde(alias = "eventCount")]
    pub event_count: usize,
    #[serde(alias = "sessionDurationMinutes")]
    pub session_duration_minutes: i64,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ExplanationResponse {
    pub explanation: String,
    pub question: String,
    pub timestamp: String,
}

#[derive(Debug, Deserialize)]
struct ApiError {
    pub error: String,
    pub message: String,
}

// ==================== HELPER FUNCTIONS ====================

fn get_api_url() -> String {
    daemon_client::daemon_url()
}

// ==================== COMMAND IMPLEMENTATIONS ====================

pub async fn execute_followalong_command(cmd: FollowAlongCommands) -> Result<()> {
    let client = daemon_client::authenticated_client();
    let api_url = get_api_url();

    match cmd {
        FollowAlongCommands::Status { json } => {
            show_status(&client, &api_url, json).await?;
        }
        FollowAlongCommands::Enable { disable } => {
            set_enabled(&client, &api_url, !disable).await?;
        }
        FollowAlongCommands::Consent { revoke } => {
            set_consent(&client, &api_url, !revoke).await?;
        }
        FollowAlongCommands::Context { json } => {
            show_context(&client, &api_url, json).await?;
        }
        FollowAlongCommands::Stats { json } => {
            show_stats(&client, &api_url, json).await?;
        }
        FollowAlongCommands::Summary { json } => {
            generate_summary(&client, &api_url, json).await?;
        }
        FollowAlongCommands::Translate { language, json } => {
            translate_summary(&client, &api_url, &language, json).await?;
        }
        FollowAlongCommands::Explain { question, json } => {
            explain_activity(&client, &api_url, &question, json).await?;
        }
        FollowAlongCommands::Clear { force } => {
            clear_events(&client, &api_url, force).await?;
        }
        FollowAlongCommands::Config {
            auto_summarize,
            auto_translate,
            auto_explain,
            interval,
        } => {
            set_config(
                &client,
                &api_url,
                auto_summarize,
                auto_translate,
                auto_explain,
                interval,
            )
            .await?;
        }
    }

    Ok(())
}

async fn show_status(client: &Client, api_url: &str, json: bool) -> Result<()> {
    let url = format!("{}/api/v1/followalong/config", api_url);
    let response = client.get(&url).send().await?;

    if response.status().is_success() {
        let config: FollowAlongConfigResponse = response.json().await?;
        if json {
            println!("{}", serde_json::to_string_pretty(&config)?);
        } else {
            println!("FollowAlong Status:");
            println!("  Enabled: {}", if config.enabled { "Yes" } else { "No" });
            println!("  Consent: {}", config.consent_status);
            println!(
                "  Auto Summarize: {}",
                if config.auto_summarize { "Yes" } else { "No" }
            );
            println!(
                "  Auto Translate: {}",
                if config.auto_translate { "Yes" } else { "No" }
            );
            println!(
                "  Auto Explain: {}",
                if config.auto_explain { "Yes" } else { "No" }
            );
            println!(
                "  Summary Interval: {} seconds",
                config.summary_interval_seconds
            );
            println!("  Max Events Buffer: {}", config.max_events_buffer);
        }
    } else {
        error!("Failed to get FollowAlong status: {}", response.status());
    }

    Ok(())
}

async fn set_enabled(client: &Client, api_url: &str, enabled: bool) -> Result<()> {
    let url = format!("{}/api/v1/followalong/config", api_url);

    #[derive(Serialize)]
    struct SetConfigRequest {
        enabled: bool,
    }

    let body = SetConfigRequest { enabled };

    let response = client.post(&url).json(&body).send().await?;

    if response.status().is_success() {
        if enabled {
            info!("FollowAlong enabled");
        } else {
            info!("FollowAlong disabled");
        }
    } else {
        let error: ApiError = response.json().await?;
        error!(
            "Failed to set enabled status: {} - {}",
            error.error, error.message
        );
    }

    Ok(())
}

async fn set_consent(client: &Client, api_url: &str, granted: bool) -> Result<()> {
    let url = format!("{}/api/v1/followalong/consent", api_url);

    #[derive(Serialize)]
    struct ConsentRequest {
        granted: bool,
    }

    let body = ConsentRequest { granted };

    let response = client.post(&url).json(&body).send().await?;

    if response.status().is_success() {
        if granted {
            info!("FollowAlong consent granted - monitoring will start");
        } else {
            info!("FollowAlong consent revoked - monitoring will stop");
        }
    } else {
        let error: ApiError = response.json().await?;
        error!("Failed to set consent: {} - {}", error.error, error.message);
    }

    Ok(())
}

async fn show_context(client: &Client, api_url: &str, json: bool) -> Result<()> {
    let url = format!("{}/api/v1/followalong/context", api_url);
    let response = client.get(&url).send().await?;

    if response.status().is_success() {
        let context: ContextStateResponse = response.json().await?;
        if json {
            println!("{}", serde_json::to_string_pretty(&context)?);
        } else {
            println!("Current Context:");
            if let Some(app) = &context.current_application {
                println!("  Application: {}", app);
            } else {
                println!("  Application: (not detected)");
            }
            if let Some(window) = &context.current_window {
                println!("  Window: {}", window);
            } else {
                println!("  Window: (not detected)");
            }
            if let Some(pattern) = &context.active_pattern {
                println!("  Active Pattern: {}", pattern);
            } else {
                println!("  Active Pattern: (none)");
            }
            println!(
                "  Session Duration: {} minutes",
                context.session_duration_minutes
            );
            if let Some(last) = &context.last_event {
                println!("  Last Event: {}", last);
            } else {
                println!("  Last Event: (none)");
            }
        }
    } else {
        error!("Failed to get context: {}", response.status());
    }

    Ok(())
}

async fn show_stats(client: &Client, api_url: &str, json: bool) -> Result<()> {
    let url = format!("{}/api/v1/followalong/stats", api_url);
    let response = client.get(&url).send().await?;

    if response.status().is_success() {
        let stats: EventStatsResponse = response.json().await?;
        if json {
            println!("{}", serde_json::to_string_pretty(&stats)?);
        } else {
            println!("Event Statistics:");
            println!("  Total Events: {}", stats.total_events);
            if let Some(app) = &stats.current_application {
                println!("  Current Application: {}", app);
            }
            if let Some(window) = &stats.current_window {
                println!("  Current Window: {}", window);
            }
            println!(
                "  Session Duration: {} minutes",
                stats.session_duration_minutes
            );
            println!("\nEvent Breakdown:");
            for event in &stats.event_counts {
                println!("  - {}: {}", event.event_type, event.count);
            }
        }
    } else {
        error!("Failed to get stats: {}", response.status());
    }

    Ok(())
}

async fn generate_summary(client: &Client, api_url: &str, json: bool) -> Result<()> {
    let url = format!("{}/api/v1/followalong/summary", api_url);
    let response = client.post(&url).send().await?;

    if response.status().is_success() {
        let summary: SummaryResponse = response.json().await?;
        if json {
            println!("{}", serde_json::to_string_pretty(&summary)?);
        } else {
            println!("Activity Summary");
            println!("Generated at: {}", summary.timestamp);
            println!("Events included: {}", summary.event_count);
            println!(
                "Session duration: {} minutes",
                summary.session_duration_minutes
            );
            println!("\n{}", summary.summary);
        }
    } else {
        error!("Failed to generate summary: {}", response.status());
    }

    Ok(())
}

async fn translate_summary(
    client: &Client,
    api_url: &str,
    language: &str,
    json: bool,
) -> Result<()> {
    let url = format!("{}/api/v1/followalong/translate", api_url);

    #[derive(Serialize)]
    struct TranslateRequest {
        target_language: String,
    }

    let body = TranslateRequest {
        target_language: language.to_string(),
    };

    let response = client.post(&url).json(&body).send().await?;

    if response.status().is_success() {
        let summary: SummaryResponse = response.json().await?;
        if json {
            println!("{}", serde_json::to_string_pretty(&summary)?);
        } else {
            println!("Translated Summary ({})", language);
            println!("Generated at: {}", summary.timestamp);
            println!("\n{}", summary.summary);
        }
    } else {
        error!("Failed to translate summary: {}", response.status());
    }

    Ok(())
}

async fn explain_activity(
    client: &Client,
    api_url: &str,
    question: &str,
    json: bool,
) -> Result<()> {
    let url = format!("{}/api/v1/followalong/explain", api_url);

    #[derive(Serialize)]
    struct ExplainRequest {
        question: String,
    }

    let body = ExplainRequest {
        question: question.to_string(),
    };

    let response = client.post(&url).json(&body).send().await?;

    if response.status().is_success() {
        let explanation: ExplanationResponse = response.json().await?;
        if json {
            println!("{}", serde_json::to_string_pretty(&explanation)?);
        } else {
            println!("Activity Explanation");
            println!("Question: {}", explanation.question);
            println!("Generated at: {}", explanation.timestamp);
            println!("\n{}", explanation.explanation);
        }
    } else {
        error!("Failed to explain activity: {}", response.status());
    }

    Ok(())
}

async fn clear_events(client: &Client, api_url: &str, force: bool) -> Result<()> {
    if !force {
        warn!("Clearing events will remove all recorded activity");
        print!("Continue? [y/N]: ");
        std::io::Write::flush(&mut std::io::stdout())?;

        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;
        if !input.trim().to_lowercase().starts_with('y') {
            info!("Clear cancelled");
            return Ok(());
        }
    }

    let url = format!("{}/api/v1/followalong/clear", api_url);
    let response = client.post(&url).send().await?;

    if response.status().is_success() {
        info!("Events cleared successfully");
    } else {
        error!("Failed to clear events: {}", response.status());
    }

    Ok(())
}

async fn set_config(
    client: &Client,
    api_url: &str,
    auto_summarize: Option<bool>,
    auto_translate: Option<bool>,
    auto_explain: Option<bool>,
    interval: Option<u64>,
) -> Result<()> {
    let url = format!("{}/api/v1/followalong/config", api_url);

    #[derive(Serialize)]
    struct ConfigRequest {
        #[serde(skip_serializing_if = "Option::is_none")]
        auto_summarize: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        auto_translate: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        auto_explain: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        summary_interval_seconds: Option<u64>,
    }

    let body = ConfigRequest {
        auto_summarize,
        auto_translate,
        auto_explain,
        summary_interval_seconds: interval,
    };

    let response = client.post(&url).json(&body).send().await?;

    if response.status().is_success() {
        info!("FollowAlong configuration updated");
    } else {
        let error: ApiError = response.json().await?;
        error!(
            "Failed to update config: {} - {}",
            error.error, error.message
        );
    }

    Ok(())
}
