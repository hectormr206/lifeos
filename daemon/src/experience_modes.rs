//! Experience Modes Management
//!
//! Provides different experience levels for LifeOS:
//! - Simple: Minimalist for new users
//! - Pro: Complete for advanced users
//! - Builder: Dev tools for developers
//!
//! Each mode has different settings, UI, and feature availability.

use anyhow::{Context, Result};
use log::{info, warn};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::RwLock;

/// Experience mode configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExperienceMode {
    /// Mode name (simple, pro, builder)
    pub name: String,
    /// Display name
    pub display_name: String,
    /// Description
    pub description: String,
    /// Mode-specific settings
    pub settings: ModeSettings,
}

/// Mode-specific settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModeSettings {
    /// UI complexity level
    pub ui_complexity: UiComplexity,
    /// Available features
    pub features: Vec<Feature>,
    /// Default keyboard shortcuts
    pub shortcuts: ShortcutsConfig,
    /// Overlay AI settings
    pub overlay: OverlaySettings,
    /// AI configuration
    pub ai: AiSettings,
    /// Update preferences
    pub updates: UpdateSettings,
    /// Privacy settings
    pub privacy: PrivacySettings,
}

/// UI complexity level
#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default, PartialEq, Eq)]
pub enum UiComplexity {
    #[default]
    Minimal,
    Standard,
    Advanced,
    Builder,
}

/// Feature availability
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Feature {
    pub name: String,
    pub display_name: String,
    pub description: String,
    pub enabled: bool,
    pub category: FeatureCategory,
}

/// Feature category
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum FeatureCategory {
    System,
    AI,
    Overlay,
    Updates,
    Privacy,
    Development,
    Customization,
}

/// Keyboard shortcuts configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShortcutsConfig {
    /// Whether to use default shortcuts
    pub use_defaults: bool,
    /// Custom shortcuts (if not using defaults)
    pub custom: Vec<CustomShortcut>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CustomShortcut {
    pub action: String,
    pub keys: String,
}

/// Overlay settings per mode
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OverlaySettings {
    /// Whether overlay is enabled
    pub enabled: bool,
    /// Default position
    pub position: String,
    /// Theme
    pub theme: String,
    /// Auto-show behavior
    pub auto_show: bool,
    /// Screenshot behavior
    pub screenshot_behavior: ScreenshotBehavior,
}

/// Screenshot behavior
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ScreenshotBehavior {
    Never,
    OnRequest,
    AutoAlways,
}

/// AI settings per mode
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiSettings {
    /// Whether AI is enabled
    pub enabled: bool,
    /// Default model
    pub model: String,
    /// Context size
    pub context_size: u32,
    /// Auto-response behavior
    pub auto_response: bool,
}

/// Update settings per mode
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateSettings {
    /// Update channel (stable, candidate, edge)
    pub channel: UpdateChannel,
    /// Auto-update enabled
    pub auto_update: bool,
    /// Update frequency
    pub frequency: UpdateFrequency,
}

/// Update channel
#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default, PartialEq, Eq)]
pub enum UpdateChannel {
    #[default]
    Stable,
    Candidate,
    Edge,
}

/// Update frequency
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum UpdateFrequency {
    Never,
    Daily,
    Weekly,
    Monthly,
}

/// Privacy settings per mode
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrivacySettings {
    /// Telemetry enabled
    pub telemetry_enabled: bool,
    /// Analytics enabled
    pub analytics_enabled: bool,
    /// Crash reports enabled
    pub crash_reports_enabled: bool,
    /// Usage data collection
    pub usage_data: bool,
}

/// Experience modes manager
pub struct ExperienceManager {
    current_mode: Arc<RwLock<String>>,
    modes: Vec<ExperienceMode>,
    config_dir: PathBuf,
}

