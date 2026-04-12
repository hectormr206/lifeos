//! AI module for daemon
//! Manages llama-server integration and AI-related system tasks

use anyhow::Context;
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use futures_util::StreamExt;
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{GenericImageView, ImageReader};
use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::Path;
use std::process::Command;
use std::sync::OnceLock;
use tokio::sync::{mpsc::Sender, Semaphore};

/// AI service status
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiStatus {
    pub server_running: bool,
    pub models: Vec<ModelInfo>,
    pub default_model: String,
    pub gpu_acceleration: bool,
}

/// Model information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelInfo {
    pub name: String,
    pub size_mb: u64,
    pub modified: String,
}

/// AI chat response
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiChatResponse {
    pub response: String,
    pub model: String,
    pub tokens_used: Option<u32>,
}

/// Embedding response from llama-server
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmbeddingResponse {
    pub embedding: Vec<f32>,
    pub model: String,
    pub dimensions: usize,
}

/// AI manager
#[derive(Clone, Copy)]
pub struct AiManager;

impl AiManager {
    pub fn new() -> Self {
        Self
    }

    /// Check AI Server status
    pub async fn check_status(&self) -> anyhow::Result<AiStatus> {
        let server_running = self.is_running().await;

        let models = self.list_models().await.unwrap_or_default();
        let active_model = self.active_model().await;
        let default_model = models
            .iter()
            .find(|m| active_model.as_deref() == Some(m.name.as_str()))
            .map(|m| m.name.clone())
            .or(active_model)
            .unwrap_or_else(|| "none".to_string());
        let gpu_acceleration = self.check_gpu_acceleration().await;

        Ok(AiStatus {
            server_running,
            models,
            default_model,
            gpu_acceleration,
        })
    }

    /// List available models (.gguf files in the model directory)
    pub async fn list_models(&self) -> anyhow::Result<Vec<ModelInfo>> {
        let mut models = Vec::new();
        let model_dir = std::path::Path::new("/var/lib/lifeos/models");

        if model_dir.exists() {
            let mut entries = tokio::fs::read_dir(model_dir).await?;
            while let Some(entry) = entries.next_entry().await? {
                let path = entry.path();
                let candidate = path
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string();
                if path.is_file()
                    && path.extension().unwrap_or_default() == "gguf"
                    && is_primary_model_candidate(&candidate)
                {
                    let metadata = entry.metadata().await?;
                    let size_mb = metadata.len() / (1024 * 1024);

                    models.push(ModelInfo {
                        name: candidate,
                        size_mb,
                        modified: "local".to_string(),
                    });
                }
            }
        }

        Ok(models)
    }

    /// Check if GPU acceleration is available
    pub async fn check_gpu_acceleration(&self) -> bool {
        // Check for NVIDIA
        if let Ok(output) = Command::new("nvidia-smi").output() {
            if output.status.success() {
                return true;
            }
        }

        // Check for AMD ROCm
        if std::path::Path::new("/opt/rocm").exists() {
            return true;
        }

        // Check for Intel Arc
        if let Ok(output) = Command::new("lspci").output() {
            let output_str = String::from_utf8_lossy(&output.stdout);
            if output_str.contains("Intel") && output_str.contains("Arc") {
                return true;
            }
        }

        false
    }

    // ==================== API-Required Methods ====================

    /// Check if llama-server is running and responsive.
    ///
    /// The old implementation used `killall -0 llama-server`, but when
    /// llama-server runs as a system service while lifeosd runs in the user
    /// scope, the signal-0 probe fails with EPERM ("Operación no permitida")
    /// and reports the server as down even though it is serving traffic.
    /// Hitting `/health` is both permission-free and a better signal: it
    /// confirms the server can actually answer requests, not just that a
    /// process with the matching name exists.
    pub async fn is_running(&self) -> bool {
        let client = match reqwest::Client::builder()
            .timeout(std::time::Duration::from_millis(500))
            .build()
        {
            Ok(c) => c,
            Err(_) => return false,
        };
        match client.get("http://127.0.0.1:8082/health").send().await {
            Ok(resp) => resp.status().is_success(),
            Err(_) => false,
        }
    }

