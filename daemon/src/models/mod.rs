//! Extended AI Model Management
//!
//! Provides support for GGUF models with hardware-aware
//! recommendations and automatic model selection.
#![allow(dead_code)]

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Available AI models with metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelRegistry {
    pub models: HashMap<String, ModelInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelInfo {
    pub id: String,
    pub name: String,
    pub description: String,
    pub parameter_size: String,
    pub size_gb: f32,
    pub tags: Vec<String>,
    pub capabilities: ModelCapabilities,
    pub hardware_requirements: HardwareRequirements,
    pub recommended_use: Vec<String>,
    pub performance_tier: PerformanceTier,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelCapabilities {
    pub chat: bool,
    pub code_generation: bool,
    pub reasoning: bool,
    pub vision: bool,
    pub multilingual: bool,
    pub function_calling: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HardwareRequirements {
    pub min_ram_gb: u32,
    pub recommended_ram_gb: u32,
    pub min_vram_gb: Option<u32>,
    pub recommended_vram_gb: Option<u32>,
    pub gpu_required: bool,
    pub quantization: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum PerformanceTier {
    UltraFast,  // 1-3B parameters
    Fast,       // 4-8B parameters
    Balanced,   // 8-14B parameters
    Capable,    // 14-32B parameters
    Powerful,   // 32-70B parameters
    Maximum,    // 70B+ parameters
}

impl Default for ModelRegistry {
    fn default() -> Self {
        let mut models = HashMap::new();

        // === QWEN MODELS ===
        models.insert(
            "qwen3-8b-q4_k_m.gguf".to_string(),
            ModelInfo {
                id: "qwen3-8b-q4_k_m.gguf".to_string(),
                name: "Qwen3 8B".to_string(),
                description: "Alibaba's latest multilingual model with excellent reasoning".to_string(),
                parameter_size: "8B".to_string(),
                size_gb: 4.8,
                tags: vec!["multilingual".to_string(), "reasoning".to_string(), "recommended".to_string()],
                capabilities: ModelCapabilities {
                    chat: true,
                    code_generation: true,
                    reasoning: true,
                    vision: false,
                    multilingual: true,
                    function_calling: true,
                },
                hardware_requirements: HardwareRequirements {
                    min_ram_gb: 8,
                    recommended_ram_gb: 16,
                    min_vram_gb: Some(4),
                    recommended_vram_gb: Some(8),
                    gpu_required: false,
                    quantization: vec!["q4_0".to_string(), "q5_0".to_string()],
                },
                recommended_use: vec![
                    "general_chat".to_string(),
                    "coding".to_string(),
                    "analysis".to_string(),
                    "writing".to_string(),
                ],
                performance_tier: PerformanceTier::Balanced,
            },
        );

        models.insert(
            "qwen3-14b-q4_k_m.gguf".to_string(),
            ModelInfo {
                id: "qwen3-14b-q4_k_m.gguf".to_string(),
                name: "Qwen3 14B".to_string(),
                description: "Larger Qwen3 with improved reasoning capabilities".to_string(),
                parameter_size: "14B".to_string(),
                size_gb: 8.5,
                tags: vec!["multilingual".to_string(), "reasoning".to_string(), "advanced".to_string()],
                capabilities: ModelCapabilities {
                    chat: true,
                    code_generation: true,
                    reasoning: true,
                    vision: false,
                    multilingual: true,
                    function_calling: true,
                },
                hardware_requirements: HardwareRequirements {
                    min_ram_gb: 16,
                    recommended_ram_gb: 32,
                    min_vram_gb: Some(8),
                    recommended_vram_gb: Some(12),
                    gpu_required: false,
                    quantization: vec!["q4_0".to_string(), "q5_0".to_string()],
                },
                recommended_use: vec![
                    "complex_analysis".to_string(),
                    "advanced_coding".to_string(),
                    "document_processing".to_string(),
                ],
                performance_tier: PerformanceTier::Capable,
            },
        );

        // === LLAMA MODELS ===
        models.insert(
            "llama-3.2-3b-instruct-q4_k_m.gguf".to_string(),
            ModelInfo {
                id: "llama-3.2-3b-instruct-q4_k_m.gguf".to_string(),
                name: "Llama 3.2 3B".to_string(),
                description: "Lightweight, fast model for quick tasks".to_string(),
                parameter_size: "3B".to_string(),
                size_gb: 2.0,
                tags: vec!["fast".to_string(), "efficient".to_string(), "edge".to_string()],
                capabilities: ModelCapabilities {
                    chat: true,
                    code_generation: true,
                    reasoning: false,
                    vision: false,
                    multilingual: true,
                    function_calling: false,
                },
                hardware_requirements: HardwareRequirements {
                    min_ram_gb: 4,
                    recommended_ram_gb: 8,
                    min_vram_gb: None,
                    recommended_vram_gb: Some(4),
                    gpu_required: false,
                    quantization: vec!["q4_0".to_string()],
                },
                recommended_use: vec![
                    "quick_chat".to_string(),
                    "simple_tasks".to_string(),
                    "edge_devices".to_string(),
                ],
                performance_tier: PerformanceTier::Fast,
            },
        );

        models.insert(
            "llama-3.2-1b-instruct-q4_k_m.gguf".to_string(),
            ModelInfo {
                id: "llama-3.2-1b-instruct-q4_k_m.gguf".to_string(),
                name: "Llama 3.2 1B".to_string(),
                description: "Ultra-lightweight for resource-constrained devices".to_string(),
                parameter_size: "1B".to_string(),
                size_gb: 1.3,
                tags: vec!["ultra-fast".to_string(), "minimal".to_string()],
                capabilities: ModelCapabilities {
                    chat: true,
                    code_generation: false,
                    reasoning: false,
                    vision: false,
                    multilingual: true,
                    function_calling: false,
                },
                hardware_requirements: HardwareRequirements {
                    min_ram_gb: 2,
                    recommended_ram_gb: 4,
                    min_vram_gb: None,
                    recommended_vram_gb: None,
                    gpu_required: false,
                    quantization: vec!["q4_0".to_string()],
                },
                recommended_use: vec![
                    "basic_chat".to_string(),
                    "very_old_hardware".to_string(),
                    "battery_life".to_string(),
                ],
                performance_tier: PerformanceTier::UltraFast,
            },
        );

        models.insert(
            "llama-3.1-8b-instruct-q4_k_m.gguf".to_string(),
            ModelInfo {
                id: "llama-3.1-8b-instruct-q4_k_m.gguf".to_string(),
                name: "Llama 3.1 8B".to_string(),
                description: "Meta's powerful general-purpose model".to_string(),
                parameter_size: "8B".to_string(),
                size_gb: 4.7,
                tags: vec!["general".to_string(), "powerful".to_string()],
                capabilities: ModelCapabilities {
                    chat: true,
                    code_generation: true,
                    reasoning: true,
                    vision: false,
                    multilingual: true,
                    function_calling: true,
                },
                hardware_requirements: HardwareRequirements {
                    min_ram_gb: 8,
                    recommended_ram_gb: 16,
                    min_vram_gb: Some(4),
                    recommended_vram_gb: Some(8),
                    gpu_required: false,
                    quantization: vec!["q4_0".to_string(), "q5_0".to_string()],
                },
                recommended_use: vec![
                    "general_purpose".to_string(),
                    "chat".to_string(),
                    "coding".to_string(),
                ],
                performance_tier: PerformanceTier::Balanced,
            },
        );

        // === CODE MODELS ===
        models.insert(
            "codellama-7b-instruct-q4_k_m.gguf".to_string(),
            ModelInfo {
                id: "codellama-7b-instruct-q4_k_m.gguf".to_string(),
                name: "CodeLlama 7B".to_string(),
                description: "Optimized for code generation and programming tasks".to_string(),
                parameter_size: "7B".to_string(),
                size_gb: 3.8,
                tags: vec!["coding".to_string(), "programming".to_string()],
                capabilities: ModelCapabilities {
                    chat: true,
                    code_generation: true,
                    reasoning: true,
                    vision: false,
                    multilingual: false,
                    function_calling: false,
                },
                hardware_requirements: HardwareRequirements {
                    min_ram_gb: 8,
                    recommended_ram_gb: 16,
                    min_vram_gb: Some(4),
                    recommended_vram_gb: Some(8),
                    gpu_required: false,
                    quantization: vec!["q4_0".to_string()],
                },
                recommended_use: vec![
                    "code_generation".to_string(),
                    "code_review".to_string(),
                    "debugging".to_string(),
                ],
                performance_tier: PerformanceTier::Balanced,
            },
        );

        models.insert(
            "deepseek-coder-6.7b-instruct-q4_k_m.gguf".to_string(),
            ModelInfo {
                id: "deepseek-coder-6.7b-instruct-q4_k_m.gguf".to_string(),
                name: "DeepSeek Coder 6.7B".to_string(),
                description: "Excellent coding assistant with fill-in-the-middle support".to_string(),
                parameter_size: "6.7B".to_string(),
                size_gb: 3.8,
                tags: vec!["coding".to_string(), "fill-in-middle".to_string()],
                capabilities: ModelCapabilities {
                    chat: true,
                    code_generation: true,
                    reasoning: true,
                    vision: false,
                    multilingual: true,
                    function_calling: false,
                },
                hardware_requirements: HardwareRequirements {
                    min_ram_gb: 8,
                    recommended_ram_gb: 16,
                    min_vram_gb: Some(4),
                    recommended_vram_gb: Some(8),
                    gpu_required: false,
                    quantization: vec!["q4_0".to_string()],
                },
                recommended_use: vec![
                    "code_completion".to_string(),
                    "code_generation".to_string(),
                    "technical_writing".to_string(),
                ],
                performance_tier: PerformanceTier::Balanced,
            },
        );

        // === MISTRAL MODELS ===
        models.insert(
            "mistral-7b-instruct-v0.3-q4_k_m.gguf".to_string(),
            ModelInfo {
                id: "mistral-7b-instruct-v0.3-q4_k_m.gguf".to_string(),
                name: "Mistral 7B".to_string(),
                description: "Strong general-purpose model with excellent performance".to_string(),
                parameter_size: "7B".to_string(),
                size_gb: 4.1,
                tags: vec!["general".to_string(), "efficient".to_string()],
                capabilities: ModelCapabilities {
                    chat: true,
                    code_generation: true,
                    reasoning: true,
                    vision: false,
                    multilingual: true,
                    function_calling: true,
                },
                hardware_requirements: HardwareRequirements {
                    min_ram_gb: 8,
                    recommended_ram_gb: 16,
                    min_vram_gb: Some(4),
                    recommended_vram_gb: Some(8),
                    gpu_required: false,
                    quantization: vec!["q4_0".to_string(), "q5_0".to_string()],
                },
                recommended_use: vec![
                    "general_chat".to_string(),
                    "writing".to_string(),
                    "analysis".to_string(),
                ],
                performance_tier: PerformanceTier::Balanced,
            },
        );

        // === GEMMA MODELS ===
        models.insert(
            "gemma-2-2b-it-q4_k_m.gguf".to_string(),
            ModelInfo {
                id: "gemma-2-2b-it-q4_k_m.gguf".to_string(),
                name: "Gemma 2 2B".to_string(),
                description: "Google's efficient small model".to_string(),
                parameter_size: "2B".to_string(),
                size_gb: 1.6,
                tags: vec!["efficient".to_string(), "fast".to_string()],
                capabilities: ModelCapabilities {
                    chat: true,
                    code_generation: true,
                    reasoning: false,
                    vision: false,
                    multilingual: true,
                    function_calling: false,
                },
                hardware_requirements: HardwareRequirements {
                    min_ram_gb: 4,
                    recommended_ram_gb: 8,
                    min_vram_gb: None,
                    recommended_vram_gb: Some(4),
                    gpu_required: false,
                    quantization: vec!["q4_0".to_string()],
                },
                recommended_use: vec![
                    "quick_tasks".to_string(),
                    "simple_chat".to_string(),
                ],
                performance_tier: PerformanceTier::Fast,
            },
        );

        // === PHI MODELS ===
        models.insert(
            "phi-3-medium-128k-instruct-q4_k_m.gguf".to_string(),
            ModelInfo {
                id: "phi-3-medium-128k-instruct-q4_k_m.gguf".to_string(),
                name: "Phi-3 Medium".to_string(),
                description: "Microsoft's capable model with excellent quality".to_string(),
                parameter_size: "14B".to_string(),
                size_gb: 7.9,
                tags: vec!["high-quality".to_string(), "microsoft".to_string()],
                capabilities: ModelCapabilities {
                    chat: true,
                    code_generation: true,
                    reasoning: true,
                    vision: false,
                    multilingual: true,
                    function_calling: true,
                },
                hardware_requirements: HardwareRequirements {
                    min_ram_gb: 16,
                    recommended_ram_gb: 32,
                    min_vram_gb: Some(8),
                    recommended_vram_gb: Some(12),
                    gpu_required: false,
                    quantization: vec!["q4_0".to_string()],
                },
                recommended_use: vec![
                    "high-quality_chat".to_string(),
                    "complex_reasoning".to_string(),
                ],
                performance_tier: PerformanceTier::Capable,
            },
        );

        // === VISION MODELS ===
        models.insert(
            "llava-v1.5-7b-q4_k_m.gguf".to_string(),
            ModelInfo {
                id: "llava-v1.5-7b-q4_k_m.gguf".to_string(),
                name: "LLaVA 7B".to_string(),
                description: "Vision-language model for image understanding".to_string(),
                parameter_size: "7B".to_string(),
                size_gb: 4.5,
                tags: vec!["vision".to_string(), "multimodal".to_string()],
                capabilities: ModelCapabilities {
                    chat: true,
                    code_generation: false,
                    reasoning: true,
                    vision: true,
                    multilingual: true,
                    function_calling: false,
                },
                hardware_requirements: HardwareRequirements {
                    min_ram_gb: 8,
                    recommended_ram_gb: 16,
                    min_vram_gb: Some(4),
                    recommended_vram_gb: Some(8),
                    gpu_required: false,
                    quantization: vec!["q4_0".to_string()],
                },
                recommended_use: vec![
                    "image_description".to_string(),
                    "visual_qa".to_string(),
                    "screen_understanding".to_string(),
                ],
                performance_tier: PerformanceTier::Balanced,
            },
        );

        ModelRegistry { models }
    }
}

impl ModelRegistry {
    /// Get all available models
    pub fn all_models(&self) -> Vec<&ModelInfo> {
        self.models.values().collect()
    }

    /// Get models by capability
    pub fn by_capability(&self, capability: &str) -> Vec<&ModelInfo> {
        self.models
            .values()
            .filter(|m| match capability {
                "chat" => m.capabilities.chat,
                "code" => m.capabilities.code_generation,
                "vision" => m.capabilities.vision,
                "reasoning" => m.capabilities.reasoning,
                "multilingual" => m.capabilities.multilingual,
                _ => false,
            })
            .collect()
    }

    /// Get models by performance tier
    pub fn by_tier(&self, tier: PerformanceTier) -> Vec<&ModelInfo> {
        self.models
            .values()
            .filter(|m| m.performance_tier == tier)
            .collect()
    }

    /// Get recommended models for given hardware
    pub fn recommended_for_hardware(
        &self,
        ram_gb: u32,
        vram_gb: Option<u32>,
    ) -> Vec<&ModelInfo> {
        self.models
            .values()
            .filter(|m| {
                let ram_ok = m.hardware_requirements.min_ram_gb <= ram_gb;
                let vram_ok = match (m.hardware_requirements.min_vram_gb, vram_gb) {
                    (Some(req), Some(avail)) => req <= avail,
                    (Some(_), None) => false,
                    _ => true,
                };
                ram_ok && vram_ok
            })
            .collect()
    }

    /// Get the best default model for given hardware
    pub fn default_for_hardware(
        &self,
        ram_gb: u32,
        vram_gb: Option<u32>,
    ) -> Option<&ModelInfo> {
        self.recommended_for_hardware(ram_gb, vram_gb)
            .into_iter()
            .find(|m| m.tags.contains(&"recommended".to_string()))
            .or_else(|| {
                // Fallback to first balanced tier model
                self.recommended_for_hardware(ram_gb, vram_gb)
                    .into_iter()
                    .find(|m| m.performance_tier == PerformanceTier::Balanced)
            })
    }

    /// Search models by query string
    pub fn search(&self, query: &str) -> Vec<&ModelInfo> {
        let query_lower = query.to_lowercase();
        self.models
            .values()
            .filter(|m| {
                m.id.to_lowercase().contains(&query_lower)
                    || m.name.to_lowercase().contains(&query_lower)
                    || m.description.to_lowercase().contains(&query_lower)
                    || m.tags.iter().any(|t| t.to_lowercase().contains(&query_lower))
            })
            .collect()
    }
}

/// System hardware information for model selection
#[derive(Debug, Clone)]
pub struct SystemHardware {
    pub total_ram_gb: u32,
    pub available_ram_gb: u32,
    pub total_vram_gb: Option<u32>,
    pub gpu_name: Option<String>,
    pub cpu_cores: u32,
}

/// Model recommendation result
#[derive(Debug, Serialize)]
pub struct ModelRecommendation {
    pub recommended: String,
    pub alternatives: Vec<String>,
    pub reasoning: String,
    pub hardware_friendly: bool,
}

/// Get model recommendation based on system hardware
pub fn recommend_model(hardware: &SystemHardware, use_case: Option<&str>) -> ModelRecommendation {
    let registry = ModelRegistry::default();
    
    // Find compatible models
    let compatible = registry.recommended_for_hardware(
        hardware.total_ram_gb,
        hardware.total_vram_gb,
    );

    // Filter by use case if specified
    let candidates: Vec<&ModelInfo> = match use_case {
        Some("chat") => compatible.into_iter().filter(|m| m.capabilities.chat).collect(),
        Some("code") | Some("coding") => compatible.into_iter().filter(|m| m.capabilities.code_generation).collect(),
        Some("vision") => compatible.into_iter().filter(|m| m.capabilities.vision).collect(),
        _ => compatible,
    };

    if candidates.is_empty() {
        return ModelRecommendation {
            recommended: "qwen3-8b-q4_k_m.gguf".to_string(),
            alternatives: vec!["llama-3.2-3b-instruct-q4_k_m.gguf".to_string()],
            reasoning: "No fully compatible models found. Using default with reduced performance.".to_string(),
            hardware_friendly: false,
        };
    }

    // Select best match
    let recommended = candidates
        .iter()
        .find(|m| m.tags.contains(&"recommended".to_string()))
        .or_else(|| candidates.first())
        .unwrap();

    // Get alternatives
    let alternatives: Vec<String> = candidates
        .iter()
        .filter(|m| m.id != recommended.id)
        .take(3)
        .map(|m| m.id.clone())
        .collect();

    // Generate reasoning
    let reasoning = format!(
        "Based on your {}GB RAM{}: {} offers the best balance of performance and quality for your hardware.",
        hardware.total_ram_gb,
        hardware.total_vram_gb.map(|v| format!(" and {}GB VRAM", v)).unwrap_or_default(),
        recommended.name
    );

    ModelRecommendation {
        recommended: recommended.id.clone(),
        alternatives,
        reasoning,
        hardware_friendly: true,
    }
}

/// Detect system hardware for model selection
pub fn detect_hardware() -> SystemHardware {
    // This would read actual system information
    // For now, provide a default implementation
    
    let total_ram_gb = detect_ram_gb();
    let (total_vram_gb, gpu_name) = detect_gpu();
    
    SystemHardware {
        total_ram_gb,
        available_ram_gb: total_ram_gb / 2, // Conservative estimate
        total_vram_gb,
        gpu_name,
        cpu_cores: num_cpus::get() as u32,
    }
}

fn detect_ram_gb() -> u32 {
    // Read from /proc/meminfo
    if let Ok(content) = std::fs::read_to_string("/proc/meminfo") {
        for line in content.lines() {
            if line.starts_with("MemTotal:") {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 2 {
                    if let Ok(kb) = parts[1].parse::<u64>() {
                        return (kb / 1024 / 1024) as u32;
                    }
                }
            }
        }
    }
    
    // Default fallback
    8
}

fn detect_gpu() -> (Option<u32>, Option<String>) {
    // Try nvidia-smi first
    if let Ok(output) = std::process::Command::new("nvidia-smi")
        .args(["--query-gpu=name,memory.total", "--format=csv,noheader,nounits"])
        .output()
    {
        if output.status.success() {
            let output_str = String::from_utf8_lossy(&output.stdout);
            let parts: Vec<&str> = output_str.split(',').collect();
            if parts.len() >= 2 {
                let name = parts[0].trim().to_string();
                if let Ok(vram_mb) = parts[1].trim().parse::<u32>() {
                    return (Some(vram_mb / 1024), Some(name));
                }
            }
        }
    }
    
    // Try rocm-smi for AMD
    if let Ok(_output) = std::process::Command::new("rocm-smi")
        .args(["--showmeminfo", "vram"])
        .output()
    {
        // Parse ROCm output
        // Simplified for now
    }
    
    (None, None)
}