impl ExperienceManager {
    /// Create new experience manager
    pub fn new(config_dir: PathBuf) -> Self {
        let modes = Self::define_modes();
        let current_mode = Self::load_current_mode(&config_dir).unwrap_or_else(|e| {
            warn!("Failed to load current mode: {}", e);
            "simple".to_string()
        });

        info!("Experience manager initialized with mode: {}", current_mode);

        Self {
            current_mode: Arc::new(RwLock::new(current_mode)),
            modes,
            config_dir,
        }
    }

    /// Define all experience modes
    fn define_modes() -> Vec<ExperienceMode> {
        vec![
            ExperienceMode {
                name: "simple".to_string(),
                display_name: "Simple".to_string(),
                description: "Modo minimalista ideal para nuevos usuarios. Interfaz simplificada con solo las funciones esenciales.".to_string(),
                settings: ModeSettings {
                    ui_complexity: UiComplexity::Minimal,
                    features: Self::simple_features(),
                    shortcuts: ShortcutsConfig {
                        use_defaults: true,
                        custom: vec![],
                    },
                    overlay: OverlaySettings {
                        enabled: true,
                        position: "center".to_string(),
                        theme: "dark".to_string(),
                        auto_show: true,
                        screenshot_behavior: ScreenshotBehavior::OnRequest,
                    },
                    ai: AiSettings {
                        enabled: true,
                        model: "llama-3.2-3b-instruct-q4_k_m.gguf".to_string(),
                        context_size: 2048,
                        auto_response: true,
                    },
                    updates: UpdateSettings {
                        channel: UpdateChannel::Stable,
                        auto_update: false,
                        frequency: UpdateFrequency::Weekly,
                    },
                    privacy: PrivacySettings {
                        telemetry_enabled: false,
                        analytics_enabled: false,
                        crash_reports_enabled: true,
                        usage_data: false,
                    },
                },
            },
            ExperienceMode {
                name: "pro".to_string(),
                display_name: "Pro".to_string(),
                description: "Modo completo para usuarios avanzados. Acceso a todas las funciones y configuraciones avanzadas.".to_string(),
                settings: ModeSettings {
                    ui_complexity: UiComplexity::Standard,
                    features: Self::pro_features(),
                    shortcuts: ShortcutsConfig {
                        use_defaults: true,
                        custom: vec![],
                    },
                    overlay: OverlaySettings {
                        enabled: true,
                        position: "top-right".to_string(),
                        theme: "auto".to_string(),
                        auto_show: false,
                        screenshot_behavior: ScreenshotBehavior::OnRequest,
                    },
                    ai: AiSettings {
                        enabled: true,
                        model: "Qwen3.5-4B-Q4_K_M.gguf".to_string(),
                        context_size: 4096,
                        auto_response: false,
                    },
                    updates: UpdateSettings {
                        channel: UpdateChannel::Candidate,
                        auto_update: false,
                        frequency: UpdateFrequency::Daily,
                    },
                    privacy: PrivacySettings {
                        telemetry_enabled: false,
                        analytics_enabled: false,
                        crash_reports_enabled: true,
                        usage_data: false,
                    },
                },
            },
            ExperienceMode {
                name: "builder".to_string(),
                display_name: "Builder".to_string(),
                description: "Modo para desarrolladores con herramientas de desarrollo integradas, logs detallados y testing avanzado.".to_string(),
                settings: ModeSettings {
                    ui_complexity: UiComplexity::Advanced,
                    features: Self::builder_features(),
                    shortcuts: ShortcutsConfig {
                        use_defaults: false,
                        custom: vec![
                            CustomShortcut {
                                action: "toggle-dev-tools".to_string(),
                                keys: "Ctrl+Shift+D".to_string(),
                            },
                            CustomShortcut {
                                action: "toggle-logs".to_string(),
                                keys: "Ctrl+Shift+L".to_string(),
                            },
                        ],
                    },
                    overlay: OverlaySettings {
                        enabled: true,
                        position: "bottom-right".to_string(),
                        theme: "dark".to_string(),
                        auto_show: false,
                        screenshot_behavior: ScreenshotBehavior::AutoAlways,
                    },
                    ai: AiSettings {
                        enabled: true,
                        model: "Qwen3.5-4B-Q4_K_M.gguf".to_string(),
                        context_size: 8192,
                        auto_response: false,
                    },
                    updates: UpdateSettings {
                        channel: UpdateChannel::Edge,
                        auto_update: false,
                        frequency: UpdateFrequency::Daily,
                    },
                    privacy: PrivacySettings {
                        telemetry_enabled: true,
                        analytics_enabled: true,
                        crash_reports_enabled: true,
                        usage_data: true,
                    },
                },
            },
        ]
    }