    /// Get the currently active model
    pub async fn active_model(&self) -> Option<String> {
        // Read from env file if available
        if let Ok(content) = std::fs::read_to_string("/etc/lifeos/llama-server.env") {
            for line in content.lines() {
                if let Some(model) = line.strip_prefix("LIFEOS_AI_MODEL=") {
                    return Some(model.to_string());
                }
            }
        }
        Some("Qwen3.5-4B-Q4_K_M.gguf".to_string())
    }

    /// Get list of loaded models
    pub async fn loaded_models(&self) -> Vec<String> {
        match self.list_models().await {
            Ok(models) => models.into_iter().map(|m| m.name).collect(),
            Err(_) => Vec::new(),
        }
    }

    /// Check if GPU is available
    pub async fn gpu_available(&self) -> bool {
        self.check_gpu_acceleration().await
    }

    /// Get GPU name if available
    pub async fn gpu_name(&self) -> Option<String> {
        // Check NVIDIA
        if let Ok(output) = Command::new("nvidia-smi")
            .args(["--query-gpu=name", "--format=csv,noheader"])
            .output()
        {
            if output.status.success() {
                let name = String::from_utf8_lossy(&output.stdout);
                return Some(name.trim().to_string());
            }
        }

        // Check AMD
        if let Ok(output) = Command::new("rocminfo").output() {
            let output_str = String::from_utf8_lossy(&output.stdout);
            if let Some(line) = output_str.lines().find(|l| l.contains("Marketing Name")) {
                let name = line.split(':').nth(1).unwrap_or("AMD GPU").trim();
                return Some(name.to_string());
            }
        }

        None
    }

    /// Send a chat completion request to llama-server (OpenAI-compatible API)
    pub async fn chat(
        &self,
        model: Option<&str>,
        messages: Vec<(String, String)>,
    ) -> anyhow::Result<AiChatResponse> {
        if messages.is_empty() {
            anyhow::bail!("No chat messages provided");
        }

        let model_name = if let Some(m) = model {
            m.to_string()
        } else {
            self.active_model()
                .await
                .unwrap_or_else(|| "Qwen3.5-4B-Q4_K_M.gguf".to_string())
        };

        let payload_messages: Vec<serde_json::Value> = messages
            .into_iter()
            .map(|(role, content)| serde_json::json!({ "role": role, "content": content }))
            .collect();

        let payload = serde_json::json!({
            "model": model_name,
            "messages": payload_messages,
            "stream": false,
        });

        self.chat_with_payload(payload).await
    }

    /// Send a streaming chat completion request and emit accumulated text
    /// snapshots as they arrive. The final response is returned in the same
    /// format as `chat()`.
    pub async fn chat_stream(
        &self,
        model: Option<&str>,
        messages: Vec<(String, String)>,
        partial_sender: Sender<String>,
    ) -> anyhow::Result<AiChatResponse> {
        if messages.is_empty() {
            anyhow::bail!("No chat messages provided");
        }

        let model_name = if let Some(m) = model {
            m.to_string()
        } else {
            self.active_model()
                .await
                .unwrap_or_else(|| "Qwen3.5-4B-Q4_K_M.gguf".to_string())
        };

        let payload_messages: Vec<serde_json::Value> = messages
            .into_iter()
            .map(|(role, content)| serde_json::json!({ "role": role, "content": content }))
            .collect();

        let payload = serde_json::json!({
            "model": model_name,
            "messages": payload_messages,
            "stream": true,
            "stream_options": { "include_usage": true },
        });

        self.chat_with_payload_streaming(payload, partial_sender)
            .await
    }

