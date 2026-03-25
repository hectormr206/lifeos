//! App Contract System (Fase Z foundation)
//!
//! Defines a contract-based system for AI-native apps. Each app declares
//! what intents it can handle, what data it needs, and its autonomy level.
//! The registry loads contracts from JSON files and provides intent routing.

use anyhow::Result;
use log::{debug, info, warn};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

/// Autonomy level that determines how much user interaction is required.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum AutonomyLevel {
    /// Always ask user for confirmation before executing.
    Manual,
    /// Show the user what will happen and ask for approval.
    AskFirst,
    /// Execute without user intervention.
    Autonomous,
}

/// A single action that an app can perform.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppAction {
    /// Action identifier (e.g., "send_email").
    pub name: String,
    /// Human-readable description.
    pub description: String,
    /// Shell command or D-Bus call to execute.
    pub command: String,
    /// Risk level: "low", "medium", "high".
    pub risk_level: String,
}

/// Contract describing an AI-native app's capabilities and requirements.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppContract {
    /// Application name.
    pub name: String,
    /// Semantic version.
    pub version: String,
    /// Human-readable description.
    pub description: String,
    /// Intents this app can handle (e.g., ["email.send", "email.read"]).
    pub intents_handled: Vec<String>,
    /// Data domains required (e.g., ["contacts", "calendar"]).
    pub data_required: Vec<String>,
    /// Available actions.
    pub actions: Vec<AppAction>,
    /// User-configurable autonomy level.
    pub autonomy_level: AutonomyLevel,
}

/// Result of a permission check against an app's autonomy level.
#[derive(Debug, Clone, PartialEq)]
pub enum PermissionResult {
    /// Action is allowed without user interaction.
    Allowed,
    /// Action requires user approval (includes description).
    NeedsApproval(String),
    /// Action is denied (includes reason).
    Denied(String),
}

/// Registry that manages all known app contracts.
#[derive(Debug)]
pub struct AppContractRegistry {
    contracts: Vec<AppContract>,
    config_dir: PathBuf,
}

impl AppContractRegistry {
    /// Create a new registry and load contracts from the given directory.
    ///
    /// Loads all `*.json` files from `config_dir`. Defaults to
    /// `/etc/lifeos/contracts/` if the path does not exist yet.
    pub fn new(config_dir: impl AsRef<Path>) -> Self {
        let config_dir = config_dir.as_ref().to_path_buf();
        let mut registry = Self {
            contracts: Vec::new(),
            config_dir: config_dir.clone(),
        };

        if config_dir.exists() {
            if let Err(e) = registry.load_all() {
                warn!("app_contracts: failed to load contracts: {}", e);
            }
        } else {
            debug!(
                "app_contracts: config dir {:?} does not exist yet, starting empty",
                config_dir
            );
        }

        registry
    }

    /// Load all JSON contract files from the config directory.
    fn load_all(&mut self) -> Result<()> {
        let entries = fs::read_dir(&self.config_dir)?;

        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("json") {
                match self.load_contract(&path) {
                    Ok(contract) => {
                        info!("app_contracts: loaded contract '{}'", contract.name);
                        self.contracts.push(contract);
                    }
                    Err(e) => {
                        warn!("app_contracts: failed to load {:?}: {}", path, e);
                    }
                }
            }
        }