    /// Features for Simple mode
    fn simple_features() -> Vec<Feature> {
        vec![
            Feature {
                name: "ai-overlay".to_string(),
                display_name: "AI Overlay".to_string(),
                description: "Asistente de AI con acceso a Super+Space".to_string(),
                enabled: true,
                category: FeatureCategory::AI,
            },
            Feature {
                name: "basic-chat".to_string(),
                display_name: "Chat Básico".to_string(),
                description: "Chat con AI para preguntas simples".to_string(),
                enabled: true,
                category: FeatureCategory::AI,
            },
            Feature {
                name: "updates-stable".to_string(),
                display_name: "Actualizaciones Estables".to_string(),
                description: "Solo actualizaciones del canal stable".to_string(),
                enabled: true,
                category: FeatureCategory::Updates,
            },
            Feature {
                name: "simple-ui".to_string(),
                display_name: "UI Simplificada".to_string(),
                description: "Interfaz minimalista con opciones esenciales".to_string(),
                enabled: true,
                category: FeatureCategory::System,
            },
        ]
    }

    /// Features for Pro mode
    fn pro_features() -> Vec<Feature> {
        vec![
            Feature {
                name: "ai-overlay".to_string(),
                display_name: "AI Overlay".to_string(),
                description: "Asistente de AI con acceso a Super+Space".to_string(),
                enabled: true,
                category: FeatureCategory::AI,
            },
            Feature {
                name: "advanced-chat".to_string(),
                display_name: "Chat Avanzado".to_string(),
                description: "Chat con historial, context y múltiples modelos".to_string(),
                enabled: true,
                category: FeatureCategory::AI,
            },
            Feature {
                name: "screenshot-context".to_string(),
                display_name: "Captura de Pantalla".to_string(),
                description: "AI puede ver y analizar lo que hay en pantalla".to_string(),
                enabled: true,
                category: FeatureCategory::Overlay,
            },
            Feature {
                name: "updates-candidate".to_string(),
                display_name: "Actualizaciones Candidate".to_string(),
                description: "Acceso a actualizaciones del canal candidate".to_string(),
                enabled: true,
                category: FeatureCategory::Updates,
            },
            Feature {
                name: "advanced-ui".to_string(),
                display_name: "UI Avanzada".to_string(),
                description: "Interfaz completa con todas las configuraciones".to_string(),
                enabled: true,
                category: FeatureCategory::System,
            },
            Feature {
                name: "customization".to_string(),
                display_name: "Personalización".to_string(),
                description: "Personalización de temas, fuentes y atajos".to_string(),
                enabled: true,
                category: FeatureCategory::Customization,
            },
            Feature {
                name: "privacy-controls".to_string(),
                display_name: "Controles de Privacidad".to_string(),
                description: "Configuración detallada de privacidad".to_string(),
                enabled: true,
                category: FeatureCategory::Privacy,
            },
        ]
    }

