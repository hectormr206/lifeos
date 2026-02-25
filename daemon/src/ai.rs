//! AI module for daemon
//! Manages Ollama integration and AI-related system tasks

use serde::{Serialize, Deserialize};
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
        let default_model = models.first().map(|m| m.name.clone()).unwrap_or_else(|| "none".to_string());
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
                    let name = path.file_name().unwrap_or_default().to_string_lossy().to_string();
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
            .args(["-m", &model_path, "--port", "11434", "-c", "4096"])
            .spawn()?;

        Ok(())
    }

    /// Stop llama-server
    pub async fn stop_server(&self) -> anyhow::Result<()> {
        Command::new("killall")
            .args(["llama-server"])
            .output()?;

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
        // For now, return the default model
        Some("qwen3:8b".to_string())
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
}

impl Default for AiManager {
    fn default() -> Self {
        Self::new()
    }
}