    /// Send a multimodal chat completion request using an image payload.
    pub async fn chat_multimodal(
        &self,
        model: Option<&str>,
        system_prompt: Option<&str>,
        prompt: &str,
        image_path: &str,
    ) -> anyhow::Result<AiChatResponse> {
        let prompt = prompt.trim();
        if prompt.is_empty() {
            anyhow::bail!("prompt is required");
        }
        if !Path::new(image_path).exists() {
            anyhow::bail!("image source not found: {}", image_path);
        }

        let model_name = if let Some(m) = model {
            m.to_string()
        } else {
            self.active_model()
                .await
                .unwrap_or_else(|| "Qwen3.5-4B-Q4_K_M.gguf".to_string())
        };

        let data_url = image_path_to_data_url(image_path)?;
        let mut messages = Vec::new();
        if let Some(system_prompt) = system_prompt
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            messages.push(serde_json::json!({
                "role": "system",
                "content": system_prompt,
            }));
        }
        messages.push(serde_json::json!({
            "role": "user",
            "content": [
                { "type": "text", "text": prompt },
                { "type": "image_url", "image_url": { "url": data_url } }
            ]
        }));

        let payload = serde_json::json!({
            "model": model_name,
            "messages": messages,
            "stream": false,
        });

        self.chat_with_payload(payload).await
    }

    async fn chat_with_payload(
        &self,
        payload: serde_json::Value,
    ) -> anyhow::Result<AiChatResponse> {
        let _permit = chat_request_semaphore()
            .acquire()
            .await
            .map_err(|_| anyhow::anyhow!("AI request limiter is unavailable"))?;
        let request_model = payload
            .get("model")
            .and_then(|value| value.as_str())
            .unwrap_or("unknown")
            .to_string();

        let response = reqwest::Client::new()
            .post("http://127.0.0.1:8082/v1/chat/completions")
            .json(&payload)
            .send()
            .await?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            let detail = truncate_error(&body);
            if detail.is_empty() {
                anyhow::bail!("llama-server returned {}", status);
            }
            anyhow::bail!("llama-server returned {}: {}", status, detail);
        }

        let body: serde_json::Value = response.json().await?;

        let response_text = extract_chat_response_text(&body);

        let response_model = body
            .get("model")
            .and_then(|m| m.as_str())
            .map(|s| s.to_string())
            .unwrap_or(request_model);

        let tokens_used = body
            .get("usage")
            .and_then(|u| u.get("total_tokens"))
            .and_then(|t| t.as_u64())
            .and_then(|t| u32::try_from(t).ok());

        Ok(AiChatResponse {
            response: response_text,
            model: response_model,
            tokens_used,
        })
    }

    async fn chat_with_payload_streaming(
        &self,
        payload: serde_json::Value,
        partial_sender: Sender<String>,
    ) -> anyhow::Result<AiChatResponse> {
        let _permit = chat_request_semaphore()
            .acquire()
            .await
            .map_err(|_| anyhow::anyhow!("AI request limiter is unavailable"))?;
        let request_model = payload
            .get("model")
            .and_then(|value| value.as_str())
            .unwrap_or("unknown")
            .to_string();

        let response = reqwest::Client::new()
            .post("http://127.0.0.1:8082/v1/chat/completions")
            .json(&payload)
            .send()
            .await?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            let detail = truncate_error(&body);
            if detail.is_empty() {
                anyhow::bail!("llama-server returned {}", status);
            }
            anyhow::bail!("llama-server returned {}: {}", status, detail);
        }

        let mut response_model = request_model;
        let mut tokens_used = None;
        let mut accumulated = String::new();
        let mut line_buffer = String::new();
        let mut done = false;
        let mut stream = response.bytes_stream();

        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            line_buffer.push_str(&String::from_utf8_lossy(&chunk));

            while let Some(newline_idx) = line_buffer.find('\n') {
                let line = line_buffer[..newline_idx].trim().to_string();
                line_buffer.drain(..=newline_idx);
                if consume_stream_sse_line(
                    &line,
                    &mut accumulated,
                    &mut response_model,
                    &mut tokens_used,
                    &partial_sender,
                ) {
                    done = true;
                    break;
                }
            }

            if done {
                break;
            }
        }

        if !done && !line_buffer.trim().is_empty() {
            let _ = consume_stream_sse_line(
                line_buffer.trim(),
                &mut accumulated,
                &mut response_model,
                &mut tokens_used,
                &partial_sender,
            );
        }

        let response_text = sanitize_generated_response(&accumulated);
        Ok(AiChatResponse {
            response: if response_text.is_empty() {
                "Lo siento, no pude generar una respuesta clara.".to_string()
            } else {
                response_text
            },
            model: response_model,
            tokens_used,
        })
    }

    /// Generate embeddings.
    ///
    /// Resolution order (best → worst quality):
    /// 1. **Dedicated nomic-embed-text server on `127.0.0.1:8083`** — started
    ///    by `llama-embeddings.service`. Returns 768-dim semantic
    ///    embeddings. This is the path the dashboard, MemoryPlane and
    ///    Telegram `recall` use in production.
    /// 2. **Hash-based fallback** — deterministic trigram hashing into a
    ///    768-dim sparse vector. Lossy and *not* semantic, but stable
    ///    enough for keyword-overlap recall when the embeddings server is
    ///    not available (offline boot, model still downloading, etc.).
    ///
    /// We do **not** call the chat-model server on `:8082` here even though
    /// it can technically serve `/v1/embeddings`: its embeddings have a
    /// different dimension than the SQLite schema's `FLOAT[768]`, so any
    /// mixing would silently corrupt the vec0 index.
    pub async fn embed(&self, text: &str) -> anyhow::Result<EmbeddingResponse> {
        const EMBEDDING_DIM: usize = 768;
        const EMBED_URL: &str = "http://127.0.0.1:8083/v1/embeddings";

        // -- 1. Dedicated semantic embeddings server (nomic-embed-text) --
        let payload = serde_json::json!({
            "model": "lifeos-embeddings",
            "input": text,
        });

        match reqwest::Client::new()
            .post(EMBED_URL)
            .json(&payload)
            .timeout(std::time::Duration::from_secs(15))
            .send()
            .await
        {
            Ok(response) if response.status().is_success() => {
                if let Ok(body) = response.json::<serde_json::Value>().await {
                    if let Some(embedding) = body["data"][0]["embedding"].as_array() {
                        let vec: Vec<f32> = embedding
                            .iter()
                            .filter_map(|v| v.as_f64().map(|f| f as f32))
                            .collect();
                        if vec.len() == EMBEDDING_DIM {
                            return Ok(EmbeddingResponse {
                                embedding: vec,
                                model: "nomic-embed-text-v1.5".to_string(),
                                dimensions: EMBEDDING_DIM,
                            });
                        } else if !vec.is_empty() {
                            // Wrong dimension — log once and fall through to
                            // the hash fallback so we never poison the index.
                            log::warn!(
                                "embeddings server returned {} dims, expected {}; falling back",
                                vec.len(),
                                EMBEDDING_DIM
                            );
                        }
                    }
                }
            }
            Ok(response) => {
                log::debug!(
                    "embeddings server returned {} — falling back to hash",
                    response.status()
                );
            }
            Err(e) => {
                log::debug!("embeddings server unreachable ({e}) — falling back to hash");
            }
        }

        // -- 2. Hash-based fallback --
        let hash_embedding = self.hash_based_embedding(text);
        let mut padded = vec![0.0f32; EMBEDDING_DIM];
        for (i, &v) in hash_embedding.iter().enumerate() {
            if i < EMBEDDING_DIM {
                padded[i] = v;
            }
        }

        Ok(EmbeddingResponse {
            embedding: padded,
            model: "hash-fallback".to_string(),
            dimensions: EMBEDDING_DIM,
        })
    }

    fn hash_based_embedding(&self, text: &str) -> Vec<f32> {
        const FALLBACK_DIM: usize = 96;
        let mut embedding = vec![0.0f32; FALLBACK_DIM];

        // Iterate by CHARACTERS, not bytes. The old implementation did
        // `&normalized[i..i + 3]` with `i` from `0..normalized.len()`, which
        // crashes with "byte index is not a char boundary" the moment the
        // input contains multi-byte UTF-8 (accents, ñ, °, em-dash, etc).
        // In production Hector's screen OCR included "24°c" and the hash
        // embedding panic-killed the tokio task that runs the screen capture
        // + vision pipeline — screen capture silently stopped and never
        // recovered until the daemon was restarted.
        let normalized: Vec<char> = text.to_lowercase().chars().collect();
        for window in normalized.windows(3) {
            let trigram: String = window.iter().collect();
            let mut hasher = DefaultHasher::new();
            trigram.hash(&mut hasher);
            let idx = (hasher.finish() as usize) % FALLBACK_DIM;
            embedding[idx] += 1.0;
        }

        let norm: f32 = embedding.iter().map(|x| x * x).sum::<f32>().sqrt();
        if norm > 0.0 {
            for e in &mut embedding {
                *e /= norm;
            }
        }

        embedding
    }
}