        Ok(())
    }

    /// Load a single contract from a JSON file.
    fn load_contract(&self, path: &Path) -> Result<AppContract> {
        let contents = fs::read_to_string(path)?;
        let contract: AppContract = serde_json::from_str(&contents)?;
        Ok(contract)
    }

    /// Register a new app contract.
    pub fn register(&mut self, contract: AppContract) {
        info!(
            "app_contracts: registering '{}' v{} ({} intents, {} actions)",
            contract.name,
            contract.version,
            contract.intents_handled.len(),
            contract.actions.len()
        );
        self.contracts.push(contract);
    }

    /// Find all apps that handle a given intent string.
    ///
    /// Matches both exact matches (e.g., "email.send") and prefix matches
    /// (e.g., intent "email" matches contract handling "email.send").
    pub fn find_handler(&self, intent: &str) -> Vec<&AppContract> {
        let intent_lower = intent.to_lowercase();
        self.contracts
            .iter()
            .filter(|c| {
                c.intents_handled.iter().any(|i| {
                    let i_lower = i.to_lowercase();
                    i_lower == intent_lower || i_lower.starts_with(&format!("{}.", intent_lower))
                })
            })
            .collect()
    }

    /// List all registered contracts.
    pub fn list_all(&self) -> Vec<&AppContract> {
        self.contracts.iter().collect()
    }

    /// Update the autonomy level for a registered app and persist to disk.
    pub fn set_autonomy(&mut self, app_name: &str, level: AutonomyLevel) -> Result<()> {
        let contract = self
            .contracts
            .iter_mut()
            .find(|c| c.name == app_name)
            .ok_or_else(|| anyhow::anyhow!("app '{}' not found in registry", app_name))?;
        info!(
            "app_contracts: setting autonomy for '{}' to {:?}",
            app_name, level
        );
        contract.autonomy_level = level;
        self.save()
    }

    /// Check whether an app is allowed to perform a given action based on its autonomy level.
    pub fn check_permission(&self, app_name: &str, action: &str) -> PermissionResult {
        let contract = match self.contracts.iter().find(|c| c.name == app_name) {
            Some(c) => c,
            None => {
                return PermissionResult::Denied(format!("app '{}' not registered", app_name))
            }
        };

        match contract.autonomy_level {
            AutonomyLevel::Autonomous => PermissionResult::Allowed,
            AutonomyLevel::AskFirst => PermissionResult::NeedsApproval(format!(
                "app '{}' wants to perform '{}' — approval required",
                app_name, action
            )),
            AutonomyLevel::Manual => PermissionResult::Denied(format!(
                "app '{}' is in manual mode — action '{}' blocked",
                app_name, action
            )),
        }
    }

    /// Persist the current registry to a JSON file in the config directory.
    pub fn save(&self) -> Result<()> {
        fs::create_dir_all(&self.config_dir)?;
        let path = self.config_dir.join("_registry.json");
        let json = serde_json::to_string_pretty(&self.contracts)?;
        fs::write(&path, json)?;
        debug!("app_contracts: saved registry to {:?}", path);
        Ok(())
    }

    /// Reload the registry from the persisted JSON file on disk.
    pub fn load(&mut self) -> Result<()> {
        let path = self.config_dir.join("_registry.json");
        if path.exists() {
            let contents = fs::read_to_string(&path)?;
            self.contracts = serde_json::from_str(&contents)?;
            info!(
                "app_contracts: loaded {} contracts from {:?}",
                self.contracts.len(),
                path
            );
        } else {
            debug!("app_contracts: no registry file at {:?}, keeping current state", path);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn sample_contract() -> AppContract {
        AppContract {
            name: "test-email".into(),
            version: "1.0.0".into(),
            description: "Test email client".into(),
            intents_handled: vec!["email.send".into(), "email.read".into()],
            data_required: vec!["contacts".into()],
            actions: vec![AppAction {
                name: "send_email".into(),
                description: "Send an email".into(),
                command: "test-email --send".into(),
                risk_level: "low".into(),
            }],
            autonomy_level: AutonomyLevel::AskFirst,
        }
    }

    #[test]
    fn test_register_and_list() {
        let mut registry = AppContractRegistry::new("/tmp/lifeos-test-contracts-nonexistent");
        assert_eq!(registry.list_all().len(), 0);

        registry.register(sample_contract());
        assert_eq!(registry.list_all().len(), 1);
        assert_eq!(registry.list_all()[0].name, "test-email");
    }

    #[test]
    fn test_find_handler_exact() {
        let mut registry = AppContractRegistry::new("/tmp/lifeos-test-contracts-nonexistent");
        registry.register(sample_contract());

        let handlers = registry.find_handler("email.send");
        assert_eq!(handlers.len(), 1);
        assert_eq!(handlers[0].name, "test-email");
    }

    #[test]
    fn test_find_handler_prefix() {
        let mut registry = AppContractRegistry::new("/tmp/lifeos-test-contracts-nonexistent");
        registry.register(sample_contract());

        // "email" should match "email.send" and "email.read"
        let handlers = registry.find_handler("email");
        assert_eq!(handlers.len(), 1);
    }

    #[test]
    fn test_find_handler_no_match() {
        let mut registry = AppContractRegistry::new("/tmp/lifeos-test-contracts-nonexistent");
        registry.register(sample_contract());

        let handlers = registry.find_handler("calendar.create");
        assert!(handlers.is_empty());
    }

    #[test]
    fn test_load_from_directory() {
        let dir = std::env::temp_dir().join("lifeos-test-contracts");
        let _ = fs::create_dir_all(&dir);

        let contract = sample_contract();
        let json = serde_json::to_string_pretty(&contract).unwrap();
        let file_path = dir.join("test-email.json");
        let mut f = fs::File::create(&file_path).unwrap();
        f.write_all(json.as_bytes()).unwrap();

        let registry = AppContractRegistry::new(&dir);
        assert_eq!(registry.list_all().len(), 1);
        assert_eq!(registry.list_all()[0].name, "test-email");

        // Cleanup
        let _ = fs::remove_file(&file_path);
        let _ = fs::remove_dir(&dir);
    }

    #[test]
    fn test_autonomy_level_serde() {
        let json = r#""ask_first""#;
        let level: AutonomyLevel = serde_json::from_str(json).unwrap();
        assert_eq!(level, AutonomyLevel::AskFirst);

        let serialized = serde_json::to_string(&AutonomyLevel::Autonomous).unwrap();
        assert_eq!(serialized, r#""autonomous""#);
    }
}
