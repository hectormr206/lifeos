//! Modo Privacidad — toggle global que fuerza al `llm_router` a usar SOLO
//! providers `tier=Local`.
//!
//! Estado:
//! - Persistido en `~/.config/lifeos/privacy-mode` (un único byte: `0` o `1`).
//! - Override por env var `LIFEOS_PRIVACY_MODE` (1/true/yes/on → true,
//!   0/false/no/off → false, otro valor → cae al archivo).
//! - Cache en memoria (`RwLock<bool>`) para no leer disco en cada request del
//!   router.
//!
//! Endpoints (gated por `x-bootstrap-token` desde el router en `api/mod.rs`):
//! - `GET  /api/v1/privacy-mode` → estado actual + fuente
//! - `POST /api/v1/privacy-mode` → persiste y devuelve el nuevo estado
//!
//! Diseño:
//! - El router consulta `is_privacy_mode_enabled()` antes de elegir candidates.
//!   Si está ON, filtra `ProviderTier::Local` y deshabilita la escalation a Free.
//! - Si el caller pidió un `preferred_provider` que no es Local, se sobrescribe
//!   al primer Local disponible (con `warn!`).

use super::{ApiError, ApiState};
use axum::{
    extract::State,
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use log::{info, warn};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::{OnceLock, RwLock};

const ENV_VAR: &str = "LIFEOS_PRIVACY_MODE";
const FILE_NAME: &str = "privacy-mode";

/// Cache en memoria del estado leído desde archivo. `None` = aún no inicializado.
fn cache() -> &'static RwLock<Option<bool>> {
    static CACHE: OnceLock<RwLock<Option<bool>>> = OnceLock::new();
    CACHE.get_or_init(|| RwLock::new(None))
}

fn config_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
    PathBuf::from(format!("{}/.config/lifeos", home))
}

fn state_path() -> PathBuf {
    config_dir().join(FILE_NAME)
}

/// Resultado de la resolución del estado actual, incluyendo de dónde vino.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrivacySource {
    Env,
    File,
    Default,
}

impl PrivacySource {
    fn as_str(&self) -> &'static str {
        match self {
            PrivacySource::Env => "env",
            PrivacySource::File => "file",
            PrivacySource::Default => "default",
        }
    }
}

/// Parse del env var. Devuelve `Some(bool)` si reconoce el valor, `None` si no.
fn parse_env(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

/// Lee el archivo de estado. Devuelve `None` si no existe o está malformado.
fn read_file() -> Option<bool> {
    let path = state_path();
    let content = std::fs::read_to_string(&path).ok()?;
    let trimmed = content.trim();
    match trimmed {
        "1" => Some(true),
        "0" => Some(false),
        _ => None,
    }
}

/// Escribe el archivo de estado de manera atómica (tempfile + rename).
fn write_file(enabled: bool) -> std::io::Result<()> {
    let path = state_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let body = if enabled { "1" } else { "0" };
    let dir = path.parent().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "atomic write: path sin parent",
        )
    })?;
    let pid = std::process::id();
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let tmp = dir.join(format!(".privacy-mode.tmp-{pid}-{nonce}"));
    std::fs::write(&tmp, body)?;
    std::fs::rename(&tmp, &path)
}

/// Resuelve el estado y la fuente. Lee env var primero, luego cache, luego archivo.
fn resolve() -> (bool, PrivacySource) {
    if let Ok(value) = std::env::var(ENV_VAR) {
        if let Some(parsed) = parse_env(&value) {
            return (parsed, PrivacySource::Env);
        }
    }
    {
        let guard = cache().read().expect("privacy_mode cache poisoned");
        if let Some(value) = *guard {
            return (value, PrivacySource::File);
        }
    }
    // Cache miss → leer archivo y poblar
    let from_file = read_file();
    let mut guard = cache().write().expect("privacy_mode cache poisoned");
    if let Some(value) = from_file {
        *guard = Some(value);
        (value, PrivacySource::File)
    } else {
        // No archivo → default false. Cacheamos `false` para evitar releer
        // en cada request hasta que el usuario haga toggle.
        *guard = Some(false);
        (false, PrivacySource::Default)
    }
}

/// API pública consumida por el llm_router. Devuelve `true` si el modo
/// privacidad está activo (env var > archivo > default false).
pub fn is_privacy_mode_enabled() -> bool {
    resolve().0
}

/// Persiste el nuevo estado y actualiza el cache. NO modifica el env var.
pub fn set_privacy_mode(enabled: bool) -> std::io::Result<()> {
    write_file(enabled)?;
    let mut guard = cache().write().expect("privacy_mode cache poisoned");
    *guard = Some(enabled);
    info!("[privacy_mode] estado actualizado → {}", enabled);
    Ok(())
}

#[cfg(test)]
fn reset_cache_for_test() {
    let mut guard = cache().write().expect("privacy_mode cache poisoned");
    *guard = None;
}

/// Lock global compartido entre todos los tests del crate que tocan
/// `LIFEOS_PRIVACY_MODE` o el archivo de estado. Necesario porque
/// distintos módulos de test corren en paralelo y env vars / cache son
/// estado global. Usamos `tokio::sync::Mutex` para que sea await-safe.
#[cfg(test)]
pub(crate) fn test_state_lock() -> &'static tokio::sync::Mutex<()> {
    static LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
}

// --------------------------------------------------------------------------
// HTTP handlers
// --------------------------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct PrivacyModeStatus {
    pub enabled: bool,
    pub source: &'static str,
}