fn image_path_to_data_url(path: &str) -> anyhow::Result<String> {
    if let Ok(url) = optimized_image_data_url(path) {
        return Ok(url);
    }

    let bytes =
        std::fs::read(path).with_context(|| format!("Failed to read image file {}", path))?;
    let mime = match Path::new(path)
        .extension()
        .and_then(|ext| ext.to_str())
        .unwrap_or_default()
        .to_lowercase()
        .as_str()
    {
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        _ => "image/png",
    };
    Ok(format!("data:{};base64,{}", mime, B64.encode(bytes)))
}

fn optimized_image_data_url(path: &str) -> anyhow::Result<String> {
    const MAX_EDGE: u32 = 1280;
    const JPEG_QUALITY: u8 = 82;

    let image = ImageReader::open(path)
        .with_context(|| format!("Failed to open image {}", path))?
        .decode()
        .with_context(|| format!("Failed to decode image {}", path))?;

    let (width, height) = image.dimensions();
    let prepared = if width > MAX_EDGE || height > MAX_EDGE {
        image.resize(MAX_EDGE, MAX_EDGE, FilterType::Triangle)
    } else {
        image
    };

    let mut bytes = Vec::new();
    let mut encoder = JpegEncoder::new_with_quality(&mut bytes, JPEG_QUALITY);
    encoder
        .encode_image(&prepared)
        .context("Failed to encode resized image as JPEG")?;

    Ok(format!("data:image/jpeg;base64,{}", B64.encode(bytes)))
}

