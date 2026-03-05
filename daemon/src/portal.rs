use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use tokio::sync::Mutex;
use zbus::{interface, Connection};

const PORTAL_POLICY_FILE: &str = "/var/lib/lifeos/portal-permissions.json";
const AUDIT_LOG_FILE: &str = "/var/log/lifeos/portal-audit.log";

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AuditEntry {
    timestamp: String,
    app_id: String,
    permission: String,
    action: String,
    reason: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct PortalPermissionStore {
    granted: HashMap<String, Vec<PortalPermission>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PortalPermission {
    pub resource: String,
    pub granted_at: String,
    pub reason: Option<String>,
}

pub struct LifeOsPortal {
    permissions: Arc<Mutex<HashMap<String, Vec<PortalPermission>>>>,
}

impl Default for LifeOsPortal {
    fn default() -> Self {
        let store = Self::load_store();
        Self {
            permissions: Arc::new(Mutex::new(store.granted)),
        }
    }
}

impl LifeOsPortal {
    fn load_store() -> PortalPermissionStore {
        let path = Path::new(PORTAL_POLICY_FILE);
        if !path.exists() {
            return PortalPermissionStore::default();
        }

        match std::fs::read_to_string(path) {
            Ok(content) => serde_json::from_str(&content).unwrap_or_default(),
            Err(_) => PortalPermissionStore::default(),
        }
    }

    fn persist_store(store: &PortalPermissionStore) -> anyhow::Result<()> {
        let parent = Path::new(PORTAL_POLICY_FILE)
            .parent()
            .ok_or_else(|| anyhow::anyhow!("Invalid portal permissions path"))?;
        std::fs::create_dir_all(parent)?;
        std::fs::write(PORTAL_POLICY_FILE, serde_json::to_string_pretty(store)?)?;
        Ok(())
    }

    fn log_audit(entry: &AuditEntry) {
        let log_line = match serde_json::to_string(entry) {
            Ok(json) => json,
            Err(_) => return,
        };

        let log_dir = Path::new(AUDIT_LOG_FILE)
            .parent()
            .unwrap_or(Path::new("/var/log/lifeos"));
        if std::fs::create_dir_all(log_dir).is_err() {
            return;
        }

        use std::io::Write;
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(AUDIT_LOG_FILE)
        {
            let _ = writeln!(file, "{}", log_line);
        }
    }

    pub fn new() -> Self {
        Self::default()
    }
}

#[interface(name = "org.lifeos.Portal")]
impl LifeOsPortal {
    async fn request_camera(&self, app_id: &str, reason: &str) -> zbus::fdo::Result<bool> {
        self.request_permission_internal(app_id, "camera", reason)
            .await
    }

    async fn request_microphone(&self, app_id: &str, reason: &str) -> zbus::fdo::Result<bool> {
        self.request_permission_internal(app_id, "microphone", reason)
            .await
    }

    async fn request_screencast(&self, app_id: &str, reason: &str) -> zbus::fdo::Result<bool> {
        self.request_permission_internal(app_id, "screencast", reason)
            .await
    }

    async fn request_file_access(
        &self,
        app_id: &str,
        path: &str,
        reason: &str,
    ) -> zbus::fdo::Result<bool> {
        self.request_permission_internal(app_id, &format!("file:{}", path), reason)
            .await
    }

    async fn request_permission(
        &self,
        app_id: &str,
        permission: &str,
        reason: &str,
    ) -> zbus::fdo::Result<bool> {
        self.request_permission_internal(app_id, permission, reason)
            .await
    }

    async fn list_permissions(&self, app_id: &str) -> zbus::fdo::Result<Vec<String>> {
        let perms = self.permissions.lock().await;
        Ok(perms
            .get(app_id)
            .map(|p| p.iter().map(|perm| perm.resource.clone()).collect())
            .unwrap_or_default())
    }

    async fn revoke_permission(&self, app_id: &str, permission: &str) -> zbus::fdo::Result<()> {
        let mut perms = self.permissions.lock().await;

        let (changed, is_empty) = {
            let Some(app_perms) = perms.get_mut(app_id) else {
                return Ok(());
            };

            let before = app_perms.len();
            app_perms.retain(|p| p.resource != permission);
            let changed = app_perms.len() != before;
            let is_empty = app_perms.is_empty();
            (changed, is_empty)
        };

        if !changed {
            return Ok(());
        }
        let audit_entry = AuditEntry {
            timestamp: chrono::Local::now().to_rfc3339(),
            app_id: app_id.to_string(),
            permission: permission.to_string(),
            action: "revoked".to_string(),
            reason: None,
        };

        if is_empty {
            perms.remove(app_id);
        }

        let store = PortalPermissionStore {
            granted: perms.clone(),
        };
        if let Err(err) = Self::persist_store(&store) {
            log::warn!("Failed to persist portal permissions: {}", err);
        }

        Self::log_audit(&audit_entry);
        log::info!("Portal permission revoked: {} -> {}", app_id, permission);

        Ok(())
    }

    async fn check_permission(&self, app_id: &str, permission: &str) -> zbus::fdo::Result<bool> {
        let perms = self.permissions.lock().await;
        Ok(perms
            .get(app_id)
            .map(|p| p.iter().any(|perm| perm.resource == permission))
            .unwrap_or(false))
    }
}

impl LifeOsPortal {
    async fn request_permission_internal(
        &self,
        app_id: &str,
        permission: &str,
        reason: &str,
    ) -> zbus::fdo::Result<bool> {
        log::info!(
            "Portal permission requested: app={}, permission={}, reason={}",
            app_id,
            permission,
            reason
        );

        if app_id.starts_with("org.lifeos.core") {
            log::info!("Auto-granting to core app: {}", app_id);
            return Ok(true);
        }

        let mut perms = self.permissions.lock().await;

        if let Some(app_perms) = perms.get(app_id) {
            if app_perms.iter().any(|p| p.resource == permission) {
                log::debug!("Permission already granted: {} -> {}", app_id, permission);
                return Ok(true);
            }
        }

        let app = app_id.to_string();
        let perm = permission.to_string();
        let rsn = reason.to_string();

        let approved =
            tokio::task::spawn_blocking(move || prompt_portal_approval(&app, &perm, &rsn))
                .await
                .map_err(|e| zbus::fdo::Error::Failed(format!("Spawn error: {}", e)))?
                .map_err(|e| zbus::fdo::Error::Failed(format!("Prompt error: {}", e)))?;

        let audit_entry = AuditEntry {
            timestamp: chrono::Local::now().to_rfc3339(),
            app_id: app_id.to_string(),
            permission: permission.to_string(),
            action: if approved { "granted" } else { "denied" }.to_string(),
            reason: if reason.is_empty() {
                None
            } else {
                Some(reason.to_string())
            },
        };
        Self::log_audit(&audit_entry);

        if approved {
            let new_perm = PortalPermission {
                resource: permission.to_string(),
                granted_at: chrono::Local::now().to_rfc3339(),
                reason: if reason.is_empty() {
                    None
                } else {
                    Some(reason.to_string())
                },
            };

            let app_perms = perms.entry(app_id.to_string()).or_insert_with(Vec::new);
            app_perms.push(new_perm);

            let store = PortalPermissionStore {
                granted: perms.clone(),
            };
            if let Err(err) = Self::persist_store(&store) {
                log::warn!("Failed to persist portal permissions: {}", err);
            }

            log::info!("Portal permission granted: {} -> {}", app_id, permission);
        } else {
            log::warn!("Portal permission denied: {} -> {}", app_id, permission);
        }

        Ok(approved)
    }
}

fn prompt_portal_approval(app_id: &str, permission: &str, reason: &str) -> anyhow::Result<bool> {
    let reason_text = if reason.is_empty() {
        String::new()
    } else {
        format!("\nReason: {}", reason)
    };
    let prompt = format!(
        "LifeOS Portal Permission Request\n\nApplication: {}\nPermission: {}{}\n\nAllow access?",
        app_id, permission, reason_text
    );

    if std::process::Command::new("sh")
        .args(["-c", "command -v zenity >/dev/null 2>&1"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
    {
        let status = std::process::Command::new("zenity")
            .args([
                "--question",
                "--title=LifeOS Portal",
                "--text",
                &prompt,
                "--timeout=60",
            ])
            .status();

        if let Ok(status) = status {
            return Ok(status.success());
        }
    }

    if std::process::Command::new("sh")
        .args(["-c", "command -v systemd-ask-password >/dev/null 2>&1"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
    {
        let output = std::process::Command::new("systemd-ask-password")
            .args([
                "--timeout=60",
                &format!(
                    "Allow {} to access {}? type 'yes' to approve",
                    app_id, permission
                ),
            ])
            .output();

        if let Ok(output) = output {
            if output.status.success() {
                let answer = String::from_utf8_lossy(&output.stdout)
                    .trim()
                    .to_lowercase();
                return Ok(answer == "yes" || answer == "y");
            }
        }
    }

    Ok(false)
}

pub async fn start_portal() -> anyhow::Result<Connection> {
    log::info!("Starting LifeOS Portal on D-Bus: org.lifeos.Portal");
    let portal = LifeOsPortal::new();

    let connection = zbus::connection::Builder::session()?
        .name("org.lifeos.Portal")?
        .serve_at("/org/lifeos/Portal", portal)?
        .build()
        .await?;

    Ok(connection)
}
