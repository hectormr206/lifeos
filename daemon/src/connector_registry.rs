//! Connector Registry (Fase Z)
//!
//! Manages external service connectors (REST APIs, GraphQL, WebSocket, CLI, D-Bus).
//! Each connector represents an integration point that the AI can use to interact
//! with external services. Connectors are persisted to `connectors.json`.

use anyhow::Result;
use log::{debug, info, warn};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

/// Type of external connector.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectorType {
    RestApi,
    GraphQL,
    WebSocket,
    Cli,
    DBus,
}

/// A connector to an external service.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Connector {
    /// Unique connector name (e.g., "github", "slack").
    pub name: String,
    /// Human-readable description.
    pub description: String,
    /// Type of integration.
    pub connector_type: ConnectorType,
    /// Connector-specific configuration (auth tokens, endpoints, etc.).
    pub config: serde_json::Value,
    /// Whether this connector is currently enabled.
    pub enabled: bool,
}

/// Registry that manages all known connectors.
#[derive(Debug)]
pub struct ConnectorRegistry {
    connectors: Vec<Connector>,
    config_path: PathBuf,
}

impl ConnectorRegistry {
    /// Create a new registry, loading from `config_dir/connectors.json` if it exists.
    /// Pre-registers default connectors (disabled) if starting fresh.
    pub fn new(config_dir: PathBuf) -> Self {
        let config_path = config_dir.join("connectors.json");
        let mut registry = Self {
            connectors: Vec::new(),
            config_path: config_path.clone(),
        };

        if config_path.exists() {
            match registry.load_from_disk() {
                Ok(()) => {
                    info!(
                        "connector_registry: loaded {} connectors from {:?}",
                        registry.connectors.len(),
                        config_path
                    );
                }
                Err(e) => {
                    warn!(
                        "connector_registry: failed to load {:?}: {}",
                        config_path, e
                    );
                    registry.register_defaults();
                }
            }
        } else {
            debug!(
                "connector_registry: no file at {:?}, registering defaults",
                config_path
            );
            registry.register_defaults();
        }

        registry
    }

    /// Register a connector and persist to disk.
    pub fn register(&mut self, connector: Connector) {
        info!(
            "connector_registry: registering '{}' ({:?}, enabled={})",
            connector.name, connector.connector_type, connector.enabled
        );
        // Replace if already exists
        self.connectors.retain(|c| c.name != connector.name);
        self.connectors.push(connector);
        if let Err(e) = self.save() {
            warn!(
                "connector_registry: failed to persist after register: {}",
                e
            );
        }
    }

    /// Find a connector by name.
    pub fn find_by_name(&self, name: &str) -> Option<&Connector> {
        self.connectors.iter().find(|c| c.name == name)
    }

    /// Find all connectors of a given type.
    pub fn find_by_type(&self, ct: ConnectorType) -> Vec<&Connector> {
        self.connectors
            .iter()
            .filter(|c| c.connector_type == ct)
            .collect()
    }

    /// List all enabled connectors.
    pub fn list_enabled(&self) -> Vec<&Connector> {
        self.connectors.iter().filter(|c| c.enabled).collect()
    }

    /// Enable or disable a connector by name.
    pub fn set_enabled(&mut self, name: &str, enabled: bool) -> Result<()> {
        let connector = self
            .connectors
            .iter_mut()
            .find(|c| c.name == name)
            .ok_or_else(|| anyhow::anyhow!("connector '{}' not found", name))?;
        info!("connector_registry: setting '{}' enabled={}", name, enabled);
        connector.enabled = enabled;
        self.save()
    }

    /// Pre-register default connectors (all disabled).
    fn register_defaults(&mut self) {
        let defaults = vec![
            Connector {
                name: "github".into(),
                description: "GitHub REST API integration".into(),
                connector_type: ConnectorType::RestApi,
                config: serde_json::json!({"base_url": "https://api.github.com"}),
                enabled: false,
            },
            Connector {
                name: "slack".into(),
                description: "Slack REST API integration".into(),
                connector_type: ConnectorType::RestApi,
                config: serde_json::json!({"base_url": "https://slack.com/api"}),
                enabled: false,
            },
            Connector {
                name: "google-calendar".into(),
                description: "Google Calendar REST API integration".into(),
                connector_type: ConnectorType::RestApi,
                config: serde_json::json!({"base_url": "https://www.googleapis.com/calendar/v3"}),
                enabled: false,
            },
            Connector {
                name: "brave-search".into(),
                description: "Brave Search REST API integration".into(),
                connector_type: ConnectorType::RestApi,
                config: serde_json::json!({"base_url": "https://api.search.brave.com/res/v1"}),
                enabled: false,
            },
        ];

        self.connectors = defaults;
        debug!(
            "connector_registry: registered {} default connectors",
            self.connectors.len()
        );
    }

    fn save(&self) -> Result<()> {
        if let Some(parent) = self.config_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(&self.connectors)?;
        fs::write(&self.config_path, json)?;
        debug!("connector_registry: saved to {:?}", self.config_path);
        Ok(())
    }

    fn load_from_disk(&mut self) -> Result<()> {
        let contents = fs::read_to_string(&self.config_path)?;
        self.connectors = serde_json::from_str(&contents)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_creates_defaults() {
        let dir = std::env::temp_dir().join("lifeos-test-connectors-new");
        let _ = fs::remove_dir_all(&dir);

        let registry = ConnectorRegistry::new(dir.clone());
        assert_eq!(registry.connectors.len(), 4);
        assert!(registry.list_enabled().is_empty());
        assert!(registry.find_by_name("github").is_some());
        assert!(registry.find_by_name("slack").is_some());

        // Cleanup
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_register_and_find() {
        let dir = std::env::temp_dir().join("lifeos-test-connectors-reg");
        let _ = fs::remove_dir_all(&dir);

        let mut registry = ConnectorRegistry::new(dir.clone());
        registry.register(Connector {
            name: "custom-api".into(),
            description: "Custom test API".into(),
            connector_type: ConnectorType::GraphQL,
            config: serde_json::json!({}),
            enabled: true,
        });

        assert!(registry.find_by_name("custom-api").is_some());
        assert_eq!(registry.find_by_type(ConnectorType::GraphQL).len(), 1);
        assert_eq!(registry.list_enabled().len(), 1);

        // Cleanup
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_set_enabled() {
        let dir = std::env::temp_dir().join("lifeos-test-connectors-enable");
        let _ = fs::remove_dir_all(&dir);

        let mut registry = ConnectorRegistry::new(dir.clone());
        assert!(registry.list_enabled().is_empty());

        registry.set_enabled("github", true).unwrap();
        assert_eq!(registry.list_enabled().len(), 1);
        assert_eq!(registry.list_enabled()[0].name, "github");

        registry.set_enabled("github", false).unwrap();
        assert!(registry.list_enabled().is_empty());

        // Cleanup
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_persistence() {
        let dir = std::env::temp_dir().join("lifeos-test-connectors-persist");
        let _ = fs::remove_dir_all(&dir);

        {
            let mut registry = ConnectorRegistry::new(dir.clone());
            registry.set_enabled("slack", true).unwrap();
        }

        // Reload from disk
        let registry = ConnectorRegistry::new(dir.clone());
        assert_eq!(registry.list_enabled().len(), 1);
        assert_eq!(registry.list_enabled()[0].name, "slack");

        // Cleanup
        let _ = fs::remove_dir_all(&dir);
    }
}