    /// Features for Builder mode
    fn builder_features() -> Vec<Feature> {
        vec![
            Feature {
                name: "ai-overlay".to_string(),
                display_name: "AI Overlay".to_string(),
                description: "Asistente de AI con acceso a Super+Space".to_string(),
                enabled: true,
                category: FeatureCategory::AI,
            },
            Feature {
                name: "developer-chat".to_string(),
                display_name: "Chat de Desarrollador".to_string(),
                description: "Chat optimizado para tareas de desarrollo y debugging".to_string(),
                enabled: true,
                category: FeatureCategory::AI,
            },
            Feature {
                name: "screenshot-auto".to_string(),
                display_name: "Captura Automática".to_string(),
                description: "Captura automática de pantalla para contexto continuo".to_string(),
                enabled: true,
                category: FeatureCategory::Overlay,
            },
            Feature {
                name: "updates-edge".to_string(),
                display_name: "Actualizaciones Edge".to_string(),
                description: "Acceso a actualizaciones del canal edge".to_string(),
                enabled: true,
                category: FeatureCategory::Updates,
            },
            Feature {
                name: "developer-ui".to_string(),
                display_name: "UI de Desarrollador".to_string(),
                description: "Interfaz con herramientas de desarrollo y logs detallados"
                    .to_string(),
                enabled: true,
                category: FeatureCategory::Development,
            },
            Feature {
                name: "debug-tools".to_string(),
                display_name: "Herramientas de Debug".to_string(),
                description: "Acceso a logs, tracing y debugging tools".to_string(),
                enabled: true,
                category: FeatureCategory::Development,
            },
            Feature {
                name: "full-customization".to_string(),
                display_name: "Personalización Completa".to_string(),
                description: "Acceso total a personalización del sistema".to_string(),
                enabled: true,
                category: FeatureCategory::Customization,
            },
            Feature {
                name: "telemetry-dev".to_string(),
                display_name: "Telemetría para Desarrolladores".to_string(),
                description: "Telemetría y analytics detalladas para desarrollo".to_string(),
                enabled: true,
                category: FeatureCategory::Privacy,
            },
        ]
    }

    /// Load current mode from config
    fn load_current_mode(config_dir: &Path) -> Result<String> {
        let mode_file = config_dir.join("current_mode.txt");

        if !mode_file.exists() {
            return Ok("simple".to_string());
        }

        let mode = fs::read_to_string(&mode_file)
            .with_context(|| format!("Failed to read {}", mode_file.display()))?
            .trim()
            .to_lowercase();

        // Validate mode
        if matches!(mode.as_str(), "simple" | "pro" | "builder") {
            Ok(mode)
        } else {
            warn!("Invalid mode '{}', defaulting to simple", mode);
            Ok("simple".to_string())
        }
    }

    /// Get current mode
    pub async fn get_current_mode(&self) -> String {
        self.current_mode.read().await.clone()
    }

    /// Set current mode
    pub async fn set_mode(&self, mode: &str) -> Result<()> {
        if !matches!(mode, "simple" | "pro" | "builder") {
            anyhow::bail!("Invalid mode: {}. Must be simple, pro, or builder", mode);
        }

        let mode = mode.to_lowercase();

        // Save to file
        let mode_file = self.config_dir.join("current_mode.txt");
        fs::write(&mode_file, &mode)
            .with_context(|| format!("Failed to write {}", mode_file.display()))?;

        // Update in-memory state
        let mut current = self.current_mode.write().await;
        *current = mode.clone();

        info!("Experience mode changed to: {}", mode);

        Ok(())
    }

    /// Get mode details
    pub fn get_mode(&self, mode: &str) -> Option<&ExperienceMode> {
        self.modes.iter().find(|m| m.name == mode)
    }

    /// Get current mode details
    pub async fn get_current_mode_details(&self) -> Option<ExperienceMode> {
        let current = self.current_mode.read().await;
        self.get_mode(&current).cloned()
    }

    /// List all available modes
    pub fn list_modes(&self) -> &Vec<ExperienceMode> {
        &self.modes
    }

