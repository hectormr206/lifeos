use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use zbus::{interface, Connection};

/// Interfaz D-Bus para el Gestor de Permisos de LifeOS
/// (org.lifeos.Permissions)
pub struct PermissionBroker {
    /// Guardado temporal en memoria de permisos concedidos: app_id -> Vec<resource>
    granted: Arc<Mutex<HashMap<String, Vec<String>>>>,
}

impl Default for PermissionBroker {
    fn default() -> Self {
        Self {
            granted: Arc::new(Mutex::new(HashMap::new())),
        }
    }
}

#[interface(name = "org.lifeos.Permissions")]
impl PermissionBroker {
    /// Solicita acceso a un recurso de hardware o sistema.
    /// Retorna `true` si se concede, `false` si se deniega.
    async fn request_access(&self, app_id: String, resource: String) -> bool {
        log::info!("Permission requested by {} for resource {}", app_id, resource);
        
        let mut granted = self.granted.lock().await;
        
        // Reglas de ejemplo: 
        // 1. Las aplicaciones built-in (ej: CLI) siempre tienen acceso
        // 2. Si ya se concedió en esta sesión, retornar true
        if app_id.starts_with("org.lifeos.core") {
            log::info!("Access granted automatically to core app {}", app_id);
            return true;
        }

        let app_perms = granted.entry(app_id.clone()).or_insert_with(Vec::new);
        
        if app_perms.contains(&resource) {
            log::debug!("Access already granted to {} for {}", app_id, resource);
            return true;
        }
        
        // Simulando una política de Prompt-to-User
        // En un sistema real aquí invocaríamos a COSMIC Polkit o Intent Bus
        log::warn!("Access denied temporarily to {}. Awaiting user prompt implementation.", app_id);
        
        // Dummy: Para MVP aprobamos simuladamente y guardamos en estado
        app_perms.push(resource.clone());
        log::info!("Access granted to {} for {}", app_id, resource);
        true
    }

    /// Verifica si un acceso fue previamente concedido sin pedir confirmación
    async fn check_access(&self, app_id: String, resource: String) -> bool {
        let granted = self.granted.lock().await;
        if let Some(perms) = granted.get(&app_id) {
            perms.contains(&resource)
        } else {
            false
        }
    }
}

/// Inicia el servidor del Permission Broker en el Session Bus
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
