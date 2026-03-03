//! AI module for daemon
//! Manages llama-server integration and AI-related system tasks

use serde::{Deserialize, Serialize};
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

/// AI manager
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
            .or_else(|| {
                payload
                    .get("model")
                    .and_then(|m| m.as_str())
                    .map(|s| s.to_string())
            })
            .unwrap_or_else(|| "unknown".to_string());

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
}

impl Default for AiManager {
    fn default() -> Self {
        Self::new()
    }
}
