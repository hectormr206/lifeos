//! AI module for daemon
//! Manages Ollama integration and AI-related system tasks

use serde::{Serialize, Deserialize};
use std::process::Command;

/// AI service status
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiStatus {
    pub ollama_running: bool,
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

    /// Check Ollama service status
    pub async fn check_status(&self) -> anyhow::Result<AiStatus> {
        // Check if Ollama is running
        let service_check = Command::new("systemctl")
            .args(["is-active", "ollama"])
            .output()?;
        
        let ollama_running = service_check.status.success();

        // Get list of models
        let models = if ollama_running {
            self.list_models().await.unwrap_or_default()
        } else {
            Vec::new()
        };

        // Check GPU acceleration
        let gpu_acceleration = self.check_gpu_acceleration().await;

        Ok(AiStatus {
            ollama_running,
            models,
            default_model: "qwen3:8b".to_string(),
            gpu_acceleration,
        })
    }

    /// List available models
    pub async fn list_models(&self) -> anyhow::Result<Vec<ModelInfo>> {
        let output = Command::new("ollama")
            .args(["list"])
            .output()?;

        if !output.status.success() {
            anyhow::bail!("Failed to list models");
        }

        let output_str = String::from_utf8_lossy(&output.stdout);
        let mut models = Vec::new();

        // Skip header line
        for line in output_str.lines().skip(1) {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 3 {
                models.push(ModelInfo {
                    name: parts[0].to_string(),
                    size_mb: parse_size(parts[1]),
                    modified: parts[2..].join(" "),
                });
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

    /// Start Ollama service
    pub async fn start_ollama(&self) -> anyhow::Result<()> {
        let output = Command::new("systemctl")
            .args(["start", "ollama"])
            .output()?;

        if !output.status.success() {
            anyhow::bail!("Failed to start Ollama service");
        }

        Ok(())
    }

    /// Stop Ollama service
    pub async fn stop_ollama(&self) -> anyhow::Result<()> {
        let output = Command::new("systemctl")
            .args(["stop", "ollama"])
            .output()?;

        if !output.status.success() {
            anyhow::bail!("Failed to stop Ollama service");
        }

        Ok(())
    }

    // ==================== API-Required Methods ====================

    /// Check if Ollama is running
    pub async fn is_running(&self) -> bool {
        Command::new("systemctl")
            .args(["is-active", "ollama"])
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

fn parse_size(size_str: &str) -> u64 {
    let size_str = size_str.to_uppercase();
    let multiplier = if size_str.ends_with("GB") {
        1024
    } else if size_str.ends_with("MB") {
        1
    } else if size_str.ends_with("TB") {
        1024 * 1024
    } else {
        1
    };

    size_str
        .trim_end_matches("GB")
        .trim_end_matches("MB")
        .trim_end_matches("TB")
        .trim()
        .parse::<f64>()
        .map(|v| (v * multiplier as f64) as u64)
        .unwrap_or(0)
}
