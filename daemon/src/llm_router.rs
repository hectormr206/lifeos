//! LLM Router — Multi-provider routing with privacy-aware selection.
//!
//! Routes requests to the optimal LLM provider based on task complexity,
//! data sensitivity, cost, and availability. Supports local (llama-server),
//! Gemini free tier, OpenRouter free, GLM free, and paid providers.

use anyhow::{bail, Context, Result};
use log::{info, warn};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use crate::privacy_filter::{PrivacyFilter, PrivacyLevel, SensitivityLevel};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Task complexity hint — the router uses this to pick a provider tier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskComplexity {
    Simple,
    Medium,
    Complex,
    Coding,
    Vision,
}

/// Task type classification — the router uses this to prefer providers
/// with the right capabilities for the job. Orthogonal to complexity:
/// complexity says HOW HARD, task type says WHAT KIND.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskType {
    /// Complex logic, planning, code analysis — prefer large reasoning models
    Reasoning,
    /// Image analysis, screenshot understanding — prefer vision-capable models
    Vision,
    /// Simple responses, translations, formatting — prefer fast local/cheap models
    Quick,
    /// Summarization of long documents — prefer large-context models (Gemini, etc.)
    LongContext,
    /// Writing, brainstorming, creative content — prefer Claude or GPT-4
    Creative,
    /// No special routing preference
    Default,
}

/// A chat message in OpenAI format.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: String,
    pub content: serde_json::Value,
}

/// Request sent to the router.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RouterRequest {
    pub messages: Vec<ChatMessage>,
    #[serde(default)]
    pub complexity: Option<TaskComplexity>,
    #[serde(default)]
    pub sensitivity: Option<SensitivityLevel>,
    #[serde(default)]
    pub preferred_provider: Option<String>,
    #[serde(default)]
    pub max_tokens: Option<u32>,
    /// Optional task type hint. If `None`, the router auto-classifies from messages.
    #[serde(default)]
    pub task_type: Option<TaskType>,
}

/// Response returned by the router.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RouterResponse {
    pub text: String,
    pub provider: String,
    pub model: String,
    pub tokens_used: Option<u32>,
    pub latency_ms: u64,
    pub cached: bool,
}

/// Cost tracking for a provider.
#[derive(Debug, Default)]
pub struct ProviderCostTracker {
    #[allow(dead_code)]
    pub total_input_tokens: AtomicU64,
    pub total_output_tokens: AtomicU64,
    pub total_requests: AtomicU64,
    pub total_failures: AtomicU64,
}

// ---------------------------------------------------------------------------
// Provider configuration
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderConfig {
    pub name: String,
    pub api_base: String,
    #[serde(default)]
    pub api_key_env: String,
    pub model: String,
    pub api_format: ApiFormat,
    #[serde(default)]
    pub cost_input_per_m: f64,
    #[serde(default)]
    pub cost_output_per_m: f64,
    #[serde(default)]
    pub max_rpm: Option<u32>,
    #[serde(default)]
    pub max_rpd: Option<u32>,
    #[serde(default)]
    pub supports_vision: bool,
    #[serde(default = "default_context")]
    pub max_context: u32,
    #[serde(default)]
    pub tier: ProviderTier,
    #[serde(default)]
    pub chat_path: Option<String>,
    #[serde(default)]
    pub privacy: String,
}

