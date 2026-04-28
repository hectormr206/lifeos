//! Multi-LLM Debate Engine — sends the same question to multiple providers
//! in parallel and synthesizes responses to eliminate corporate bias.
//!
//! Especially important for Vida Plena (wellness coaching) topics where a
//! single LLM's training bias could yield harmful advice on health,
//! relationships, finances, or spirituality.

use anyhow::{bail, Result};
use log::{info, warn};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;
use tokio::time::timeout;

use crate::llm_router::{ChatMessage, LlmRouter, ProviderConfig, ProviderTier, RouterRequest};
use crate::privacy_filter::{PrivacyFilter, PrivacyLevel};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// What kind of question is being debated — influences the judge prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DebateTopic {
    Health,
    MentalHealth,
    Nutrition,
    Exercise,
    Finance,
    Relationships,
    Spiritual,
    General,
}

impl DebateTopic {
    /// Parse from a user-facing string (case-insensitive).
    pub fn from_str_loose(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "health" | "salud" => Self::Health,
            "mental_health" | "mental" | "salud_mental" => Self::MentalHealth,
            "nutrition" | "nutricion" => Self::Nutrition,
            "exercise" | "ejercicio" => Self::Exercise,
            "finance" | "finanzas" | "finances" => Self::Finance,
            "relationships" | "relaciones" => Self::Relationships,
            "spiritual" | "espiritualidad" => Self::Spiritual,
            _ => Self::General,
        }
    }

    fn domain_warning(&self) -> &'static str {
        match self {
            Self::Health | Self::MentalHealth => {
                "CRITICAL: This is a health topic. Discard any response that diagnoses, \
                 prescribes medication, or replaces professional medical advice. \
                 Flag provider responses that are overconfident about medical claims."
            }
            Self::Nutrition => {
                "This is a nutrition topic. Be skeptical of extreme diet claims, \
                 supplement pushing, or responses that ignore individual context."
            }
            Self::Exercise => {
                "This is an exercise topic. Flag responses that push unsafe intensity \
                 or ignore injury risk. Prefer evidence-based recommendations."
            }
            Self::Finance => {
                "This is a financial topic. Discard any response that promotes specific \
                 investment products or ignores the user's financial context. \
                 Flag get-rich-quick advice."
            }
            Self::Relationships => {
                "This is a relationships topic. Discard any response that is judgmental, \
                 culturally biased, or dismissive of the user's feelings. \
                 Prioritize empathy and nuance."
            }
            Self::Spiritual => {
                "This is a spirituality topic. Respect all belief systems equally. \
                 Discard any response that proselytizes or dismisses any tradition. \
                 Focus on the user's personal growth."
            }
            Self::General => "",
        }
    }
}

/// Request to the debate engine.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DebateRequest {
    pub question: String,
    /// Optional user context for personalization.
    pub context: Option<String>,
    /// Minimum providers to query (default 2).
    #[serde(default = "default_min")]
    pub min_providers: usize,
    /// Maximum providers to query (default 5).
    #[serde(default = "default_max")]
    pub max_providers: usize,
    /// What kind of question is being debated.
    #[serde(default)]
    pub topic: DebateTopic,
    /// Privacy level to enforce — filters providers and sanitizes content.
    #[serde(default)]
    pub privacy_level: Option<PrivacyLevel>,
}

fn default_min() -> usize {
    2
}
fn default_max() -> usize {
    5
}

impl Default for DebateTopic {
    fn default() -> Self {
        Self::General
    }
}

/// A single provider's opinion collected during the debate.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderOpinion {
    pub provider_name: String,
    pub response: String,
    pub agrees_with_majority: bool,
}

/// The synthesized result of a multi-provider debate.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DebateResponse {
    /// Final synthesized answer from the judge.
    pub synthesis: String,
    /// 0.0 (total disagreement) to 1.0 (unanimous consensus).
    pub consensus_level: f32,
    /// Individual provider responses with agreement status.
    pub provider_responses: Vec<ProviderOpinion>,
    /// Where providers disagreed — human-readable summaries.
    pub dissenting_views: Vec<String>,
}