fn truncate_error(body: &str) -> String {
    let cleaned = body.split_whitespace().collect::<Vec<_>>().join(" ");
    if cleaned.len() <= 200 {
        return cleaned;
    }
    format!("{}...", &cleaned[..200])
}

fn consume_stream_sse_line(
    line: &str,
    accumulated: &mut String,
    response_model: &mut String,
    tokens_used: &mut Option<u32>,
    partial_sender: &Sender<String>,
) -> bool {
    let line = line.trim();
    if line.is_empty() || line.starts_with(':') {
        return false;
    }

    let Some(data) = line.strip_prefix("data:") else {
        return false;
    };
    let data = data.trim();
    if data == "[DONE]" {
        return true;
    }

    let Ok(body) = serde_json::from_str::<serde_json::Value>(data) else {
        return false;
    };

    if let Some(model) = body.get("model").and_then(|value| value.as_str()) {
        *response_model = model.to_string();
    }
    if let Some(total_tokens) = body
        .get("usage")
        .and_then(|usage| usage.get("total_tokens"))
        .and_then(|value| value.as_u64())
        .and_then(|value| u32::try_from(value).ok())
    {
        *tokens_used = Some(total_tokens);
    }

    let delta_text = extract_chat_stream_delta_text(&body);
    if !delta_text.is_empty() {
        accumulated.push_str(&delta_text);
        match partial_sender.try_send(accumulated.clone()) {
            Ok(()) => {}
            Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                log::warn!("Streaming partial channel full — dropping token chunk");
            }
            Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {}
        }
    }

    false
}