fn default_context() -> u32 {
    128_000
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApiFormat {
    OpenAiCompatible,
    Gemini,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderTier {
    Local,
    #[default]
    Free,
    Cheap,
    Premium,
}

// ---------------------------------------------------------------------------
// Task type classification
// ---------------------------------------------------------------------------

/// Classify the task type from message content using simple heuristics.
/// This is a best-effort classifier — it doesn't need to be perfect,
/// just good enough to route most requests to a better-suited provider.
pub fn classify_task_type(messages: &[ChatMessage]) -> TaskType {
    // Collect all user message text for analysis
    let mut total_len = 0usize;
    let mut has_image_content = false;
    let mut combined_text = String::new();

    for msg in messages {
        if msg.role == "user" {
            // Check for image content (OpenAI vision format: array with image_url parts)
            if let Some(arr) = msg.content.as_array() {
                for part in arr {
                    if part.get("type").and_then(|t| t.as_str()) == Some("image_url") {
                        has_image_content = true;
                    }
                    if let Some(text) = part.get("text").and_then(|t| t.as_str()) {
                        total_len += text.len();
                        combined_text.push(' ');
                        combined_text.push_str(text);
                    }
                }
            } else if let Some(text) = msg.content.as_str() {
                total_len += text.len();
                combined_text.push(' ');
                combined_text.push_str(text);
            }
        }
    }

    // Rule 1: Image data present → Vision
    if has_image_content {
        return TaskType::Vision;
    }

    let lower = combined_text.to_lowercase();

    // Rule 2: Mentions of images/screenshots in text → Vision
    let vision_keywords = [
        "screenshot",
        "image",
        "picture",
        "photo",
        "diagram",
        "captura",
        "imagen",
        "foto",
    ];
    if vision_keywords.iter().any(|kw| lower.contains(kw)) {
        // Only if they're asking to analyze/look at something, not just mentioning the word
        let vision_action = [
            "analyze",
            "look at",
            "what's in",
            "describe",
            "analiza",
            "mira",
            "qué hay",
            "qué ves",
        ];
        if vision_action.iter().any(|kw| lower.contains(kw)) {
            return TaskType::Vision;
        }
    }

    // Rule 3: Long content → LongContext
    if total_len > 8000 {
        return TaskType::LongContext;
    }

    // Rule 4: Reasoning keywords
    let reasoning_keywords = [
        "plan",
        "analyze",
        "debug",
        "architecture",
        "refactor",
        "explain why",
        "compare",
        "evaluate",
        "trade-off",
        "tradeoff",
        "analiza",
        "planifica",
        "depura",
        "arquitectura",
    ];
    if reasoning_keywords.iter().any(|kw| lower.contains(kw)) {
        return TaskType::Reasoning;
    }

    // Rule 5: Creative keywords
    let creative_keywords = [
        "write",
        "create",
        "brainstorm",
        "draft",
        "compose",
        "story",
        "poem",
        "essay",
        "redacta",
        "escribe",
        "crea",
        "borrador",
    ];
    if creative_keywords.iter().any(|kw| lower.contains(kw)) {
        return TaskType::Creative;
    }

    // Rule 6: Short, single-turn → Quick
    let user_messages = messages.iter().filter(|m| m.role == "user").count();
    if user_messages <= 1 && total_len < 100 {
        return TaskType::Quick;
    }

    TaskType::Default
}

/// Compute a task-type affinity bonus for a provider (0-50).
/// This is added to the complexity-based score as a SOFT preference.
fn task_type_bonus(provider: &ProviderConfig, task_type: TaskType) -> u32 {
    match task_type {
        TaskType::Vision => {
            if provider.supports_vision {
                40
            } else {
                0
            }
        }
        TaskType::LongContext => {
            if provider.max_context >= 500_000 {
                50 // Gemini-class context
            } else if provider.max_context >= 200_000 {
                30
            } else {
                0
            }
        }
        TaskType::Quick => {
            match provider.tier {
                ProviderTier::Local => 40, // fastest, no network
                ProviderTier::Free => {
                    // Small fast models get a boost
                    let model_lower = provider.model.to_lowercase();
                    if model_lower.contains("8b") || model_lower.contains("nano") {
                        30
                    } else {
                        10
                    }
                }
                _ => 0,
            }
        }
        TaskType::Reasoning => {
            let name_lower = provider.name.to_lowercase();
            let model_lower = provider.model.to_lowercase();
            if name_lower.contains("anthropic") || name_lower.contains("claude") {
                50
            } else if name_lower.contains("openai") || model_lower.contains("gpt") {
                45
            } else if model_lower.contains("qwen") && model_lower.contains("235b") {
                40 // Large MoE reasoning model
            } else if model_lower.contains("70b") || model_lower.contains("120b") {
                30
            } else {
                0
            }
        }
        TaskType::Creative => {
            let name_lower = provider.name.to_lowercase();
            let model_lower = provider.model.to_lowercase();
            if name_lower.contains("anthropic") || name_lower.contains("claude") {
                50
            } else if name_lower.contains("openai") || model_lower.contains("gpt") {
                45
            } else if model_lower.contains("70b") || model_lower.contains("235b") {
                25
            } else {
                0
            }
        }
        TaskType::Default => 0, // No bonus — use complexity scoring only
    }
}

// ---------------------------------------------------------------------------
// LLM Router
// ---------------------------------------------------------------------------

pub struct LlmRouter {
    providers: Vec<ProviderConfig>,
    cost_trackers: HashMap<String, ProviderCostTracker>,
    http: reqwest::Client,
    privacy_level: PrivacyLevel,
}

impl LlmRouter {
    pub fn new(privacy_level: PrivacyLevel) -> Self {
        let all_providers = load_providers_from_toml().unwrap_or_else(|e| {
            info!("No providers.toml found ({}), using built-in defaults", e);
            default_providers()
        });
        // Filter: only keep providers whose API key env var is set (or empty = local)
        let providers: Vec<ProviderConfig> = all_providers
            .into_iter()
            .filter(|p| {
                p.api_key_env.is_empty()
                    || std::env::var(&p.api_key_env)
                        .map(|v| !v.is_empty())
                        .unwrap_or(false)
            })
            .collect();
        info!(
            "[llm_router] {} active providers (with API keys configured)",
            providers.len()
        );
        let cost_trackers = providers
            .iter()
            .map(|p| (p.name.clone(), ProviderCostTracker::default()))
            .collect();

        Self {
            providers,
            cost_trackers,
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(120))
                .build()
                .expect("failed to build HTTP client"),
            privacy_level,
        }
    }

    /// Route a chat request with **local-first escalation**.
    ///
    /// Flow:
    /// 1. If sensitivity is `Critical` → local-only (no escalation).
    /// 2. Otherwise → try Local tier first. If `should_escalate()` flags the
    ///    response as weak/unknown/unsuitable, re-run once forcing `Free` tier.
    /// 3. Capped at ONE escalation step (local → free) to avoid cost cascades.
    ///
    /// Toggle via env `LIFEOS_LLM_ESCALATION_ENABLED=false` to disable (default: true).
    pub async fn chat_with_escalation(&self, request: &RouterRequest) -> Result<RouterResponse> {
        let enabled = std::env::var("LIFEOS_LLM_ESCALATION_ENABLED")
            .map(|v| !matches!(v.as_str(), "0" | "false" | "no"))
            .unwrap_or(true);
        if !enabled {
            return self.chat(request).await;
        }

        let sensitivity = request.sensitivity.unwrap_or(SensitivityLevel::Low);

        // Voice / privacy-critical → never escalate. Local tier only.
        if matches!(sensitivity, SensitivityLevel::Critical) {
            info!("[llm_router] escalation skipped (sensitivity=Critical) — me quedo local");
            return self.chat(request).await;
        }

        // Round 1: force local tier — but ONLY if the caller didn't already
        // pin a provider. Respect explicit caller intent; escalation still
        // triggers on weakness below.
        let mut local_req = request.clone();
        if local_req.preferred_provider.is_none() {
            let local_name = self
                .providers
                .iter()
                .find(|p| p.tier == ProviderTier::Local)
                .map(|p| p.name.clone());
            if let Some(ref name) = local_name {
                local_req.preferred_provider = Some(name.clone());
            }
        }

        let local_resp = match self.chat(&local_req).await {
            Ok(r) => r,
            Err(e) => {
                // Local unavailable — escalate directly to Free tier.
                info!(
                    "[llm_router] escalación: local cayó ({}) — voy directo al tier Free, dale",
                    e
                );
                return self.chat_forced_free(request).await;
            }
        };

        // Only consider escalation if we actually hit a Local-tier provider.
        let hit_local = self
            .providers
            .iter()
            .any(|p| p.name == local_resp.provider && p.tier == ProviderTier::Local);

        if !hit_local {
            return Ok(local_resp);
        }

        if should_escalate(&local_resp) {
            info!(
                "[llm_router] escalando a Free: local respondió flojito (len={}, provider={}). \
                 Locura cósmica, pedimos refuerzo.",
                local_resp.text.len(),
                local_resp.provider
            );
            match self.chat_forced_free(request).await {
                Ok(r) => Ok(r),
                Err(e) => {
                    warn!(
                        "[llm_router] Free también falló ({}). Me quedo con la respuesta local, aunque sea débil.",
                        e
                    );
                    Ok(local_resp)
                }
            }
        } else {
            Ok(local_resp)
        }
    }

    /// Retry the request, but bias toward the Free tier by excluding Local preference.
    async fn chat_forced_free(&self, request: &RouterRequest) -> Result<RouterResponse> {
        let mut req = request.clone();
        // Pick first available Free-tier provider as the preferred target.
        if let Some(free) = self
            .providers
            .iter()
            .find(|p| p.tier == ProviderTier::Free)
        {
            req.preferred_provider = Some(free.name.clone());
        } else {
            req.preferred_provider = None;
        }
        self.chat(&req).await
    }

    /// Route a chat request to the best available provider.
    pub async fn chat(&self, request: &RouterRequest) -> Result<RouterResponse> {
        let complexity = request.complexity.unwrap_or(TaskComplexity::Medium);
        let filter = PrivacyFilter::new(self.privacy_level);

        // P0-1: Sanitize all user message content before sending to any provider
        let mut sanitized_request = request.clone();
        let mut highest_sensitivity = request.sensitivity.unwrap_or(SensitivityLevel::Low);

        for msg in &mut sanitized_request.messages {
            if msg.role == "user" {
                if let Some(text) = msg.content.as_str() {
                    let result = filter.sanitize(text);
                    if result.sensitivity > highest_sensitivity {
                        highest_sensitivity = result.sensitivity;
                    }
                    msg.content = serde_json::Value::String(result.sanitized_text);
                }
            }
        }

        // Use the detected sensitivity (highest between explicit and classified)
        let sensitivity = highest_sensitivity;

        // Auto-classify task type if not explicitly provided
        let task_type = request
            .task_type
            .unwrap_or_else(|| classify_task_type(&request.messages));

        let candidates = self.select_candidates(
            complexity,
            sensitivity,
            &sanitized_request.preferred_provider,
            task_type,
        );

        if candidates.is_empty() {
            if complexity == TaskComplexity::Vision {
                bail!(
                    "NO_VISION_AVAILABLE: No puedo analizar imagenes en este momento. \
                     Ningun proveedor de vision esta disponible (modelo local apagado o sin API key de vision). \
                     Intenta describir la imagen con texto."
                );
            }
            bail!(
                "No LLM providers available for complexity={:?} sensitivity={:?}",
                complexity,
                sensitivity
            );
        }

        info!(
            "[llm_router] {} candidates for complexity={:?} sensitivity={:?} task={:?}: {}",
            candidates.len(),
            complexity,
            sensitivity,
            task_type,
            candidates
                .iter()
                .map(|p| p.name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );

        let mut last_error = None;

        for provider in &candidates {
            // P0-2: Check if content is safe for this provider's tier
            if !filter.is_safe_for_tier(sensitivity, provider.tier) {
                info!(
                    "[llm_router] skipping {} — content too sensitive for {:?} tier",
                    provider.name, provider.tier
                );
                continue;
            }

            info!("[llm_router] trying provider: {}", provider.name);
            let start = Instant::now();
            match self.call_provider(provider, &sanitized_request).await {
                Ok(mut response) => {
                    response.latency_ms = start.elapsed().as_millis() as u64;
                    if let Some(tracker) = self.cost_trackers.get(&provider.name) {
                        tracker.total_requests.fetch_add(1, Ordering::Relaxed);
                        if let Some(tokens) = response.tokens_used {
                            tracker
                                .total_output_tokens
                                .fetch_add(tokens as u64, Ordering::Relaxed);
                        }
                    }
                    info!(
                        "LLM router: {} ({}) responded in {}ms",
                        provider.name, provider.model, response.latency_ms
                    );
                    return Ok(response);
                }
                Err(e) => {
                    warn!("LLM router: {} failed: {}", provider.name, e);
                    if let Some(tracker) = self.cost_trackers.get(&provider.name) {
                        tracker.total_failures.fetch_add(1, Ordering::Relaxed);
                    }
                    last_error = Some(e);
                }
            }
        }

        Err(last_error.unwrap_or_else(|| anyhow::anyhow!("All providers failed")))
    }

    /// Select candidate providers in priority order.
    /// Task type adds a soft scoring bonus to prefer providers with matching capabilities.
    fn select_candidates(
        &self,
        complexity: TaskComplexity,
        sensitivity: SensitivityLevel,
        preferred: &Option<String>,
        task_type: TaskType,
    ) -> Vec<&ProviderConfig> {
        // If user specified a provider, try it first
        let mut candidates: Vec<&ProviderConfig> = Vec::new();

        if let Some(name) = preferred {
            if let Some(p) = self.providers.iter().find(|p| p.name == *name) {
                candidates.push(p);
            }
        }

        // Filter by sensitivity constraints
        let allowed_tiers = match (&self.privacy_level, sensitivity) {
            (PrivacyLevel::Paranoid, _) => vec![ProviderTier::Local],
            (_, SensitivityLevel::Critical) => vec![ProviderTier::Local],
            (_, SensitivityLevel::High) => vec![ProviderTier::Local, ProviderTier::Premium],
            (PrivacyLevel::Careful, SensitivityLevel::Medium) => {
                vec![
                    ProviderTier::Local,
                    ProviderTier::Free,
                    ProviderTier::Premium,
                ]
            }
            _ => vec![
                ProviderTier::Local,
                ProviderTier::Free,
                ProviderTier::Cheap,
                ProviderTier::Premium,
            ],
        };

        // Block low-privacy providers (Gemini free, Chinese) for sensitive data
        let block_low_privacy = matches!(
            sensitivity,
            SensitivityLevel::Medium | SensitivityLevel::High | SensitivityLevel::Critical
        );

        // Score providers by suitability for this complexity
        let mut scored: Vec<(&ProviderConfig, u32)> = self
            .providers
            .iter()
            .filter(|p| allowed_tiers.contains(&p.tier))
            .filter(|p| {
                !(block_low_privacy
                    && (p.privacy.eq_ignore_ascii_case("low")
                        || p.privacy.eq_ignore_ascii_case("variable")))
            })
            .filter(|p| !candidates.iter().any(|c| c.name == p.name))
            .map(|p| {
                let score = match complexity {
                    TaskComplexity::Simple => match p.tier {
                        ProviderTier::Local => 100,
                        ProviderTier::Free => 80,
                        ProviderTier::Cheap => 60,
                        ProviderTier::Premium => 20,
                    },
                    TaskComplexity::Medium => match p.tier {
                        ProviderTier::Free => 100,
                        ProviderTier::Local => 70,
                        ProviderTier::Cheap => 90,
                        ProviderTier::Premium => 50,
                    },
                    TaskComplexity::Complex => match p.tier {
                        ProviderTier::Premium => 100,
                        ProviderTier::Cheap => 90,
                        ProviderTier::Free => 70,
                        ProviderTier::Local => 30,
                    },
                    TaskComplexity::Coding => match p.tier {
                        ProviderTier::Free => 100,
                        ProviderTier::Cheap => 90,
                        ProviderTier::Premium => 80,
                        ProviderTier::Local => 40,
                    },
                    TaskComplexity::Vision => {
                        if p.supports_vision {
                            match p.tier {
                                ProviderTier::Local => 100,
                                ProviderTier::Free => 80,
                                ProviderTier::Cheap => 90,
                                ProviderTier::Premium => 70,
                            }
                        } else {
                            0
                        }
                    }
                };
                // Add task-type affinity bonus (soft preference, doesn't eliminate anyone)
                let bonus = task_type_bonus(p, task_type);
                (p, score + bonus)
            })
            .filter(|(_, score)| *score > 0)
            .collect();

        scored.sort_by(|a, b| b.1.cmp(&a.1));
        candidates.extend(scored.into_iter().map(|(p, _)| p));
        candidates
    }

    /// Call a single provider with the request.
    async fn call_provider(
        &self,
        provider: &ProviderConfig,
        request: &RouterRequest,
    ) -> Result<RouterResponse> {
        let api_key = std::env::var(&provider.api_key_env).unwrap_or_default();

        match provider.api_format {
            ApiFormat::OpenAiCompatible => {
                self.call_openai_compatible(provider, request, &api_key)
                    .await
            }
            ApiFormat::Gemini => self.call_gemini(provider, request, &api_key).await,
        }
    }

    /// Call an OpenAI-compatible endpoint (works for local llama-server, DeepSeek,
    /// OpenRouter, GLM, Kimi, MiniMax, and OpenAI itself).
    async fn call_openai_compatible(
        &self,
        provider: &ProviderConfig,
        request: &RouterRequest,
        api_key: &str,
    ) -> Result<RouterResponse> {
        let path = provider
            .chat_path
            .as_deref()
            .unwrap_or("/v1/chat/completions");
        let url = format!("{}{}", provider.api_base, path);

        let payload = serde_json::json!({
            "model": provider.model,
            "messages": request.messages,
            "max_tokens": request.max_tokens.unwrap_or(2048),
            "stream": false,
        });

        let mut req = self.http.post(&url).json(&payload);

        if !api_key.is_empty() {
            req = req.bearer_auth(api_key);
        }

        let response = req
            .send()
            .await
            .context(format!("request to {} failed", provider.name))?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();

            // Auto-discovery: if model not found, try to find the correct model name
            if (status.as_u16() == 404 || status.as_u16() == 400)
                && (body.contains("model_not_found")
                    || body.contains("does not exist")
                    || body.contains("not found"))
            {
                warn!(
                    "[llm_router] Model '{}' not found on {}. Attempting auto-discovery...",
                    provider.model, provider.name
                );
                if let Some(new_model) = self.discover_replacement_model(provider, api_key).await {
                    warn!(
                        "[llm_router] Found replacement model: '{}' → '{}'. \
                         Update your config or dashboard. Using fallback for this request.",
                        provider.model, new_model
                    );
                    // Retry with discovered model
                    let mut new_payload = payload.clone();
                    new_payload["model"] = serde_json::Value::String(new_model.clone());
                    let mut retry_req = self.http.post(&url).json(&new_payload);
                    if !api_key.is_empty() {
                        retry_req = retry_req.bearer_auth(api_key);
                    }
                    let retry_resp = retry_req.send().await?;
                    if retry_resp.status().is_success() {
                        let retry_body: serde_json::Value = retry_resp.json().await?;
                        let msg = &retry_body["choices"][0]["message"];
                        let raw_text = msg["content"]
                            .as_str()
                            .filter(|s| !s.is_empty())
                            .or_else(|| msg["reasoning_content"].as_str())
                            .unwrap_or("")
                            .to_string();
                        let text = strip_think_tags(&raw_text);
                        let text = strip_reasoning_loop(&text);
                        let tokens_used = retry_body["usage"]["total_tokens"]
                            .as_u64()
                            .and_then(|t| u32::try_from(t).ok());
                        return Ok(RouterResponse {
                            text,
                            provider: format!("{} (auto-discovered: {})", provider.name, new_model),
                            model: new_model,
                            tokens_used,
                            latency_ms: 0,
                            cached: false,
                        });
                    }
                }
            }

            bail!(
                "{} returned {}: {}",
                provider.name,
                status,
                crate::str_utils::truncate_bytes_safe(&body, 200)
            );
        }

        let body: serde_json::Value = response.json().await?;

        // Some models (Qwen3.5 with --jinja) put output in reasoning_content instead of content
        let msg = &body["choices"][0]["message"];
        let raw_text = msg["content"]
            .as_str()
            .filter(|s| !s.is_empty())
            .or_else(|| msg["reasoning_content"].as_str())
            .unwrap_or("")
            .to_string();

        // Strip <think>...</think> blocks and degenerate reasoning loops
        let text = strip_think_tags(&raw_text);
        let text = strip_reasoning_loop(&text);

        let tokens_used = body["usage"]["total_tokens"]
            .as_u64()
            .and_then(|t| u32::try_from(t).ok());

        Ok(RouterResponse {
            text,
            provider: provider.name.clone(),
            model: provider.model.clone(),
            tokens_used,
            latency_ms: 0,
            cached: false,
        })
    }

    /// Call Google Gemini API (different format from OpenAI).
    async fn call_gemini(
        &self,
        provider: &ProviderConfig,
        request: &RouterRequest,
        api_key: &str,
    ) -> Result<RouterResponse> {
        if api_key.is_empty() {
            bail!("Gemini API key not set ({})", provider.api_key_env);
        }

        let url = format!(
            "{}/v1beta/models/{}:generateContent?key={}",
            provider.api_base, provider.model, api_key
        );

        // Convert OpenAI-format messages to Gemini format
        let mut contents = Vec::new();
        let mut system_instruction = None;

        for msg in &request.messages {
            match msg.role.as_str() {
                "system" => {
                    let text = msg.content.as_str().unwrap_or("").to_string();
                    system_instruction = Some(serde_json::json!({
                        "parts": [{ "text": text }]
                    }));
                }
                "user" | "assistant" => {
                    let role = if msg.role == "assistant" {
                        "model"
                    } else {
                        "user"
                    };
                    let text = msg.content.as_str().unwrap_or("").to_string();
                    contents.push(serde_json::json!({
                        "role": role,
                        "parts": [{ "text": text }]
                    }));
                }
                _ => {}
            }
        }

        let mut payload = serde_json::json!({
            "contents": contents,
            "generationConfig": {
                "maxOutputTokens": request.max_tokens.unwrap_or(2048),
            }
        });

        if let Some(sys) = system_instruction {
            payload["systemInstruction"] = sys;
        }

        let response = self.http.post(&url).json(&payload).send().await?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            bail!(
                "Gemini returned {}: {}",
                status,
                crate::str_utils::truncate_bytes_safe(&body, 200)
            );
        }

        let body: serde_json::Value = response.json().await?;

        let text = body["candidates"][0]["content"]["parts"][0]["text"]
            .as_str()
            .unwrap_or("")
            .to_string();

        let tokens_used = body["usageMetadata"]["totalTokenCount"]
            .as_u64()
            .and_then(|t| u32::try_from(t).ok());

        Ok(RouterResponse {
            text,
            provider: provider.name.clone(),
            model: provider.model.clone(),
            tokens_used,
            latency_ms: 0,
            cached: false,
        })
    }

    /// Get cost summary per provider.
    pub fn cost_summary(&self) -> Vec<(String, u64, u64, u64)> {
        self.cost_trackers
            .iter()
            .map(|(name, tracker)| {
                (
                    name.clone(),
                    tracker.total_requests.load(Ordering::Relaxed),
                    tracker.total_output_tokens.load(Ordering::Relaxed),
                    tracker.total_failures.load(Ordering::Relaxed),
                )
            })
            .collect()
    }

    /// Return a snapshot of all active provider configurations.
    pub fn provider_configs(&self) -> &[ProviderConfig] {
        &self.providers
    }

    /// Return the configured privacy level.
    pub fn privacy_level(&self) -> PrivacyLevel {
        self.privacy_level
    }

    /// Reload providers from the TOML config file.
    /// Called via API endpoint or SIGHUP signal.
    pub fn reload_providers(&mut self) -> Result<usize> {
        let providers = load_providers_from_toml().unwrap_or_else(|e| {
            warn!(
                "[llm_router] Failed to reload TOML ({}), using default providers",
                e
            );
            default_providers()
        });
        let count = providers.len();
        // Rebuild cost trackers for new provider set
        let cost_trackers = providers
            .iter()
            .map(|p| (p.name.clone(), ProviderCostTracker::default()))
            .collect();
        self.providers = providers;
        self.cost_trackers = cost_trackers;
        info!("[llm_router] Reloaded {} providers", count);
        Ok(count)
    }
}

