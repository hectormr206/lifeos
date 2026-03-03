use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::process::Command;
use std::sync::Arc;
use tokio::sync::Mutex;
use zbus::{interface, Connection};

const POLICY_FILE: &str = "/var/lib/lifeos/permissions-policy.json";

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct PermissionStore {
    granted: HashMap<String, Vec<String>>,
}

impl PermissionStore {
    fn load() -> Self {
        let path = Path::new(POLICY_FILE);
        if !path.exists() {
            return Self::default();
        }

        match std::fs::read_to_string(path) {
            Ok(content) => serde_json::from_str(&content).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    fn persist(&self) -> anyhow::Result<()> {
        let parent = Path::new(POLICY_FILE)
            .parent()
            .ok_or_else(|| anyhow::anyhow!("Invalid permissions policy path"))?;
        std::fs::create_dir_all(parent)?;
        std::fs::write(POLICY_FILE, serde_json::to_string_pretty(self)?)?;
        Ok(())
    }
}

/// D-Bus interface for LifeOS permissions broker (`org.lifeos.Permissions`)
pub struct PermissionBroker {
    granted: Arc<Mutex<HashMap<String, Vec<String>>>>,
}

impl Default for PermissionBroker {
    fn default() -> Self {
        let store = PermissionStore::load();
        Self {
            granted: Arc::new(Mutex::new(store.granted)),
        }
    }
}

#[interface(name = "org.lifeos.Permissions")]
impl PermissionBroker {
    /// Requests access to a resource. Returns true on grant, false on deny.
    async fn request_access(&self, app_id: String, resource: String) -> bool {
        log::info!(
            "Permission requested by {} for resource {}",
            app_id,
            resource
        );

        // Built-in apps are trusted by policy.
        if app_id.starts_with("org.lifeos.core") {
            log::info!("Access granted automatically to core app {}", app_id);
            return true;
        }

        let mut granted = self.granted.lock().await;
        let app_perms = granted.entry(app_id.clone()).or_insert_with(Vec::new);

        if app_perms.contains(&resource) {
            log::debug!("Access already granted to {} for {}", app_id, resource);
            return true;
        }

        let app = app_id.clone();
        let res = resource.clone();
        let approved = tokio::task::spawn_blocking(move || prompt_user_approval(&app, &res))
            .await
            .unwrap_or(false);

        if approved {
            app_perms.push(resource.clone());
            app_perms.sort();
            app_perms.dedup();

            let store = PermissionStore {
                granted: granted.clone(),
            };
            if let Err(err) = store.persist() {
                log::warn!("Failed to persist permissions policy: {}", err);
            }

            log::info!("Access granted to {} for {}", app_id, resource);
            true
        } else {
            log::warn!("Access denied to {} for {}", app_id, resource);
            false
        }
    }

    /// Checks previously granted permissions without prompting.
    async fn check_access(&self, app_id: String, resource: String) -> bool {
        let granted = self.granted.lock().await;
        granted
            .get(&app_id)
            .map(|perms| perms.contains(&resource))
            .unwrap_or(false)
    }
}

fn prompt_user_approval(app_id: &str, resource: &str) -> bool {
    let prompt = format!(
        "LifeOS permission request\n\nApplication: {}\nResource: {}\n\nAllow access?",
        app_id, resource
    );

    // Prefer graphical prompt when available.
    if Command::new("sh")
        .args(["-c", "command -v zenity >/dev/null 2>&1"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
    {
        let status = Command::new("zenity")
            .args([
                "--question",
                "--title=LifeOS Permissions",
                "--text",
                &prompt,
                "--timeout=30",
            ])
            .status();

        if let Ok(status) = status {
            return status.success();
        }
    }

    // Fallback to systemd ask-password prompt (TTY/console compatible).
    if Command::new("sh")
        .args(["-c", "command -v systemd-ask-password >/dev/null 2>&1"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
    {
        let output = Command::new("systemd-ask-password")
            .args([
                "--timeout=30",
                &format!(
                    "Allow {} to access {}? type 'yes' to approve",
                    app_id, resource
                ),
            ])
            .output();

        if let Ok(output) = output {
            if output.status.success() {
                let answer = String::from_utf8_lossy(&output.stdout)
                    .trim()
                    .to_lowercase();
                return answer == "yes" || answer == "y";
            }
        }
    }

    // Last fallback: deny if we cannot prompt safely.
    false
}

/// Starts the permission broker on the user session D-Bus.
pub async fn start_broker() -> anyhow::Result<Connection> {
    log::info!("Starting LifeOS Permission Broker on D-Bus: org.lifeos.Permissions");
    let broker = PermissionBroker::default();

    let connection = zbus::connection::Builder::session()?
        .name("org.lifeos.Permissions")?
        .serve_at("/org/lifeos/Permissions", broker)?
        .build()
        .await?;

    Ok(connection)
}
