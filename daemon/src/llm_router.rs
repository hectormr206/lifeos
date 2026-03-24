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

use crate::privacy_filter::{PrivacyLevel, SensitivityLevel};

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
        let providers = load_providers_from_toml().unwrap_or_else(|e| {
            info!("No providers.toml found ({}), using built-in defaults", e);
            default_providers()
        });
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

    /// Route a chat request to the best available provider.
    pub async fn chat(&self, request: &RouterRequest) -> Result<RouterResponse> {
        let complexity = request.complexity.unwrap_or(TaskComplexity::Medium);
        let sensitivity = request.sensitivity.unwrap_or(SensitivityLevel::Low);

        let candidates =
            self.select_candidates(complexity, sensitivity, &request.preferred_provider);

        if candidates.is_empty() {
            bail!(
                "No LLM providers available for complexity={:?} sensitivity={:?}",
                complexity,
                sensitivity
            );
        }

        let mut last_error = None;

        for provider in &candidates {
            let start = Instant::now();
            match self.call_provider(provider, request).await {
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
    fn select_candidates(
        &self,
        complexity: TaskComplexity,
        sensitivity: SensitivityLevel,
        preferred: &Option<String>,
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

        // Score providers by suitability for this complexity
        let mut scored: Vec<(&ProviderConfig, u32)> = self
            .providers
            .iter()
            .filter(|p| allowed_tiers.contains(&p.tier))
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
                (p, score)
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
            bail!(
                "{} returned {}: {}",
                provider.name,
                status,
                &body[..body.len().min(200)]
            );
        }

        let body: serde_json::Value = response.json().await?;

        // Some models (Qwen3.5 with --jinja) put output in reasoning_content instead of content
        let msg = &body["choices"][0]["message"];
        let text = msg["content"]
            .as_str()
            .filter(|s| !s.is_empty())
            .or_else(|| msg["reasoning_content"].as_str())
            .unwrap_or("")
            .to_string();

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
                &body[..body.len().min(200)]
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
}

// ---------------------------------------------------------------------------
// Default provider configurations
// ---------------------------------------------------------------------------

/// TOML file structure for providers config
#[derive(Debug, Deserialize)]
struct ProvidersFile {
    providers: Vec<ProviderConfig>,
}

/// Load providers from TOML config file. Searches multiple locations.
fn load_providers_from_toml() -> Result<Vec<ProviderConfig>> {
    let candidates = [
        // User config
        dirs_home()
            .map(|h| h.join(".config/lifeos/llm-providers.toml"))
            .unwrap_or_default(),
        // System config
        std::path::PathBuf::from("/etc/lifeos/llm-providers.toml"),
        // Repo-local (for development)
        std::path::PathBuf::from("files/etc/lifeos/llm-providers.toml"),
    ];

    for path in &candidates {
        if path.exists() {
            let content = std::fs::read_to_string(path)
                .with_context(|| format!("reading {}", path.display()))?;
            let file: ProvidersFile =
                toml::from_str(&content).with_context(|| format!("parsing {}", path.display()))?;

            // Filter: only keep providers whose API key env var is set (or empty = local)
            let active: Vec<ProviderConfig> = file
                .providers
                .into_iter()
                .filter(|p| {
                    p.api_key_env.is_empty()
                        || std::env::var(&p.api_key_env)
                            .map(|v| !v.is_empty())
                            .unwrap_or(false)
                })
                .collect();

            info!(
                "Loaded {} providers from {} ({} with active keys)",
                active.len() + candidates.len() - candidates.len(), // total in file
                path.display(),
                active.len()
            );
            return Ok(active);
        }
    }

    bail!("no providers.toml found")
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
            max_context: 6144,
            tier: ProviderTier::Local,
            chat_path: None,
            privacy: String::new(),
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
            privacy: String::new(),
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
            privacy: String::new(),
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
            privacy: String::new(),
        },
        // Qwen3 32B on Groq — reasoning and coding
        ProviderConfig {
            name: "groq-qwen32b".into(),
            api_base: "https://api.groq.com/openai".into(),
            api_key_env: "GROQ_API_KEY".into(),
            model: "qwen-qwq-32b".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: Some(30),
            max_rpd: Some(14400),
            supports_vision: false,
            max_context: 128_000,
            tier: ProviderTier::Free,
            chat_path: None,
            privacy: String::new(),
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
            privacy: String::new(),
        },
        // DeepSeek R1 on Groq — deep reasoning
        ProviderConfig {
            name: "groq-deepseek-r1".into(),
            api_base: "https://api.groq.com/openai".into(),
            api_key_env: "GROQ_API_KEY".into(),
            model: "deepseek-r1-distill-llama-70b".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: Some(30),
            max_rpd: Some(14400),
            supports_vision: false,
            max_context: 128_000,
            tier: ProviderTier::Free,
            chat_path: None,
            privacy: String::new(),
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
            privacy: String::new(),
        },
        // OpenAI GPT-4o-mini — cheapest OpenAI, no training on API data
        ProviderConfig {
            name: "openai-4o-mini".into(),
            api_base: "https://api.openai.com".into(),
            api_key_env: "OPENAI_API_KEY".into(),
            model: "gpt-4o-mini".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.15,
            cost_output_per_m: 0.60,
            max_rpm: None,
            max_rpd: None,
            supports_vision: true,
            max_context: 128_000,
            tier: ProviderTier::Premium,
            chat_path: None,
            privacy: String::new(),
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
            privacy: String::new(),
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
            privacy: String::new(),
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
            privacy: String::new(),
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
            privacy: String::new(),
        },
        // ===== Priority 6: OpenRouter fallback (mixed privacy) =====
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
            privacy: String::new(),
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
            privacy: String::new(),
        },
    ]
}