#[derive(Debug, Deserialize)]
pub struct SetPrivacyModeRequest {
    pub enabled: bool,
}

pub fn privacy_mode_routes() -> Router<ApiState> {
    Router::new()
        .route("/", get(get_privacy_mode))
        .route("/", post(post_privacy_mode))
}

async fn get_privacy_mode(
    State(_state): State<ApiState>,
) -> Result<Json<PrivacyModeStatus>, (StatusCode, Json<ApiError>)> {
    let (enabled, source) = resolve();
    Ok(Json(PrivacyModeStatus {
        enabled,
        source: source.as_str(),
    }))
}

async fn post_privacy_mode(
    State(_state): State<ApiState>,
    Json(payload): Json<SetPrivacyModeRequest>,
) -> Result<Json<PrivacyModeStatus>, (StatusCode, Json<ApiError>)> {
    if let Err(e) = set_privacy_mode(payload.enabled) {
        warn!(
            "[privacy_mode] no pude persistir estado={}: {}",
            payload.enabled, e
        );
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "privacy_mode_persist_failed".into(),
                message: format!("No se pudo escribir el archivo de estado: {}", e),
                code: 500,
            }),
        ));
    }
    // Volver a resolver para reportar la fuente real (env var puede sobrescribir).
    let (enabled, source) = resolve();
    Ok(Json(PrivacyModeStatus {
        enabled,
        source: source.as_str(),
    }))
}

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Los tests modifican env vars y archivos compartidos (cache global +
    /// $HOME). Serializamos para evitar races con `llm_router::tests`,
    /// que toca la misma env var en paralelo (cargo test corre módulos en
    /// hilos distintos).
    fn test_lock() -> &'static tokio::sync::Mutex<()> {
        test_state_lock()
    }

    /// Setup: redirige $HOME a un tempdir aislado y limpia env+cache.
    fn setup() -> tempfile::TempDir {
        let tmp = tempfile::tempdir().expect("tempdir");
        std::env::set_var("HOME", tmp.path());
        std::env::remove_var(ENV_VAR);
        reset_cache_for_test();
        tmp
    }

    #[test]
    fn env_var_on_overrides_everything() {
        let _guard = test_lock().blocking_lock();
        let _tmp = setup();
        std::env::set_var(ENV_VAR, "1");
        let (enabled, source) = resolve();
        assert!(enabled);
        assert_eq!(source, PrivacySource::Env);

        std::env::set_var(ENV_VAR, "true");
        assert!(is_privacy_mode_enabled());
        std::env::set_var(ENV_VAR, "yes");
        assert!(is_privacy_mode_enabled());
        std::env::set_var(ENV_VAR, "on");
        assert!(is_privacy_mode_enabled());
        std::env::remove_var(ENV_VAR);
    }

    #[test]
    fn env_var_off_overrides_file_on() {
        let _guard = test_lock().blocking_lock();
        let _tmp = setup();
        // Archivo dice ON
        set_privacy_mode(true).expect("persist");
        // Pero env var dice OFF → gana env
        std::env::set_var(ENV_VAR, "0");
        let (enabled, source) = resolve();
        assert!(!enabled);
        assert_eq!(source, PrivacySource::Env);
        std::env::remove_var(ENV_VAR);
    }

    #[test]
    fn env_var_unrecognized_falls_through_to_file() {
        let _guard = test_lock().blocking_lock();
        let _tmp = setup();
        set_privacy_mode(true).expect("persist");
        std::env::set_var(ENV_VAR, "maybe");
        let (enabled, source) = resolve();
        assert!(enabled);
        assert_eq!(source, PrivacySource::File);
        std::env::remove_var(ENV_VAR);
    }

    #[test]
    fn file_absent_returns_default_false() {
        let _guard = test_lock().blocking_lock();
        let _tmp = setup();
        let (enabled, source) = resolve();
        assert!(!enabled);
        assert_eq!(source, PrivacySource::Default);
    }

    #[test]
    fn toggle_round_trip_persists() {
        let _guard = test_lock().blocking_lock();
        let _tmp = setup();
        set_privacy_mode(true).expect("persist on");
        // Reset cache para forzar relectura desde disco
        reset_cache_for_test();
        let (enabled, source) = resolve();
        assert!(enabled);
        assert_eq!(source, PrivacySource::File);

        set_privacy_mode(false).expect("persist off");
        reset_cache_for_test();
        let (enabled, source) = resolve();
        assert!(!enabled);
        assert_eq!(source, PrivacySource::File);
    }

    #[test]
    fn concurrent_reads_no_race() {
        let _guard = test_lock().blocking_lock();
        let _tmp = setup();
        set_privacy_mode(true).expect("persist");

        let handles: Vec<_> = (0..16)
            .map(|_| std::thread::spawn(is_privacy_mode_enabled))
            .collect();
        for h in handles {
            assert!(h.join().expect("thread join"));
        }
    }

    #[test]
    fn parse_env_recognizes_common_truthy_falsy() {
        assert_eq!(parse_env("1"), Some(true));
        assert_eq!(parse_env("True"), Some(true));
        assert_eq!(parse_env(" YES "), Some(true));
        assert_eq!(parse_env("on"), Some(true));
        assert_eq!(parse_env("0"), Some(false));
        assert_eq!(parse_env("FALSE"), Some(false));
        assert_eq!(parse_env("off"), Some(false));
        assert_eq!(parse_env("nope"), None);
        assert_eq!(parse_env(""), None);
    }
}
