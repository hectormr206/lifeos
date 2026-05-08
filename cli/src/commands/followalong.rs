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
use colored::Colorize;
use log::{error, info, warn};
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

// ==================== COMMAND IMPLEMENTATIONS ====================

pub async fn execute_followalong_command(cmd: FollowAlongCommands) -> Result<()> {
    match cmd {
        FollowAlongCommands::Status { json } => {
            show_status(json).await?;
        }
        FollowAlongCommands::Enable { disable } => {
            set_enabled(!disable).await?;
        }
        FollowAlongCommands::Consent { revoke } => {
            set_consent(!revoke).await?;
        }
        FollowAlongCommands::Context { json } => {
            show_context(json).await?;
        }
        FollowAlongCommands::Stats { json } => {
            show_stats(json).await?;
        }
        FollowAlongCommands::Summary { json } => {
            generate_summary(json).await?;
        }
        FollowAlongCommands::Translate { language, json } => {
            translate_summary(&language, json).await?;
        }
        FollowAlongCommands::Explain { question, json } => {
            explain_activity(&question, json).await?;
        }
        FollowAlongCommands::Clear { force } => {
            clear_events(force).await?;
        }
        FollowAlongCommands::Config {
            auto_summarize,
            auto_translate,
            auto_explain,
            interval,
        } => {
            set_config(auto_summarize, auto_translate, auto_explain, interval).await?;
        }
    }

    Ok(())
}

async fn show_status(json: bool) -> Result<()> {
    match daemon_client::get_json::<FollowAlongConfigResponse>("/api/v1/followalong/config").await {
        Ok(config) => {
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
        }
        Err(e) => {
            error!("Failed to get FollowAlong status: {}", e);
        }
    }

    Ok(())
}

async fn set_enabled(enabled: bool) -> Result<()> {
    #[derive(Serialize)]
    struct SetConfigRequest {
        enabled: bool,
    }

    let body = SetConfigRequest { enabled };

    daemon_client::post_json::<_, serde_json::Value>("/api/v1/followalong/config", &body).await?;

    if enabled {
        info!("FollowAlong enabled");
        println!("{}", "FollowAlong enabled".green());
    } else {
        info!("FollowAlong disabled");
        println!("{}", "FollowAlong disabled".yellow());
    }

    Ok(())
}

async fn set_consent(granted: bool) -> Result<()> {
    #[derive(Serialize)]
    struct ConsentRequest {
        granted: bool,
    }

    let body = ConsentRequest { granted };

    daemon_client::post_json::<_, serde_json::Value>("/api/v1/followalong/consent", &body).await?;

    if granted {
        info!("FollowAlong consent granted - monitoring will start");
        println!("{}", "FollowAlong consent granted".green());
    } else {
        info!("FollowAlong consent revoked - monitoring will stop");
        println!("{}", "FollowAlong consent revoked".yellow());
    }

    Ok(())
}

async fn show_context(json: bool) -> Result<()> {
    match daemon_client::get_json::<ContextStateResponse>("/api/v1/followalong/context").await {
        Ok(context) => {
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
        }
        Err(e) => {
            error!("Failed to get context: {}", e);
        }
    }

    Ok(())
}

async fn show_stats(json: bool) -> Result<()> {
    match daemon_client::get_json::<EventStatsResponse>("/api/v1/followalong/stats").await {
        Ok(stats) => {
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
        }
        Err(e) => {
            error!("Failed to get stats: {}", e);
        }
    }

    Ok(())
}

async fn generate_summary(json: bool) -> Result<()> {
    match daemon_client::post_empty::<SummaryResponse>("/api/v1/followalong/summary").await {
        Ok(summary) => {
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
        }
        Err(e) => {
            error!("Failed to generate summary: {}", e);
        }
    }

    Ok(())
}

async fn translate_summary(language: &str, json: bool) -> Result<()> {
    #[derive(Serialize)]
    struct TranslateRequest {
        target_language: String,
    }

    let body = TranslateRequest {
        target_language: language.to_string(),
    };

    match daemon_client::post_json::<_, SummaryResponse>("/api/v1/followalong/translate", &body)
        .await
    {
        Ok(summary) => {
            if json {
                println!("{}", serde_json::to_string_pretty(&summary)?);
            } else {
                println!("Translated Summary ({})", language);
                println!("Generated at: {}", summary.timestamp);
                println!("\n{}", summary.summary);
            }
        }
        Err(e) => {
            error!("Failed to translate summary: {}", e);
        }
    }

    Ok(())
}

async fn explain_activity(question: &str, json: bool) -> Result<()> {
    #[derive(Serialize)]
    struct ExplainRequest {
        question: String,
    }

    let body = ExplainRequest {
        question: question.to_string(),
    };

    match daemon_client::post_json::<_, ExplanationResponse>("/api/v1/followalong/explain", &body)
        .await
    {
        Ok(explanation) => {
            if json {
                println!("{}", serde_json::to_string_pretty(&explanation)?);
            } else {
                println!("Activity Explanation");
                println!("Question: {}", explanation.question);
                println!("Generated at: {}", explanation.timestamp);
                println!("\n{}", explanation.explanation);
            }
        }
        Err(e) => {
            error!("Failed to explain activity: {}", e);
        }
    }

    Ok(())
}

async fn clear_events(force: bool) -> Result<()> {
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

    match daemon_client::post_empty::<serde_json::Value>("/api/v1/followalong/clear").await {
        Ok(_) => {
            info!("Events cleared successfully");
        }
        Err(e) => {
            error!("Failed to clear events: {}", e);
        }
    }

    Ok(())
}

async fn set_config(
    auto_summarize: Option<bool>,
    auto_translate: Option<bool>,
    auto_explain: Option<bool>,
    interval: Option<u64>,
) -> Result<()> {
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

    match daemon_client::post_json::<_, serde_json::Value>("/api/v1/followalong/config", &body)
        .await
    {
        Ok(_) => {
            info!("FollowAlong configuration updated");
        }
        Err(e) => {
            error!("Failed to update config: {}", e);
        }
    }

    Ok(())
}
