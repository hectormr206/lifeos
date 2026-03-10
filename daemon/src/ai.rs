//! AI module for daemon
//! Manages llama-server integration and AI-related system tasks

use anyhow::Context;
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::Path;
use std::process::Command;

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
        let default_model = models
            .first()
            .map(|m| m.name.clone())
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
                if path.is_file() && path.extension().unwrap_or_default() == "gguf" {
                    let metadata = entry.metadata().await?;
                    let name = path
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .to_string();
                    let size_mb = metadata.len() / (1024 * 1024);

                    models.push(ModelInfo {
                        name,
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

    /// Start llama-server
    pub async fn start_server(&self) -> anyhow::Result<()> {
        let models = self.list_models().await?;
        let first_model = match models.first() {
            Some(m) => m.name.clone(),
            None => anyhow::bail!("No models found in /var/lib/lifeos/models"),
        };

        let model_path = format!("/var/lib/lifeos/models/{}", first_model);

        Command::new("llama-server")
            .env("GGML_BACKEND_PATH", "/usr/lib64")
            .args(["-m", &model_path, "--port", "8082", "-c", "4096"])
            .spawn()?;

        Ok(())
    }

    /// Stop llama-server
    pub async fn stop_server(&self) -> anyhow::Result<()> {
        Command::new("killall").args(["llama-server"]).output()?;

        Ok(())
    }

    // ==================== API-Required Methods ====================

    /// Check if llama-server is running
    pub async fn is_running(&self) -> bool {
        Command::new("killall")
            .args(["-0", "llama-server"])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
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
            anyhow::bail!("llama-server returned {}", response.status());
        }

        let body: serde_json::Value = response.json().await?;

        let response_text = body
            .get("choices")
            .and_then(|v| v.as_array())
            .and_then(|choices| choices.first())
            .and_then(|choice| choice.get("message"))
            .and_then(|message| message.get("content"))
            .and_then(|content| content.as_str())
            .map(|s| s.to_string())
            .unwrap_or_default();

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

    /// Generate embeddings using llama-server's OpenAI-compatible API
    /// Falls back to hash-based embeddings if llama-server is unavailable
    pub async fn embed(&self, text: &str) -> anyhow::Result<EmbeddingResponse> {
        const EMBEDDING_DIM: usize = 768;

        if self.is_running().await {
            let payload = serde_json::json!({
                "model": "nomic-embed-text-v1.5.f16.gguf",
                "input": text
            });

            match reqwest::Client::new()
                .post("http://127.0.0.1:8082/v1/embeddings")
                .json(&payload)
                .timeout(std::time::Duration::from_secs(30))
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
                                    model: "nomic-embed-text".to_string(),
                                    dimensions: EMBEDDING_DIM,
                                });
                            }
                        }
                    }
                }
                _ => {}
            }
        }

        log::warn!("llama-server embeddings unavailable, using hash-based fallback");
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

        let normalized = text.to_lowercase();
        for i in 0..normalized.len().saturating_sub(2) {
            let trigram = &normalized[i..i + 3];
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

impl Default for AiManager {
    fn default() -> Self {
        Self::new()
    }
}