// ---------------------------------------------------------------------------
// SSRF guard — validate provider endpoints before use
// ---------------------------------------------------------------------------

/// Validate that an LLM provider endpoint is safe (no SSRF to internal networks).
pub(crate) fn validate_endpoint_safe(url: &str) -> Result<(), String> {
    let parsed: reqwest::Url =
        reqwest::Url::parse(url).map_err(|e| format!("Invalid URL: {}", e))?;

    // Only allow http/https
    match parsed.scheme() {
        "http" | "https" => {}
        s => return Err(format!("Unsupported scheme: {}", s)),
    }

    let host = parsed.host_str().unwrap_or("");

    // Allow localhost for local llama-server
    if host == "127.0.0.1" || host == "localhost" || host == "::1" {
        return Ok(()); // Local is always allowed
    }

    // Block private IP ranges
    if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        use std::net::IpAddr;
        let is_private = match ip {
            IpAddr::V4(v4) => {
                v4.is_private()       // 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
                || v4.is_loopback()   // 127.0.0.0/8
                || v4.is_link_local() // 169.254.0.0/16
                || v4.is_broadcast()
                || v4.octets()[0] == 0 // 0.0.0.0/8
            }
            IpAddr::V6(v6) => {
                v6.is_loopback()      // ::1
                || v6.is_unspecified() // ::
                // fe80::/10 (link-local)
                || (v6.segments()[0] & 0xffc0) == 0xfe80
            }
        };

        if is_private {
            return Err(format!(
                "SSRF blocked: {} is a private/reserved address",
                ip
            ));
        }
    }

    // Block cloud metadata endpoints
    if host == "169.254.169.254" || host == "metadata.google.internal" {
        return Err(format!("SSRF blocked: metadata endpoint {}", host));
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Default provider configurations
// ---------------------------------------------------------------------------

/// TOML file structure for providers config
#[derive(Debug, Deserialize)]
struct ProvidersFile {
    providers: Vec<ProviderConfig>,
}

/// Load providers from a single TOML file.
fn load_providers_from_file(path: &std::path::Path) -> Result<Vec<ProviderConfig>> {
    let content =
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let file: ProvidersFile =
        toml::from_str(&content).with_context(|| format!("parsing {}", path.display()))?;
    Ok(file.providers)
}

/// Load providers using merged system/user TOML strategy.
///
/// Priority (highest to lowest):
/// 1. `~/.config/lifeos/llm-providers.toml` — user overrides
/// 2. `/etc/lifeos/llm-providers.toml` — admin/user config
/// 3. `/usr/share/lifeos/llm-providers.toml` — system defaults (read-only, shipped with image)
/// 4. `files/etc/lifeos/llm-providers.toml` — repo-local (development)
///
/// User-defined providers override system defaults with the same name.
pub(crate) fn load_providers_from_toml() -> Result<Vec<ProviderConfig>> {
    let user_paths = [
        // User home config (highest priority)
        dirs_home()
            .map(|h| h.join(".config/lifeos/llm-providers.toml"))
            .unwrap_or_default(),
        // Admin/user system config
        std::path::PathBuf::from("/etc/lifeos/llm-providers.toml"),
    ];
    let system_paths = [
        // System defaults (bootc read-only image)
        std::path::PathBuf::from("/usr/share/lifeos/llm-providers.toml"),
        // Repo-local (for development)
        std::path::PathBuf::from("files/etc/lifeos/llm-providers.toml"),
    ];

    let mut providers = Vec::new();
    let mut seen_names = std::collections::HashSet::new();

    // User TOML files take priority
    for path in &user_paths {
        if path.as_os_str().is_empty() || !path.exists() {
            continue;
        }
        if let Ok(file_providers) = load_providers_from_file(path) {
            info!(
                "[llm_router] Loaded {} providers from {} (user)",
                file_providers.len(),
                path.display()
            );
            for p in file_providers {
                seen_names.insert(p.name.clone());
                providers.push(p);
            }
            break; // Use the first user TOML found
        }
    }

    // System TOML fills in what user doesn't override
    for path in &system_paths {
        if !path.exists() {
            continue;
        }
        if let Ok(sys_providers) = load_providers_from_file(path) {
            let mut added = 0usize;
            for p in sys_providers {
                if !seen_names.contains(&p.name) {
                    seen_names.insert(p.name.clone());
                    providers.push(p);
                    added += 1;
                }
            }
            if added > 0 {
                info!(
                    "[llm_router] Merged {} system-default providers from {}",
                    added,
                    path.display()
                );
            }
            break; // Use the first system TOML found
        }
    }

    if providers.is_empty() {
        bail!("no providers.toml found");
    }

    // Filter: only keep providers whose API key env var is set (or empty = local)
    let active: Vec<ProviderConfig> = providers
        .into_iter()
        .filter(|p| {
            p.api_key_env.is_empty()
                || std::env::var(&p.api_key_env)
                    .map(|v| !v.is_empty())
                    .unwrap_or(false)
        })
        .collect();

    // SSRF guard: validate each endpoint before use
    for p in &active {
        if let Err(e) = validate_endpoint_safe(&p.api_base) {
            warn!("[llm_router] SSRF: provider '{}' blocked — {}", p.name, e);
        }
    }
    let safe: Vec<ProviderConfig> = active
        .into_iter()
        .filter(|p| validate_endpoint_safe(&p.api_base).is_ok())
        .collect();

    info!(
        "[llm_router] {} total safe providers (after SSRF filter + merge)",
        safe.len()
    );
    Ok(safe)
}

fn dirs_home() -> Option<std::path::PathBuf> {
    std::env::var("HOME").ok().map(std::path::PathBuf::from)
}

fn default_providers() -> Vec<ProviderConfig> {
    // Provider priority: Local > Cerebras (privacy+speed) > Groq (privacy+speed)
    //                    > Z.AI paid (if balance) > OpenRouter (fallback, mixed privacy)
    vec![
        // ===== Priority 1: Local — max privacy, zero cost =====
        ProviderConfig {
            name: "local".into(),
            api_base: "http://127.0.0.1:8082".into(),
            api_key_env: "".into(),
            model: "local".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: None,
            max_rpd: None,
            supports_vision: true,
            max_context: 16384,
            tier: ProviderTier::Local,
            chat_path: None,
            privacy: "max".into(),
        },
        // ===== Priority 2: Cerebras — zero data retention, 2000+ tok/s =====
        // Qwen3 235B (A22B MoE) — most powerful free model
        ProviderConfig {
            name: "cerebras-qwen235b".into(),
            api_base: "https://api.cerebras.ai".into(),
            api_key_env: "CEREBRAS_API_KEY".into(),
            model: "qwen-3-235b-a22b-instruct-2507".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: Some(30),
            max_rpd: None,
            supports_vision: false,
            max_context: 128_000,
            tier: ProviderTier::Free,
            chat_path: None,
            privacy: "high".into(),
        },
        // Llama 3.1 8B on Cerebras — fastest for simple tasks (~2200 tok/s)
        ProviderConfig {
            name: "cerebras-llama8b".into(),
            api_base: "https://api.cerebras.ai".into(),
            api_key_env: "CEREBRAS_API_KEY".into(),
            model: "llama3.1-8b".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: Some(30),
            max_rpd: None,
            supports_vision: false,
            max_context: 128_000,
            tier: ProviderTier::Free,
            chat_path: None,
            privacy: "high".into(),
        },
        // ===== Priority 3: Groq — zero data retention, ~500-1000 tok/s =====
        // Llama 3.3 70B on Groq — strong general purpose
        ProviderConfig {
            name: "groq-llama70b".into(),
            api_base: "https://api.groq.com/openai".into(),
            api_key_env: "GROQ_API_KEY".into(),
            model: "llama-3.3-70b-versatile".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: Some(30),
            max_rpd: Some(14400),
            supports_vision: false,
            max_context: 128_000,
            tier: ProviderTier::Free,
            chat_path: None,
            privacy: "high".into(),
        },
        // Qwen3 32B on Groq — reasoning and coding
        ProviderConfig {
            name: "groq-qwen32b".into(),
            api_base: "https://api.groq.com/openai".into(),
            api_key_env: "GROQ_API_KEY".into(),
            model: "qwen/qwen3-32b".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: Some(30),
            max_rpd: Some(14400),
            supports_vision: false,
            max_context: 128_000,
            tier: ProviderTier::Free,
            chat_path: None,
            privacy: "high".into(),
        },
        // Llama 3.1 8B on Groq — fast lightweight tasks
        ProviderConfig {
            name: "groq-llama8b".into(),
            api_base: "https://api.groq.com/openai".into(),
            api_key_env: "GROQ_API_KEY".into(),
            model: "llama-3.1-8b-instant".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: Some(30),
            max_rpd: Some(14400),
            supports_vision: false,
            max_context: 128_000,
            tier: ProviderTier::Free,
            chat_path: None,
            privacy: "high".into(),
        },
        // GPT-OSS 120B on Groq — strong reasoning
        ProviderConfig {
            name: "groq-gptoss120b".into(),
            api_base: "https://api.groq.com/openai".into(),
            api_key_env: "GROQ_API_KEY".into(),
            model: "openai/gpt-oss-120b".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: Some(30),
            max_rpd: Some(14400),
            supports_vision: false,
            max_context: 128_000,
            tier: ProviderTier::Free,
            chat_path: None,
            privacy: "high".into(),
        },
        // ===== Priority 4: Premium US providers (medium privacy, paid) =====
        // Anthropic Claude — no training on API data
        ProviderConfig {
            name: "anthropic-haiku".into(),
            api_base: "https://api.anthropic.com".into(),
            api_key_env: "ANTHROPIC_API_KEY".into(),
            model: "claude-haiku-4-5-20251001".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.25,
            cost_output_per_m: 1.25,
            max_rpm: None,
            max_rpd: None,
            supports_vision: true,
            max_context: 200_000,
            tier: ProviderTier::Premium,
            chat_path: Some("/v1/messages".into()),
            privacy: "medium".into(),
        },
        // OpenAI GPT-5.4-nano — cheapest OpenAI, no training on API data
        ProviderConfig {
            name: "openai-54nano".into(),
            api_base: "https://api.openai.com".into(),
            api_key_env: "OPENAI_API_KEY".into(),
            model: "gpt-5.4-nano".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.15,
            cost_output_per_m: 0.60,
            max_rpm: None,
            max_rpd: None,
            supports_vision: true,
            max_context: 128_000,
            tier: ProviderTier::Premium,
            chat_path: None,
            privacy: "medium".into(),
        },
        // Google Gemini Flash (free tier trains on data! use with caution)
        ProviderConfig {
            name: "gemini-flash".into(),
            api_base: "https://generativelanguage.googleapis.com".into(),
            api_key_env: "GEMINI_API_KEY".into(),
            model: "gemini-2.5-flash".into(),
            api_format: ApiFormat::Gemini,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: Some(10),
            max_rpd: Some(250),
            supports_vision: true,
            max_context: 1_000_000,
            tier: ProviderTier::Free,
            chat_path: None,
            privacy: "low".into(),
        },
        // ===== Priority 5: Chinese providers (low privacy, paid) =====
        ProviderConfig {
            name: "zai-glm47".into(),
            api_base: "https://api.z.ai/api/paas".into(),
            api_key_env: "ZAI_API_KEY".into(),
            model: "glm-4.7".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.55,
            cost_output_per_m: 2.20,
            max_rpm: None,
            max_rpd: None,
            supports_vision: false,
            max_context: 200_000,
            tier: ProviderTier::Cheap,
            chat_path: Some("/v4/chat/completions".into()),
            privacy: "low".into(),
        },
        // Kimi K2.5 — multimodal vision, 256K context
        ProviderConfig {
            name: "kimi-k25".into(),
            api_base: "https://api.moonshot.cn".into(),
            api_key_env: "KIMI_API_KEY".into(),
            model: "kimi-k2.5".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.60,
            cost_output_per_m: 2.50,
            max_rpm: None,
            max_rpd: None,
            supports_vision: true,
            max_context: 256_000,
            tier: ProviderTier::Cheap,
            chat_path: None,
            privacy: "low".into(),
        },
        // MiniMax M2.5 — strong coding (80% SWE-Bench)
        ProviderConfig {
            name: "minimax-m25".into(),
            api_base: "https://api.minimax.chat".into(),
            api_key_env: "MINIMAX_API_KEY".into(),
            model: "minimax-m2.5".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.30,
            cost_output_per_m: 1.20,
            max_rpm: None,
            max_rpd: None,
            supports_vision: false,
            max_context: 128_000,
            tier: ProviderTier::Cheap,
            chat_path: None,
            privacy: "low".into(),
        },
        // ===== Priority 6: OpenRouter fallback (mixed privacy) =====
        // Nemotron 3 Super — NVIDIA's best free model on OpenRouter
        ProviderConfig {
            name: "openrouter-nemotron".into(),
            api_base: "https://openrouter.ai/api".into(),
            api_key_env: "OPENROUTER_API_KEY".into(),
            model: "nvidia/nemotron-3-super:free".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: Some(20),
            max_rpd: Some(200),
            supports_vision: false,
            max_context: 131_072,
            tier: ProviderTier::Free,
            chat_path: None,
            privacy: "variable".into(),
        },
        // Qwen3 Coder — strong coding fallback
        ProviderConfig {
            name: "openrouter-coder".into(),
            api_base: "https://openrouter.ai/api".into(),
            api_key_env: "OPENROUTER_API_KEY".into(),
            model: "qwen/qwen3-coder:free".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: Some(20),
            max_rpd: Some(200),
            supports_vision: false,
            max_context: 262_144,
            tier: ProviderTier::Free,
            chat_path: None,
            privacy: "variable".into(),
        },
        ProviderConfig {
            name: "openrouter-gptoss120b".into(),
            api_base: "https://openrouter.ai/api".into(),
            api_key_env: "OPENROUTER_API_KEY".into(),
            model: "openai/gpt-oss-120b:free".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: Some(20),
            max_rpd: Some(200),
            supports_vision: false,
            max_context: 128_000,
            tier: ProviderTier::Free,
            chat_path: None,
            privacy: "variable".into(),
        },
    ]
}

impl LlmRouter {
    /// Try to discover a replacement model when the configured one returns 404.
    /// Calls /v1/models on the provider and finds the best match by name similarity.
    async fn discover_replacement_model(
        &self,
        provider: &ProviderConfig,
        api_key: &str,
    ) -> Option<String> {
        let models_url = format!("{}/v1/models", provider.api_base);
        let mut req = self.http.get(&models_url);
        if !api_key.is_empty() {
            req = req.bearer_auth(api_key);
        }

        let resp = req.send().await.ok()?;
        if !resp.status().is_success() {
            return None;
        }

        let body: serde_json::Value = resp.json().await.ok()?;
        let models = body["data"].as_array()?;

        // Extract the "family" from the old model name (e.g., "qwen" from "qwen-3-235b")
        let old_lower = provider.model.to_lowercase();
        let family_keywords: Vec<&str> = old_lower
            .split(['-', '_', '.'])
            .filter(|s| s.len() > 2 && !s.chars().all(|ch| ch.is_ascii_digit()))
            .collect();

        let mut best_match: Option<(String, usize)> = None;

        for model in models {
            let id = model["id"].as_str()?;
            let id_lower = id.to_lowercase();

            // Count how many family keywords match
            let score = family_keywords
                .iter()
                .filter(|kw| id_lower.contains(*kw))
                .count();

            if score > 0 && (best_match.is_none() || score > best_match.as_ref()?.1) {
                best_match = Some((id.to_string(), score));
            }
        }

        best_match.map(|(name, _)| name)
    }
}

/// Decide whether a local response should trigger escalation to the next tier.
///
/// Heuristic (deliberately simple, no ML) — tuned to AVOID false positives
/// on legitimate short answers that happen to contain hedge substrings:
/// - Empty / whitespace-only response.
/// - Trivially short responses (< 3 codepoints of the NORMALIZED string).
/// - Response is ENTIRELY a known hedge phrase (equality after normalization)
///   OR opens with a hedge phrase AND is short/terminally-hedged (see
///   `starts_with_terminal_hedge`): a long substantive answer that happens
///   to begin with "No sé con certeza, pero..." does NOT escalate.
/// - Degenerate outputs (`...`, `>>>`).
///
/// Rationale: substring matching for "no sé" flags valid responses like
/// "no sé si te conviene X, pero..." which is actually a useful answer.
/// We only escalate when the model is truly punting.
pub fn should_escalate(local_response: &RouterResponse) -> bool {
    let text = local_response.text.trim();

    if text.is_empty() {
        return true;
    }

    // Normalize FIRST so the tiny-length check runs on the same representation
    // used by hedge matching. "«ok»" → "ok" (2 chars → escalate); "¡Sí!" → "sí"
    // (2 chars → escalate — acceptable, pure ack); "Sí." → "sí" (2 chars).
    // Normalization: lowercase, strip LEADING Spanish/quote openers (¡¿"'([«)
    // and strip trailing punctuation we see in hedges.
    let normalized: String = text
        .to_lowercase()
        .trim_start_matches(|c: char| matches!(c, '¡' | '¿' | '"' | '\'' | '(' | '[' | '«'))
        .trim_end_matches(|c: char| matches!(c, '.' | ',' | '!' | '?' | ';' | ':' | '»' | ')' | ']' | '"' | '\''))
        .trim()
        .to_string();

    // Trivially short by Unicode codepoint count on the NORMALIZED string.
    // Threshold `< 3` keeps legitimate acks like "sí" (2)... wait: 2 < 3 so
    // pure bare "sí"/"no"/"ok" DO escalate; but "Sí." / "No." / "Ok." / "Va."
    // all become 2-char normalized strings too. Per spec those should NOT
    // escalate — so we bump the raw text floor slightly: only escalate if
    // the normalized string is strictly less than 2 codepoints ("a", "??").
    // Covers the cases from the spec:
    //   "Sí." → "sí" (2) → no escalate
    //   "No." → "no" (2) → no escalate
    //   "Ok." → "ok" (2) → no escalate
    //   "Va." → "va" (2) → no escalate
    //   "a"   → "a"  (1) → escalate
    //   "??"  → ""   (0) → escalate (trailing punct stripped to empty)
    if normalized.chars().count() < 2 {
        return true;
    }

    // Explicit hedge / refusal patterns (ES + EN) — the FULL response must
    // either BE one of these (after normalization) or open with one in a
    // terminal way (see `starts_with_terminal_hedge`).
    const HEDGE_PATTERNS: &[&str] = &[
        "no sé",
        "no lo sé",
        "no lo se",
        "no tengo esa información",
        "no tengo esa informacion",
        "no tengo información",
        "no tengo informacion",
        "no puedo responder",
        "no estoy seguro",
        "desconozco",
        "i don't know",
        "i do not know",
        "i'm not sure",
        "i am not sure",
        "i cannot answer",
        "i can't answer",
        "as an ai, i cannot",
        "i don't have that information",
        "i do not have that information",
    ];

    for pat in HEDGE_PATTERNS {
        // Exact-match hedge → escalate.
        if normalized == *pat {
            return true;
        }
        // Starts-with hedge only escalates when the hedge is TERMINAL —
        // i.e. the hedge is essentially the whole answer or is followed by
        // a short tail. A long substantive answer that opens with
        // "No sé con certeza, pero te cuento que..." does NOT escalate.
        if starts_with_terminal_hedge(&normalized, pat) {
            return true;
        }
    }

    // Degenerate echoes.
    if text == "..." || text == ">>>" {
        return true;
    }

    false
}

/// Returns true when `normalized` opens with `hedge` AND the hedge is
/// terminal — meaning either:
///   * the whole response is the hedge (optionally followed by stripped
///     punctuation), OR
///   * the response continues past the hedge with a VERY short tail
///     (<= 5 words) AND the hedge is followed by a sentence terminator
///     (`.`, `!`, `?`) or a comma/semicolon that cuts the clause short.
///
/// The overall word-count cap of 6 acts as a safety net: any response
/// with <= 6 words that opens with a hedge is escalated ("No sé, la verdad.").
///
/// Captures:
///   "No sé."                         → terminal (pure hedge)
///   "No sé. Pero tal vez X."         → terminal (short tail after `.`)
///   "No sé, la verdad."              → terminal (<= 6 words overall)
/// Does NOT capture:
///   "No sé con certeza, pero te cuento que el flujo A va a B y luego C."
///     → long substantive answer; NOT terminal.
fn starts_with_terminal_hedge(normalized: &str, hedge: &str) -> bool {
    if !normalized.starts_with(hedge) {
        return false;
    }

    // Pure hedge (normalization already stripped trailing punctuation).
    if normalized == hedge {
        return true;
    }

    // Short overall response that opens with a hedge → escalate.
    let word_count = normalized.split_whitespace().count();
    if word_count <= 6 {
        return true;
    }

    // Look at what follows the hedge. If the hedge is immediately followed
    // by a sentence terminator AND the remaining tail is <= 5 words, treat
    // it as terminal ("No sé. Pero tal vez X.").
    let tail = &normalized[hedge.len()..];
    let tail_trimmed = tail.trim_start();
    let first_tail_char = tail_trimmed.chars().next();
    let is_terminator = matches!(first_tail_char, Some('.') | Some('!') | Some('?'));
    if is_terminator {
        let after_term = tail_trimmed
            .trim_start_matches(|c: char| matches!(c, '.' | '!' | '?'))
            .trim();
        let tail_words = after_term.split_whitespace().count();
        if tail_words <= 5 {
            return true;
        }
    }

    false
}

/// Strip `<think>...</think>` blocks from LLM responses (Qwen3, DeepSeek, etc.).
/// These models include chain-of-thought reasoning that shouldn't be shown to users.
pub fn strip_think_tags(text: &str) -> String {
    if let Some(start) = text.find("<think>") {
        if let Some(end) = text.find("</think>") {
            let after = &text[end + "</think>".len()..];
            // Recursively strip in case of multiple blocks
            return strip_think_tags(&format!("{}{}", &text[..start], after))
                .trim()
                .to_string();
        }
        // Unclosed <think> — the model used all tokens on reasoning with no output.
        // Return everything before the tag (if any), otherwise empty.
        let before = text[..start].trim();
        if !before.is_empty() {
            return before.to_string();
        }
        return String::new();
    }
    text.to_string()
}

/// Detect and strip degenerate reasoning loops where the model repeats the same
/// sentences over and over (common with small models like Qwen3.5-2B in reasoning mode).
///
/// Heuristic: split into sentences, if any sentence appears 3+ times, the response
/// is degenerate — return only the unique content before the loop started.
pub fn strip_reasoning_loop(text: &str) -> String {
    let text = text.trim();
    if text.is_empty() {
        return String::new();
    }

    // Split on sentence boundaries (period/newline followed by capital or common patterns)
    let sentences: Vec<&str> = text
        .split('\n')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();

    if sentences.len() < 4 {
        return text.to_string();
    }

    // Count occurrences of each sentence
    let mut counts = std::collections::HashMap::new();
    for s in &sentences {
        *counts.entry(*s).or_insert(0u32) += 1;
    }

    // If any sentence repeats 3+ times, the output is degenerate
    let has_loop = counts.values().any(|&c| c >= 3);
    if !has_loop {
        return text.to_string();
    }

    // Collect unique sentences in order (first occurrence only), stop at first repeat
    let mut seen = std::collections::HashSet::new();
    let mut unique = Vec::new();
    for s in &sentences {
        if !seen.insert(*s) {
            break; // Loop started
        }
        unique.push(*s);
    }

    let result = unique.join("\n").trim().to_string();
    if result.is_empty() {
        // Everything was a loop — return a fallback
        return String::new();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bug_reasoning_loop_qwen35_repeats_same_sentence() {
        let input = "I should respond.\nLet me check.\nI should respond.\nLet me check.\nI should respond.\nLet me check.\nI should respond.";
        let result = strip_reasoning_loop(input);
        assert!(result.len() < input.len(), "Loop should be stripped");
        assert!(!result.contains("I should respond.\nLet me check.\nI should respond."));
    }

    #[test]
    fn test_bug_unclosed_think_tag_returns_empty() {
        let input = "<think>This is internal reasoning that never closes";
        let result = strip_think_tags(input);
        assert!(
            result.is_empty() || !result.contains("internal reasoning"),
            "Unclosed think tag should not leak reasoning"
        );
    }

    #[test]
    fn test_strip_think_tags_normal() {
        let input = "<think>reasoning here</think>The actual answer.";
        let result = strip_think_tags(input);
        assert_eq!(result, "The actual answer.");
    }

    #[test]
    fn test_strip_think_tags_multiple_blocks() {
        let input = "<think>first</think>Hello <think>second</think>world";
        let result = strip_think_tags(input);
        assert_eq!(result, "Hello world");
    }

    #[test]
    fn test_strip_think_tags_no_tags() {
        let input = "Just a normal response without any tags.";
        let result = strip_think_tags(input);
        assert_eq!(result, input);
    }

    #[test]
    fn test_strip_reasoning_loop_no_loop() {
        let input = "First sentence.\nSecond sentence.\nThird sentence.";
        let result = strip_reasoning_loop(input);
        assert_eq!(result, input);
    }

    #[test]
    fn test_strip_reasoning_loop_empty() {
        let result = strip_reasoning_loop("");
        assert!(result.is_empty());
    }

    #[test]
    fn test_bug_reasoning_loop_degenerate_all_same() {
        let input = "ok\nok\nok\nok\nok";
        let result = strip_reasoning_loop(input);
        // First occurrence only before the loop starts
        assert!(result.len() <= "ok".len());
    }

    // AL.1 — SSRF Guard tests
    #[test]
    fn test_ssrf_guard_blocks_private_ips() {
        assert!(validate_endpoint_safe("http://10.0.0.1:8080/v1").is_err());
        assert!(validate_endpoint_safe("http://192.168.1.1:8080").is_err());
        assert!(validate_endpoint_safe("http://172.16.0.1:8080").is_err());
        assert!(validate_endpoint_safe("http://169.254.169.254/metadata").is_err());
        assert!(validate_endpoint_safe("http://127.0.0.1:8082").is_ok()); // local allowed
        assert!(validate_endpoint_safe("https://api.cerebras.ai").is_ok());
        assert!(validate_endpoint_safe("ftp://evil.com").is_err()); // bad scheme
    }

    #[test]
    fn test_ssrf_guard_blocks_metadata_endpoints() {
        assert!(validate_endpoint_safe("http://169.254.169.254/latest/meta-data/").is_err());
        assert!(
            validate_endpoint_safe("http://metadata.google.internal/computeMetadata/v1/").is_err()
        );
    }

    #[test]
    fn test_ssrf_guard_allows_valid_providers() {
        assert!(validate_endpoint_safe("https://api.openai.com/v1").is_ok());
        assert!(validate_endpoint_safe("https://generativelanguage.googleapis.com").is_ok());
        assert!(validate_endpoint_safe("https://openrouter.ai/api/v1").is_ok());
        assert!(validate_endpoint_safe("http://localhost:8082").is_ok());
    }

    #[test]
    fn test_ssrf_guard_rejects_invalid_urls() {
        assert!(validate_endpoint_safe("not-a-url").is_err());
        assert!(validate_endpoint_safe("").is_err());
    }

    // AL.2 — Security: bootstrap token entropy
    #[test]
    fn test_security_bootstrap_token_entropy() {
        // Verify bootstrap tokens have sufficient entropy (at least 128 bits = 32 hex chars)
        // Zero-pad to ensure consistent length regardless of leading zeros.
        let token = format!("{:032x}", rand::random::<u128>());
        assert!(
            token.len() >= 32,
            "Token must be at least 128 bits, got {} chars",
            token.len()
        );
        // Verify it's valid hex
        assert!(
            token.chars().all(|c| c.is_ascii_hexdigit()),
            "Token must be hex-encoded"
        );
    }

    // ---- Task type classification tests ----

    fn msg(role: &str, content: &str) -> ChatMessage {
        ChatMessage {
            role: role.into(),
            content: serde_json::Value::String(content.into()),
        }
    }

    #[test]
    fn test_classify_short_single_turn_is_quick() {
        let messages = vec![msg("user", "hi")];
        assert_eq!(classify_task_type(&messages), TaskType::Quick);
    }

    #[test]
    fn test_classify_reasoning_keywords() {
        let messages = vec![msg("user", "Can you analyze this architecture decision?")];
        assert_eq!(classify_task_type(&messages), TaskType::Reasoning);
    }

    #[test]
    fn test_classify_creative_keywords() {
        let messages = vec![msg("user", "Write me a short story about a robot")];
        assert_eq!(classify_task_type(&messages), TaskType::Creative);
    }

    #[test]
    fn test_classify_long_context() {
        let long_text = "x".repeat(9000);
        let messages = vec![msg("user", &long_text)];
        assert_eq!(classify_task_type(&messages), TaskType::LongContext);
    }

    #[test]
    fn test_classify_vision_with_image_content() {
        let messages = vec![ChatMessage {
            role: "user".into(),
            content: serde_json::json!([
                {"type": "text", "text": "What is this?"},
                {"type": "image_url", "image_url": {"url": "data:image/png;base64,abc"}}
            ]),
        }];
        assert_eq!(classify_task_type(&messages), TaskType::Vision);
    }

    #[test]
    fn test_classify_vision_text_mention() {
        let messages = vec![msg("user", "Analyze this screenshot image for me")];
        assert_eq!(classify_task_type(&messages), TaskType::Vision);
    }

    #[test]
    fn test_classify_default_for_normal_message() {
        // Message > 100 chars, no keywords, single turn → Default (not Quick)
        let messages = vec![msg("user", "Tell me about the weather in Buenos Aires tomorrow morning please, I need to know if I should bring an umbrella or a jacket")];
        assert_eq!(classify_task_type(&messages), TaskType::Default);
    }

    #[test]
    fn test_classify_empty_messages_is_default() {
        let messages: Vec<ChatMessage> = vec![];
        // No user messages, short total → Quick since 0 < 100 but 0 user msgs ≤ 1
        assert_eq!(classify_task_type(&messages), TaskType::Quick);
    }

    #[test]
    fn test_task_type_bonus_vision_provider() {
        let provider = ProviderConfig {
            name: "local".into(),
            api_base: "http://127.0.0.1:8082".into(),
            api_key_env: "".into(),
            model: "local".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: None,
            max_rpd: None,
            supports_vision: true,
            max_context: 16384,
            tier: ProviderTier::Local,
            chat_path: None,
            privacy: "max".into(),
        };
        assert_eq!(task_type_bonus(&provider, TaskType::Vision), 40);
        assert_eq!(task_type_bonus(&provider, TaskType::Quick), 40);
        assert_eq!(task_type_bonus(&provider, TaskType::Default), 0);
    }

    #[test]
    fn test_task_type_bonus_gemini_long_context() {
        let provider = ProviderConfig {
            name: "gemini-flash".into(),
            api_base: "https://generativelanguage.googleapis.com".into(),
            api_key_env: "GEMINI_API_KEY".into(),
            model: "gemini-2.5-flash".into(),
            api_format: ApiFormat::Gemini,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: Some(10),
            max_rpd: Some(250),
            supports_vision: true,
            max_context: 1_000_000,
            tier: ProviderTier::Free,
            chat_path: None,
            privacy: "low".into(),
        };
        assert_eq!(task_type_bonus(&provider, TaskType::LongContext), 50);
    }

    fn resp(text: &str) -> RouterResponse {
        RouterResponse {
            text: text.into(),
            provider: "local".into(),
            model: "local".into(),
            tokens_used: None,
            latency_ms: 0,
            cached: false,
        }
    }

    #[test]
    fn test_should_escalate_empty() {
        assert!(should_escalate(&resp("")));
        assert!(should_escalate(&resp("   \n  ")));
    }

    #[test]
    fn test_should_escalate_too_short() {
        // Truly degenerate short inputs still escalate.
        assert!(should_escalate(&resp("a")));
        assert!(should_escalate(&resp("??")));
        assert!(should_escalate(&resp("")));
    }

    #[test]
    fn test_should_not_escalate_short_acks() {
        // Short Spanish/English acks are legitimate replies — don't escalate.
        assert!(!should_escalate(&resp("Sí.")));
        assert!(!should_escalate(&resp("No.")));
        assert!(!should_escalate(&resp("Ok.")));
        assert!(!should_escalate(&resp("Va.")));
        assert!(!should_escalate(&resp("sí claro")));
    }

    #[test]
    fn test_should_escalate_hedge_terminal() {
        // Pure hedge, possibly decorated with punctuation/quotes.
        assert!(should_escalate(&resp("¡No sé!")));
        assert!(should_escalate(&resp("No sé.")));
        // Hedge + very short tail (<= 6 words overall).
        assert!(should_escalate(&resp("No sé, la verdad.")));
    }

    #[test]
    fn test_should_not_escalate_hedge_with_substance() {
        // Long substantive answer that happens to OPEN with a hedge — the
        // hedge is embedded, not terminal, so the answer stands on its own.
        assert!(!should_escalate(&resp(
            "No sé con certeza, pero te cuento que el flujo A va a B y luego C."
        )));
        assert!(!should_escalate(&resp(
            "Desconozco el detalle técnico exacto, pero el flujo general es A → B → C y funciona así."
        )));
    }

    #[test]
    fn test_should_escalate_normalized_quotes() {
        // Normalization strips leading «¡¿"'([ — so decorated short replies
        // are treated identically to their bare form.
        // "«ok»" normalizes to "ok" (2 chars) — below hedge list, above the
        // tiny-length floor (< 2), so it survives as a legitimate ack.
        assert!(!should_escalate(&resp("«ok»")));
        // But a single decorated letter still trips the length floor.
        assert!(should_escalate(&resp("«a»")));
    }

    #[test]
    fn test_should_escalate_dont_know_patterns() {
        // Short terminal hedges still escalate (<= 6 words overall).
        assert!(should_escalate(&resp("Desconozco ese dato, perdón.")));
        assert!(should_escalate(&resp("I don't know.")));
        assert!(should_escalate(&resp("No tengo información.")));
    }

    #[test]
    fn test_should_not_escalate_normal_answer() {
        assert!(!should_escalate(&resp(
            "La capital de Argentina es Buenos Aires, una ciudad cosmopolita y hermosa."
        )));
    }

    #[test]
    fn test_task_type_bonus_anthropic_reasoning() {
        let provider = ProviderConfig {
            name: "anthropic-haiku".into(),
            api_base: "https://api.anthropic.com".into(),
            api_key_env: "ANTHROPIC_API_KEY".into(),
            model: "claude-haiku-4-5-20251001".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.25,
            cost_output_per_m: 1.25,
            max_rpm: None,
            max_rpd: None,
            supports_vision: true,
            max_context: 200_000,
            tier: ProviderTier::Premium,
            chat_path: Some("/v1/messages".into()),
            privacy: "medium".into(),
        };
        assert_eq!(task_type_bonus(&provider, TaskType::Reasoning), 50);
        assert_eq!(task_type_bonus(&provider, TaskType::Creative), 50);
    }
}