fn extract_chat_response_text(body: &serde_json::Value) -> String {
    let message = body
        .get("choices")
        .and_then(|v| v.as_array())
        .and_then(|choices| choices.first())
        .and_then(|choice| choice.get("message"));

    let mut candidates: Vec<String> = Vec::new();

    if let Some(message) = message {
        if let Some(content) = message.get("content") {
            let parsed = extract_text_from_content_value(content);
            if !parsed.is_empty() {
                candidates.push(parsed);
            }
        }

        for key in ["text", "response", "output_text"] {
            if let Some(value) = message.get(key).and_then(|v| v.as_str()) {
                let trimmed = value.trim();
                if !trimmed.is_empty() {
                    candidates.push(trimmed.to_string());
                }
            }
        }

        // Last-resort fields used by some models to expose chain-of-thought.
        // Keep them as candidates only after sanitization.
        for key in ["reasoning_content", "reasoning", "thinking"] {
            if let Some(value) = message.get(key).and_then(|v| v.as_str()) {
                let trimmed = value.trim();
                if !trimmed.is_empty() {
                    candidates.push(trimmed.to_string());
                }
            }
        }
    }

    if let Some(choice_text) = body
        .get("choices")
        .and_then(|v| v.as_array())
        .and_then(|choices| choices.first())
        .and_then(|choice| choice.get("text"))
        .and_then(|text| text.as_str())
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
    {
        candidates.push(choice_text);
    }

    for candidate in candidates {
        let cleaned = sanitize_generated_response(&candidate);
        if !cleaned.is_empty() {
            return cleaned;
        }
    }

    "Lo siento, no pude generar una respuesta clara.".to_string()
}

fn extract_chat_stream_delta_text(body: &serde_json::Value) -> String {
    let choice = body
        .get("choices")
        .and_then(|value| value.as_array())
        .and_then(|choices| choices.first());

    if let Some(delta) = choice.and_then(|choice| choice.get("delta")) {
        if let Some(content) = delta.get("content") {
            let parsed = extract_text_from_content_value(content);
            if !parsed.is_empty() {
                return parsed;
            }
        }

        for key in ["text", "response", "output_text", "reasoning_content"] {
            if let Some(text) = delta.get(key).and_then(|value| value.as_str()) {
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    return trimmed.to_string();
                }
            }
        }
    }

    if let Some(text) = choice
        .and_then(|choice| choice.get("text"))
        .and_then(|value| value.as_str())
    {
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }

    String::new()
}

fn extract_text_from_content_value(content: &serde_json::Value) -> String {
    match content {
        serde_json::Value::String(text) => text.trim().to_string(),
        serde_json::Value::Array(items) => {
            let segments: Vec<String> = items
                .iter()
                .filter_map(extract_text_segment)
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
                .collect();
            segments.join("\n")
        }
        serde_json::Value::Object(map) => {
            if let Some(text) = map.get("text").and_then(|v| v.as_str()) {
                return text.trim().to_string();
            }
            if let Some(text) = map
                .get("text")
                .and_then(|v| v.as_object())
                .and_then(|obj| obj.get("value"))
                .and_then(|v| v.as_str())
            {
                return text.trim().to_string();
            }
            if let Some(inner) = map.get("content") {
                return extract_text_from_content_value(inner);
            }
            String::new()
        }
        _ => String::new(),
    }
}