/// Timeout per individual provider query.
const PROVIDER_TIMEOUT: Duration = Duration::from_secs(30);

/// Global timeout for the entire debate (all providers combined).
const DEBATE_GLOBAL_TIMEOUT: Duration = Duration::from_secs(90);

// ---------------------------------------------------------------------------
// Debate Engine
// ---------------------------------------------------------------------------

/// Orchestrates multi-LLM debates by querying multiple providers in parallel
/// and using the local model as an impartial judge to synthesize responses.
pub struct DebateEngine {
    router: Arc<RwLock<LlmRouter>>,
}

impl DebateEngine {
    pub fn new(router: Arc<RwLock<LlmRouter>>) -> Self {
        Self { router }
    }

    /// Run a multi-provider debate on the given question.
    ///
    /// 1. Select N diverse providers from the router.
    /// 2. Query all in parallel with a 30s timeout each.
    /// 3. Use the local model as judge to synthesize.
    /// 4. Return the synthesis + individual opinions.
    pub async fn debate(&self, request: &DebateRequest) -> Result<DebateResponse> {
        let router = self.router.read().await;

        // Determine privacy level: explicit request > router default
        let privacy_level = request
            .privacy_level
            .unwrap_or_else(|| router.privacy_level());

        // Sanitize the question before sending to any provider
        let filter = PrivacyFilter::new(privacy_level);
        let filter_result = filter.sanitize(&request.question);
        let sensitivity = filter_result.sensitivity;

        let providers = select_diverse_providers(
            router.provider_configs(),
            request.min_providers,
            request.max_providers,
            privacy_level,
            sensitivity,
        );

        if providers.is_empty() {
            bail!("No LLM providers available for debate");
        }

        // Build a sanitized request — use filtered question for external providers
        let sanitized_request = DebateRequest {
            question: filter_result.sanitized_text.clone(),
            context: request.context.clone(),
            min_providers: request.min_providers,
            max_providers: request.max_providers,
            topic: request.topic,
            privacy_level: request.privacy_level,
        };

        // Single provider — skip debate, return directly with a note
        if providers.len() == 1 {
            info!(
                "[llm_debate] Only 1 provider available ({}), skipping debate",
                providers[0].name
            );
            let response =
                query_single_provider(&router, &providers[0], &sanitized_request).await?;
            return Ok(DebateResponse {
                synthesis: format!(
                    "[Nota: Solo 1 modelo disponible — sin debate multi-perspectiva]\n\n{}",
                    response
                ),
                consensus_level: 1.0,
                provider_responses: vec![ProviderOpinion {
                    provider_name: providers[0].name.clone(),
                    response,
                    agrees_with_majority: true,
                }],
                dissenting_views: vec![],
            });
        }

        info!(
            "[llm_debate] Starting debate with {} providers: {}",
            providers.len(),
            providers
                .iter()
                .map(|p| p.name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );

        // Query all providers in parallel with per-provider + global timeout
        let futures: Vec<_> = providers
            .iter()
            .map(|provider| {
                let name = provider.name.clone();
                let question = sanitized_request.question.clone();
                let context = sanitized_request.context.clone();
                let provider_clone = provider.clone();

                // We need to clone the router Arc for each task
                let router_arc = Arc::clone(&self.router);

                async move {
                    let result = timeout(PROVIDER_TIMEOUT, async {
                        let router = router_arc.read().await;
                        query_single_provider(
                            &router,
                            &provider_clone,
                            &DebateRequest {
                                question,
                                context,
                                min_providers: 0,
                                max_providers: 0,
                                topic: DebateTopic::General,
                                privacy_level: None,
                            },
                        )
                        .await
                    })
                    .await;

                    match result {
                        Ok(Ok(text)) => {
                            info!("[llm_debate] {} responded ({} chars)", name, text.len());
                            Some((name, text))
                        }
                        Ok(Err(e)) => {
                            warn!("[llm_debate] {} failed: {}", name, e);
                            None
                        }
                        Err(_) => {
                            warn!("[llm_debate] {} timed out after 30s", name);
                            None
                        }
                    }
                }
            })
            .collect();

        // Global timeout: 90s for the entire debate to prevent hanging
        let all_results = timeout(
            DEBATE_GLOBAL_TIMEOUT,
            futures_util::future::join_all(futures),
        )
        .await;

        let responses: Vec<(String, String)> = match all_results {
            Ok(results) => results.into_iter().flatten().collect(),
            Err(_) => {
                warn!("[llm_debate] Global debate timeout (90s) exceeded");
                bail!("Debate timed out after 90 seconds");
            }
        };

        if responses.is_empty() {
            bail!("All providers failed or timed out during debate");
        }

        if responses.len() == 1 {
            return Ok(DebateResponse {
                synthesis: format!(
                    "[Nota: Solo 1 modelo respondio — sin debate multi-perspectiva]\n\n{}",
                    responses[0].1
                ),
                consensus_level: 1.0,
                provider_responses: vec![ProviderOpinion {
                    provider_name: responses[0].0.clone(),
                    response: responses[0].1.clone(),
                    agrees_with_majority: true,
                }],
                dissenting_views: vec![],
            });
        }

        // Synthesize using the local model as judge
        let judge_result = synthesize_with_judge(
            &router,
            &request.question,
            &request.context,
            &responses,
            request.topic,
        )
        .await;

        match judge_result {
            Ok(debate_resp) => Ok(debate_resp),
            Err(e) => {
                warn!(
                    "[llm_debate] Judge synthesis failed ({}), returning raw responses",
                    e
                );
                // Fallback: return responses without synthesis
                Ok(DebateResponse {
                    synthesis: format!(
                        "[Error en sintesis — mostrando respuestas individuales]\n\n{}",
                        responses
                            .iter()
                            .map(|(name, resp)| format!("**{}**: {}", name, resp))
                            .collect::<Vec<_>>()
                            .join("\n\n---\n\n")
                    ),
                    consensus_level: 0.5,
                    provider_responses: responses
                        .iter()
                        .map(|(name, resp)| ProviderOpinion {
                            provider_name: name.clone(),
                            response: resp.clone(),
                            agrees_with_majority: true,
                        })
                        .collect(),
                    dissenting_views: vec![],
                })
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Provider selection — pick diverse providers across tiers
// ---------------------------------------------------------------------------

fn select_diverse_providers(
    all: &[ProviderConfig],
    min: usize,
    max: usize,
    privacy_level: PrivacyLevel,
    sensitivity: crate::privacy_filter::SensitivityLevel,
) -> Vec<ProviderConfig> {
    // Goal: pick providers from different tiers for diversity of perspective.
    // Priority: Local first (always if available), then one from each tier,
    // then fill remaining slots by score.
    // Privacy: filter out providers whose tier doesn't match the sensitivity level.

    let filter = PrivacyFilter::new(privacy_level);

    let mut selected: Vec<ProviderConfig> = Vec::new();
    let mut used_names: Vec<String> = Vec::new();

    // Phase 1: one provider per tier (Local → Free → Cheap → Premium)
    for tier in &[
        ProviderTier::Local,
        ProviderTier::Free,
        ProviderTier::Cheap,
        ProviderTier::Premium,
    ] {
        if selected.len() >= max {
            break;
        }
        if let Some(p) = all.iter().find(|p| {
            p.tier == *tier
                && !used_names.contains(&p.name)
                && filter.is_safe_for_tier(sensitivity, p.tier)
        }) {
            used_names.push(p.name.clone());
            selected.push(p.clone());
        }
    }

    // Phase 2: fill with remaining providers if under max
    for p in all {
        if selected.len() >= max {
            break;
        }
        if !used_names.contains(&p.name) && filter.is_safe_for_tier(sensitivity, p.tier) {
            used_names.push(p.name.clone());
            selected.push(p.clone());
        }
    }

    // Check minimum
    if selected.len() < min {
        // Return what we have even if under minimum — caller handles
        info!(
            "[llm_debate] Only {} providers available (min requested: {})",
            selected.len(),
            min
        );
    }

    selected
}

// ---------------------------------------------------------------------------
// Query a single provider
// ---------------------------------------------------------------------------

async fn query_single_provider(
    router: &LlmRouter,
    provider: &ProviderConfig,
    request: &DebateRequest,
) -> Result<String> {
    let mut messages = vec![];

    if let Some(ctx) = &request.context {
        messages.push(ChatMessage {
            role: "system".to_string(),
            content: serde_json::Value::String(format!(
                "Contexto del usuario: {}. Responde de forma concisa y directa.",
                ctx
            )),
        });
    }

    messages.push(ChatMessage {
        role: "user".to_string(),
        content: serde_json::Value::String(request.question.clone()),
    });

    let router_req = RouterRequest {
        messages,
        complexity: None,
        sensitivity: None,
        preferred_provider: Some(provider.name.clone()),
        max_tokens: Some(1024),
        task_type: None,
        tools: None,
    };

    let resp = router.chat(&router_req).await?;
    Ok(resp.text)
}

// ---------------------------------------------------------------------------
// Judge synthesis — local model analyzes all responses
// ---------------------------------------------------------------------------

fn build_judge_prompt(
    question: &str,
    context: &Option<String>,
    responses: &[(String, String)],
    topic: DebateTopic,
) -> String {
    let mut prompt = String::with_capacity(4096);

    prompt.push_str(
        "Eres un juez imparcial que analiza respuestas de multiples asistentes de IA.\n\
         Tu trabajo es sintetizar la mejor respuesta posible, identificando consenso \
         y disenso entre los modelos.\n\n",
    );

    let warning = topic.domain_warning();
    if !warning.is_empty() {
        prompt.push_str(&format!("DOMINIO ESPECIAL: {}\n\n", warning));
    }

    if let Some(ctx) = context {
        prompt.push_str(&format!("Contexto del usuario: {}\n\n", ctx));
    }

    prompt.push_str(&format!("El usuario pregunto: \"{}\"\n\n", question));

    for (i, (name, response)) in responses.iter().enumerate() {
        let letter = (b'A' + i as u8) as char;
        prompt.push_str(&format!(
            "--- Respuesta del Modelo {} ({}) ---\n{}\n\n",
            letter, name, response
        ));
    }

    prompt.push_str(
        "Analiza las respuestas y proporciona EXACTAMENTE este formato:\n\n\
         CONSENSO: [Lo que la mayoria coincide — 2-3 puntos clave]\n\n\
         DISENSO: [Donde difieren y por que cada uno podria tener razon o estar sesgado]\n\n\
         SINTESIS: [Tu respuesta balanceada incorporando los puntos mas fuertes de cada modelo. \
         Esta es la respuesta final para el usuario — debe ser util y directa.]\n\n\
         NIVEL_CONSENSO: [Un numero entre 0.0 y 1.0 — 1.0 = todos coinciden, 0.0 = desacuerdo total]\n\n\
         IMPORTANTE: Cada IA puede tener sesgos corporativos. Identifica y descuenta cualquier \
         respuesta que parezca empujar una agenda especifica en vez de ayudar genuinamente al usuario.",
    );

    prompt
}

/// Parse the structured judge output into a DebateResponse.
fn parse_judge_output(raw: &str, responses: &[(String, String)]) -> DebateResponse {
    // Extract sections by searching for headers
    let _consensus = extract_section(raw, "CONSENSO:");
    let dissent = extract_section(raw, "DISENSO:");
    let synthesis = extract_section(raw, "SINTESIS:");
    let level_str = extract_section(raw, "NIVEL_CONSENSO:");

    let consensus_level = match level_str.trim().parse::<f32>() {
        Ok(v) => v.clamp(0.0, 1.0),
        Err(e) => {
            warn!(
                "[llm_debate] Failed to parse consensus_level '{}': {} — defaulting to 0.5",
                level_str.trim(),
                e
            );
            0.5
        }
    };

    let synthesis_text = if synthesis.is_empty() {
        // Fallback: use the whole output as synthesis
        raw.to_string()
    } else {
        synthesis
    };

    let dissenting_views = if dissent.is_empty() {
        vec![]
    } else {
        dissent
            .split('\n')
            .filter(|l| !l.trim().is_empty())
            .map(|l| l.trim().to_string())
            .collect()
    };

    // Determine majority agreement based on consensus level
    let agrees_threshold = consensus_level > 0.5;

    let provider_responses = responses
        .iter()
        .map(|(name, resp)| ProviderOpinion {
            provider_name: name.clone(),
            response: resp.clone(),
            agrees_with_majority: agrees_threshold,
        })
        .collect();

    DebateResponse {
        synthesis: synthesis_text,
        consensus_level,
        provider_responses,
        dissenting_views,
    }
}

/// Strip markdown bold formatting (`**text**` → `text`).
fn strip_markdown_bold(text: &str) -> String {
    text.replace("**", "")
}

/// Extract content between a section header and the next section header.
/// Case-insensitive and strips markdown formatting before searching.
fn extract_section(text: &str, header: &str) -> String {
    let clean = strip_markdown_bold(text);
    let lower = clean.to_lowercase();
    let header_lower = header.to_lowercase();

    let headers_lower = ["consenso:", "disenso:", "sintesis:", "nivel_consenso:"];

    if let Some(start) = lower.find(&header_lower) {
        let after = &clean[start + header.len()..];
        let after_lower = &lower[start + header_lower.len()..];
        // Find where the next section starts
        let end = headers_lower
            .iter()
            .filter(|h| **h != header_lower)
            .filter_map(|h| after_lower.find(h))
            .min()
            .unwrap_or(after.len());

        after[..end].trim().to_string()
    } else {
        String::new()
    }
}

async fn synthesize_with_judge(
    router: &LlmRouter,
    question: &str,
    context: &Option<String>,
    responses: &[(String, String)],
    topic: DebateTopic,
) -> Result<DebateResponse> {
    // The judge MUST be a local model to avoid adding external bias.
    // If no local model is available, return responses without synthesis.
    let local_provider = router
        .provider_configs()
        .iter()
        .find(|p| p.tier == ProviderTier::Local)
        .map(|p| p.name.clone());

    if local_provider.is_none() {
        warn!(
            "[llm_debate] No local model available for judge synthesis — returning raw responses"
        );
        let raw_synthesis = format!(
            "[Sintesis no disponible — no hay modelo local para juez imparcial]\n\n{}",
            responses
                .iter()
                .map(|(name, resp)| format!("**{}**: {}", name, resp))
                .collect::<Vec<_>>()
                .join("\n\n---\n\n")
        );
        return Ok(DebateResponse {
            synthesis: raw_synthesis,
            consensus_level: 0.5,
            provider_responses: responses
                .iter()
                .map(|(name, resp)| ProviderOpinion {
                    provider_name: name.clone(),
                    response: resp.clone(),
                    agrees_with_majority: true,
                })
                .collect(),
            dissenting_views: vec![],
        });
    }

    let judge_prompt = build_judge_prompt(question, context, responses, topic);

    let messages = vec![ChatMessage {
        role: "user".to_string(),
        content: serde_json::Value::String(judge_prompt),
    }];

    let req = RouterRequest {
        messages,
        complexity: None,
        sensitivity: None,
        preferred_provider: local_provider,
        max_tokens: Some(2048),
        task_type: None,
        tools: None,
    };

    let resp = router.chat(&req).await?;
    Ok(parse_judge_output(&resp.text, responses))
}

// ---------------------------------------------------------------------------
// Telegram tool formatting
// ---------------------------------------------------------------------------

/// Format a DebateResponse for display in Telegram.
pub fn format_for_telegram(resp: &DebateResponse) -> String {
    let provider_count = resp.provider_responses.len();
    let agreeing = resp
        .provider_responses
        .iter()
        .filter(|p| p.agrees_with_majority)
        .count();

    let mut out = String::with_capacity(2048);

    out.push_str(&format!(
        "Consulta multi-perspectiva ({}/{} modelos coinciden)\n\n",
        agreeing, provider_count
    ));

    out.push_str(&format!("Sintesis:\n{}\n", resp.synthesis));

    if !resp.dissenting_views.is_empty() {
        out.push_str("\nDisenso:\n");
        for view in &resp.dissenting_views {
            out.push_str(&format!("- {}\n", view));
        }
    }

    out.push_str(&format!(
        "\nNivel de consenso: {:.0}%",
        resp.consensus_level * 100.0
    ));

    out
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm_router::ApiFormat;

    fn make_provider(name: &str, tier: ProviderTier) -> ProviderConfig {
        ProviderConfig {
            name: name.to_string(),
            api_base: "http://localhost:8082".to_string(),
            api_key_env: String::new(),
            model: "test-model".to_string(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: None,
            max_rpd: None,
            supports_vision: false,
            max_context: 128_000,
            tier,
            chat_path: None,
            privacy: "high".to_string(),
        }
    }

    #[test]
    fn test_select_diverse_providers_picks_one_per_tier() {
        use crate::privacy_filter::SensitivityLevel;

        let providers = vec![
            make_provider("local-qwen", ProviderTier::Local),
            make_provider("groq", ProviderTier::Free),
            make_provider("cerebras", ProviderTier::Free),
            make_provider("openrouter", ProviderTier::Cheap),
            make_provider("claude", ProviderTier::Premium),
        ];

        let selected = select_diverse_providers(
            &providers,
            2,
            4,
            PrivacyLevel::Balanced,
            SensitivityLevel::Low,
        );

        assert_eq!(selected.len(), 4);
        // Should pick one from each tier first
        let tiers: Vec<ProviderTier> = selected.iter().map(|p| p.tier).collect();
        assert!(tiers.contains(&ProviderTier::Local));
        assert!(tiers.contains(&ProviderTier::Free));
        assert!(tiers.contains(&ProviderTier::Cheap));
        assert!(tiers.contains(&ProviderTier::Premium));
    }

    #[test]
    fn test_select_diverse_providers_under_min() {
        use crate::privacy_filter::SensitivityLevel;

        let providers = vec![make_provider("local-qwen", ProviderTier::Local)];

        let selected = select_diverse_providers(
            &providers,
            3,
            5,
            PrivacyLevel::Balanced,
            SensitivityLevel::Low,
        );

        // Returns what's available even if under min
        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0].name, "local-qwen");
    }

    #[test]
    fn test_select_diverse_providers_respects_max() {
        use crate::privacy_filter::SensitivityLevel;

        let providers = vec![
            make_provider("local", ProviderTier::Local),
            make_provider("groq", ProviderTier::Free),
            make_provider("cerebras", ProviderTier::Free),
            make_provider("openrouter", ProviderTier::Cheap),
            make_provider("claude", ProviderTier::Premium),
            make_provider("gpt4", ProviderTier::Premium),
        ];

        let selected = select_diverse_providers(
            &providers,
            2,
            3,
            PrivacyLevel::Balanced,
            SensitivityLevel::Low,
        );

        assert_eq!(selected.len(), 3);
    }

    #[test]
    fn test_select_diverse_providers_filters_by_privacy() {
        use crate::privacy_filter::SensitivityLevel;

        let providers = vec![
            make_provider("local-qwen", ProviderTier::Local),
            make_provider("groq", ProviderTier::Free),
            make_provider("openrouter", ProviderTier::Cheap),
            make_provider("claude", ProviderTier::Premium),
        ];

        // Paranoid mode: only local providers should be selected
        let selected = select_diverse_providers(
            &providers,
            1,
            5,
            PrivacyLevel::Paranoid,
            SensitivityLevel::Low,
        );

        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0].name, "local-qwen");
    }

    #[test]
    fn test_parse_judge_output_case_insensitive() {
        // Judge output with lowercase headers and markdown bold
        let raw = "**consenso:** Todos coinciden en el ejercicio.\n\n\
                   **disenso:** Diferencias en frecuencia.\n\n\
                   **sintesis:** El ejercicio es bueno para todos.\n\n\
                   **nivel_consenso:** 0.75";

        let responses = vec![
            ("ModeloA".to_string(), "resp1".to_string()),
            ("ModeloB".to_string(), "resp2".to_string()),
        ];

        let result = parse_judge_output(raw, &responses);

        assert!((result.consensus_level - 0.75).abs() < 0.01);
        assert!(result.synthesis.contains("ejercicio es bueno"));
        assert!(!result.dissenting_views.is_empty());
    }

    #[test]
    fn test_parse_judge_output_structured() {
        let raw = "CONSENSO: Todos coinciden en que el ejercicio regular es beneficioso.\n\n\
                   DISENSO: Modelo A sugiere 30 min diarios, Modelo B sugiere 45 min 3 veces por semana.\n\n\
                   SINTESIS: El ejercicio regular es beneficioso. La frecuencia optima depende del individuo.\n\n\
                   NIVEL_CONSENSO: 0.8";

        let responses = vec![
            ("ModeloA".to_string(), "Haz 30 min diarios".to_string()),
            ("ModeloB".to_string(), "Haz 45 min 3 veces".to_string()),
        ];

        let result = parse_judge_output(raw, &responses);

        assert!((result.consensus_level - 0.8).abs() < 0.01);
        assert!(result.synthesis.contains("ejercicio regular"));
        assert!(!result.dissenting_views.is_empty());
        assert_eq!(result.provider_responses.len(), 2);
    }

    #[test]
    fn test_parse_judge_output_fallback() {
        // If the judge doesn't follow format, use the whole output
        let raw = "This is just a regular response without structure.";
        let responses = vec![("A".to_string(), "resp".to_string())];

        let result = parse_judge_output(raw, &responses);

        assert_eq!(result.synthesis, raw);
        assert!((result.consensus_level - 0.5).abs() < 0.01);
    }

    #[test]
    fn test_debate_topic_from_str_loose() {
        assert_eq!(DebateTopic::from_str_loose("health"), DebateTopic::Health);
        assert_eq!(DebateTopic::from_str_loose("salud"), DebateTopic::Health);
        assert_eq!(
            DebateTopic::from_str_loose("finanzas"),
            DebateTopic::Finance
        );
        assert_eq!(DebateTopic::from_str_loose("unknown"), DebateTopic::General);
    }

    #[test]
    fn test_format_for_telegram() {
        let resp = DebateResponse {
            synthesis: "El ejercicio es bueno.".to_string(),
            consensus_level: 0.85,
            provider_responses: vec![
                ProviderOpinion {
                    provider_name: "Qwen".to_string(),
                    response: "resp1".to_string(),
                    agrees_with_majority: true,
                },
                ProviderOpinion {
                    provider_name: "Groq".to_string(),
                    response: "resp2".to_string(),
                    agrees_with_majority: true,
                },
                ProviderOpinion {
                    provider_name: "Claude".to_string(),
                    response: "resp3".to_string(),
                    agrees_with_majority: false,
                },
            ],
            dissenting_views: vec!["Claude opina diferente sobre la intensidad.".to_string()],
        };

        let formatted = format_for_telegram(&resp);

        assert!(formatted.contains("2/3 modelos coinciden"));
        assert!(formatted.contains("Sintesis:"));
        assert!(formatted.contains("Disenso:"));
        assert!(formatted.contains("85%"));
    }
}