    /// Check if feature is enabled in current mode
    pub async fn is_feature_enabled(&self, feature_name: &str) -> bool {
        let current = self.current_mode.read().await;

        if let Some(mode) = self.get_mode(&current) {
            mode.settings
                .features
                .iter()
                .any(|f| f.name == feature_name && f.enabled)
        } else {
            false
        }
    }

    /// Get features for current mode
    pub async fn get_current_features(&self) -> Vec<Feature> {
        let current = self.current_mode.read().await;

        if let Some(mode) = self.get_mode(&current) {
            mode.settings.features.clone()
        } else {
            vec![]
        }
    }

    /// Apply mode settings to system
    pub async fn apply_mode(&self, mode: &str) -> Result<ModeApplicationResult> {
        let mode_details = self
            .get_mode(mode)
            .ok_or_else(|| anyhow::anyhow!("Mode '{}' not found", mode))?;

        info!("Applying mode: {}", mode_details.display_name);

        let mut result = ModeApplicationResult {
            mode: mode_details.name.clone(),
            applied_at: chrono::Utc::now().to_rfc3339(),
            changes: vec![],
            warnings: vec![],
        };

        // Save mode
        self.set_mode(mode).await?;
        result.changes.push("Current mode updated".to_string());

        // Apply overlay settings
        if let Err(e) = self
            .apply_overlay_settings(&mode_details.settings.overlay)
            .await
        {
            result
                .warnings
                .push(format!("Failed to apply overlay settings: {}", e));
        } else {
            result.changes.push("Overlay settings applied".to_string());
        }

        // Apply AI settings
        if let Err(e) = self.apply_ai_settings(&mode_details.settings.ai).await {
            result
                .warnings
                .push(format!("Failed to apply AI settings: {}", e));
        } else {
            result.changes.push("AI settings applied".to_string());
        }

        // Apply update settings
        if let Err(e) = self
            .apply_update_settings(&mode_details.settings.updates)
            .await
        {
            result
                .warnings
                .push(format!("Failed to apply update settings: {}", e));
        } else {
            result.changes.push("Update settings applied".to_string());
        }

        info!("Mode '{}' applied successfully", mode);

        Ok(result)
    }

    /// Apply overlay settings
    async fn apply_overlay_settings(&self, settings: &OverlaySettings) -> Result<()> {
        let config_file = self.config_dir.join("overlay.conf");
        let config_content = format!(
            r#"[overlay]
enabled = {}
position = {}
theme = {}
auto_show = {}
screenshot_behavior = {}
"#,
            settings.enabled,
            settings.position,
            settings.theme,
            settings.auto_show,
            match settings.screenshot_behavior {
                ScreenshotBehavior::Never => "never",
                ScreenshotBehavior::OnRequest => "on_request",
                ScreenshotBehavior::AutoAlways => "auto",
            }
        );

        tokio::fs::write(&config_file, config_content)
            .await
            .with_context(|| {
                format!("Failed to write overlay config: {}", config_file.display())
            })?;

        Ok(())
    }

    /// Apply AI settings
    async fn apply_ai_settings(&self, settings: &AiSettings) -> Result<()> {
        let config_file = self.config_dir.join("ai.conf");
        let config_content = format!(
            r#"[ai]
enabled = {}
model = {}
context_size = {}
auto_response = {}
"#,
            settings.enabled, settings.model, settings.context_size, settings.auto_response
        );

        tokio::fs::write(&config_file, config_content)
            .await
            .with_context(|| format!("Failed to write AI config: {}", config_file.display()))?;

        // Update llama-server.env if enabled
        if settings.enabled {
            // This would normally update /etc/lifeos/llama-server.env
            // For now, just log it
            info!("AI model set to: {}", settings.model);
        }

        Ok(())
    }