fn extract_text_segment(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(text) => Some(text.to_string()),
        serde_json::Value::Object(map) => {
            if let Some(text) = map.get("text").and_then(|v| v.as_str()) {
                return Some(text.to_string());
            }
            if let Some(text) = map
                .get("text")
                .and_then(|v| v.as_object())
                .and_then(|obj| obj.get("value"))
                .and_then(|v| v.as_str())
            {
                return Some(text.to_string());
            }
            map.get("content")
                .map(extract_text_from_content_value)
                .filter(|v| !v.trim().is_empty())
        }
        _ => None,
    }
}

fn sanitize_generated_response(raw: &str) -> String {
    let mut text = strip_think_sections(raw);
    text = text
        .replace("<think>", " ")
        .replace("</think>", " ")
        .replace("<|im_start|>", " ")
        .replace("<|im_end|>", " ");

    // Strip markdown bold/italic asterisks — these pollute TTS and chat responses
    text = text.replace("**", "").replace('*', "");

    let mut cleaned_lines = Vec::new();
    let mut in_code_fence = false;
    for raw_line in text.lines() {
        let mut line = raw_line.trim();
        if line.starts_with("```") {
            in_code_fence = !in_code_fence;
            continue;
        }
        if in_code_fence || line.is_empty() {
            continue;
        }
        line = strip_leading_list_marker(line)
            .trim_start_matches('#')
            .trim()
            .trim_matches('`')
            .trim();
        if line.is_empty() {
            continue;
        }
        if looks_like_internal_reasoning_line(line) {
            continue;
        }
        cleaned_lines.push(line.to_string());
    }

    let cleaned = normalize_whitespace(&cleaned_lines.join(" "));
    if !cleaned.is_empty() {
        return cleaned;
    }

    extract_quoted_spoken_text(raw)
}

fn strip_think_sections(input: &str) -> String {
    let mut output = String::new();
    let mut rest = input;
    loop {
        if let Some(start) = rest.find("<think>") {
            output.push_str(&rest[..start]);
            let after_start = &rest[start + "<think>".len()..];
            if let Some(end_rel) = after_start.find("</think>") {
                rest = &after_start[end_rel + "</think>".len()..];
            } else {
                break;
            }
        } else {
            output.push_str(rest);
            break;
        }
    }
    output
}

fn normalize_whitespace(input: &str) -> String {
    input.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn looks_like_internal_reasoning_line(line: &str) -> bool {
    let normalized = normalize_whitespace(line)
        .trim_start_matches(['*', '-', '#', '`', '>', ' '])
        .to_lowercase();
    [
        "thinking process",
        "analysis:",
        "reasoning:",
        "internal reasoning",
        "the user wants",
        "i need to",
        "let me ",
        "analyze the request",
        "determine the output",
        "drafting the response",
        "selection:",
        "check constraints",
        "final polish",
        "goal:",
        "constraints:",
    ]
    .iter()
    .any(|prefix| normalized.starts_with(prefix))
}

fn strip_leading_list_marker(line: &str) -> &str {
    let trimmed = line.trim_start();
    let trimmed = trimmed
        .strip_prefix("- ")
        .or_else(|| trimmed.strip_prefix("* "))
        .or_else(|| trimmed.strip_prefix("• "))
        .unwrap_or(trimmed);

    let bytes = trimmed.as_bytes();
    let mut idx = 0usize;
    while idx < bytes.len() && bytes[idx].is_ascii_digit() {
        idx += 1;
    }
    if idx > 0 && idx + 1 < bytes.len() && (bytes[idx] == b'.' || bytes[idx] == b')') {
        let mut next = idx + 1;
        while next < bytes.len() && bytes[next].is_ascii_whitespace() {
            next += 1;
        }
        return trimmed[next..].trim_start();
    }

    trimmed
}

fn extract_quoted_spoken_text(raw: &str) -> String {
    let mut best = String::new();
    let mut current = String::new();
    let mut in_quote = false;

    for ch in raw.chars() {
        if matches!(ch, '"' | '“' | '”') {
            if in_quote {
                let candidate = normalize_whitespace(current.trim());
                if candidate.len() > best.len() {
                    best = candidate;
                }
                current.clear();
                in_quote = false;
            } else {
                in_quote = true;
                current.clear();
            }
            continue;
        }

        if in_quote {
            current.push(ch);
        }
    }

    best
}

fn chat_request_semaphore() -> &'static Semaphore {
    static SEMAPHORE: OnceLock<Semaphore> = OnceLock::new();
    SEMAPHORE.get_or_init(|| Semaphore::new(1))
}

impl Default for AiManager {
    fn default() -> Self {
        Self::new()
    }
}

fn is_primary_model_candidate(model: &str) -> bool {
    let lower = model.to_ascii_lowercase();
    !lower.starts_with("mmproj-")
        && !lower.contains("-mmproj-")
        && !lower.starts_with("nomic-embed-")
        && !lower.starts_with("whisper")
        && !lower.contains("embedding")
}

#[cfg(test)]
mod tests {
    use super::{
        consume_stream_sse_line, extract_chat_response_text, extract_chat_stream_delta_text,
    };
    use tokio::sync::mpsc;

    #[test]
    fn extract_chat_response_handles_string_content() {
        let body = serde_json::json!({
            "choices": [
                { "message": { "content": "Hola desde string" } }
            ]
        });

        assert_eq!(extract_chat_response_text(&body), "Hola desde string");
    }

    #[test]
    fn extract_chat_response_handles_array_content() {
        let body = serde_json::json!({
            "choices": [
                {
                    "message": {
                        "content": [
                            { "type": "text", "text": "Linea 1" },
                            { "type": "output_text", "text": { "value": "Linea 2" } }
                        ]
                    }
                }
            ]
        });

        assert_eq!(extract_chat_response_text(&body), "Linea 1 Linea 2");
    }

    #[test]
    fn extract_chat_response_prefers_quoted_final_text_over_reasoning() {
        let body = serde_json::json!({
            "choices": [
                {
                    "message": {
                        "content": "",
                        "reasoning_content": "Thinking Process: Analyze the request. **Final Polish:** \"Hola, claro que si.\""
                    }
                }
            ]
        });

        assert_eq!(extract_chat_response_text(&body), "Hola, claro que si.");
    }

    #[test]
    fn extract_chat_response_discards_reasoning_only_payload() {
        let body = serde_json::json!({
            "choices": [
                {
                    "message": {
                        "content": "",
                        "reasoning_content": "Thinking Process: Analyze constraints and draft output."
                    }
                }
            ]
        });

        assert_eq!(
            extract_chat_response_text(&body),
            "Lo siento, no pude generar una respuesta clara."
        );
    }

    #[test]
    fn extract_chat_stream_delta_handles_string_content() {
        let body = serde_json::json!({
            "choices": [
                { "delta": { "content": "Hola parcial" } }
            ]
        });

        assert_eq!(extract_chat_stream_delta_text(&body), "Hola parcial");
    }

    #[test]
    fn extract_chat_stream_delta_handles_array_content() {
        let body = serde_json::json!({
            "choices": [
                {
                    "delta": {
                        "content": [
                            { "type": "text", "text": "Linea" },
                            { "type": "output_text", "text": { "value": "dos" } }
                        ]
                    }
                }
            ]
        });

        assert_eq!(extract_chat_stream_delta_text(&body), "Linea\ndos");
    }

    #[test]
    fn consume_stream_sse_line_accumulates_partial_text() {
        let (sender, mut receiver) = mpsc::channel(1024);
        let mut accumulated = String::new();
        let mut model = "unknown".to_string();
        let mut tokens = None;

        let done = consume_stream_sse_line(
            r#"data: {"model":"qwen","choices":[{"delta":{"content":"Hola"}}]}"#,
            &mut accumulated,
            &mut model,
            &mut tokens,
            &sender,
        );

        assert!(!done);
        assert_eq!(model, "qwen");
        assert_eq!(accumulated, "Hola");
        assert_eq!(receiver.try_recv().unwrap(), "Hola");
        assert_eq!(tokens, None);
    }
}