    /// Apply update settings
    async fn apply_update_settings(&self, settings: &UpdateSettings) -> Result<()> {
        let config_file = self.config_dir.join("updates.conf");
        let channel_str = match settings.channel {
            UpdateChannel::Stable => "stable",
            UpdateChannel::Candidate => "candidate",
            UpdateChannel::Edge => "edge",
        };

        let frequency_str = match settings.frequency {
            UpdateFrequency::Never => "never",
            UpdateFrequency::Daily => "daily",
            UpdateFrequency::Weekly => "weekly",
            UpdateFrequency::Monthly => "monthly",
        };

        let config_content = format!(
            r#"[updates]
channel = {}
auto_update = {}
frequency = {}
"#,
            channel_str, settings.auto_update, frequency_str
        );

        tokio::fs::write(&config_file, config_content)
            .await
            .with_context(|| {
                format!("Failed to write updates config: {}", config_file.display())
            })?;

        Ok(())
    }

    /// Get mode comparison
    pub fn compare_modes(&self, mode1: &str, mode2: &str) -> ModeComparison {
        let m1 = self.get_mode(mode1);
        let m2 = self.get_mode(mode2);

        match (m1, m2) {
            (Some(a), Some(b)) => ModeComparison {
                mode1: a.name.clone(),
                mode1_display: a.display_name.clone(),
                mode2: b.name.clone(),
                mode2_display: b.display_name.clone(),
                differences: Self::get_differences(a, b),
            },
            _ => ModeComparison {
                mode1: mode1.to_string(),
                mode1_display: mode1.to_string(),
                mode2: mode2.to_string(),
                mode2_display: mode2.to_string(),
                differences: vec![],
            },
        }
    }

    /// Get differences between two modes
    fn get_differences(a: &ExperienceMode, b: &ExperienceMode) -> Vec<String> {
        let mut differences = vec![];

        // UI complexity
        if a.settings.ui_complexity != b.settings.ui_complexity {
            differences.push(format!(
                "UI Complexity: {:?} vs {:?}",
                a.settings.ui_complexity, b.settings.ui_complexity
            ));
        }

        // Features
        let a_features: Vec<_> = a.settings.features.iter().filter(|f| f.enabled).collect();
        let b_features: Vec<_> = b.settings.features.iter().filter(|f| f.enabled).collect();

        if a_features.len() != b_features.len() {
            differences.push(format!(
                "Features: {} vs {} enabled",
                a_features.len(),
                b_features.len()
            ));
        }

        // AI settings
        if a.settings.ai.context_size != b.settings.ai.context_size {
            differences.push(format!(
                "AI Context: {} vs {} tokens",
                a.settings.ai.context_size, b.settings.ai.context_size
            ));
        }

        // Update channel
        let a_channel = match a.settings.updates.channel {
            UpdateChannel::Stable => "stable",
            UpdateChannel::Candidate => "candidate",
            UpdateChannel::Edge => "edge",
        };
        let b_channel = match b.settings.updates.channel {
            UpdateChannel::Stable => "stable",
            UpdateChannel::Candidate => "candidate",
            UpdateChannel::Edge => "edge",
        };

        if a_channel != b_channel {
            differences.push(format!("Update Channel: {} vs {}", a_channel, b_channel));
        }

        differences
    }
}

/// Mode application result
#[derive(Debug, Clone, Serialize)]
pub struct ModeApplicationResult {
    pub mode: String,
    pub applied_at: String,
    pub changes: Vec<String>,
    pub warnings: Vec<String>,
}

/// Mode comparison result
#[derive(Debug, Clone, Serialize)]
pub struct ModeComparison {
    pub mode1: String,
    pub mode1_display: String,
    pub mode2: String,
    pub mode2_display: String,
    pub differences: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_modes_definition() {
        let manager = ExperienceManager::new(PathBuf::from("/tmp/test"));
        assert_eq!(manager.list_modes().len(), 3);
    }

    #[test]
    fn test_feature_names() {
        let simple = ExperienceManager::simple_features();
        assert!(!simple.is_empty());
        assert_eq!(simple[0].name, "ai-overlay");
    }
}
