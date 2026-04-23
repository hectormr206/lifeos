//! LLM provider CRUD endpoints.
//!
//! These endpoints write to the user-scoped TOML at
//! `~/.config/lifeos/llm-providers.toml` (an "active" set) and a sibling
//! `~/.config/lifeos/llm-providers.disabled.toml` (a "stash" of toggled-off
//! entries). After every mutation we call
//! [`crate::llm_router::LlmRouter::reload_providers`] so the live router picks
//! up the change without a daemon restart.
//!
//! We intentionally avoid mutating shipped system TOML files (under
//! `/usr/share/lifeos`) because `/usr` is read-only on the bootc image.

use super::{ApiError, ApiState};
use crate::llm_router::{ApiFormat, ProviderConfig, ProviderTier};
use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::Json,
    routing::{delete, post},
    Router,
};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::OnceLock;
use tokio::sync::Mutex as AsyncMutex;

/// C10: serialize all provider mutations across `create`, `delete`, `toggle`.
/// Without this, two concurrent requests can race on the read-modify-write
/// cycle — losing one mutation, splitting state across `active.toml` /
/// `disabled.toml`, or producing torn writes.
fn provider_mutation_lock() -> &'static AsyncMutex<()> {
    static LOCK: OnceLock<AsyncMutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| AsyncMutex::new(()))
}

pub fn providers_routes() -> Router<ApiState> {
    Router::new()
        .route("/", post(create_provider))
        .route("/:name", delete(delete_provider))
        .route("/:name/toggle", post(toggle_provider))
}

fn config_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
    PathBuf::from(format!("{}/.config/lifeos", home))
}

pub(crate) fn active_path() -> PathBuf {
    config_dir().join("llm-providers.toml")
}

pub(crate) fn disabled_path() -> PathBuf {
    config_dir().join("llm-providers.disabled.toml")
}

#[derive(Debug, Serialize, Deserialize, Default)]
struct ProvidersFile {
    #[serde(default)]
    providers: Vec<ProviderConfig>,
}

fn read_file(path: &std::path::Path) -> ProvidersFile {
    if !path.exists() {
        return ProvidersFile::default();
    }
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| toml::from_str(&s).ok())
        .unwrap_or_default()
}

fn write_file(path: &std::path::Path, file: &ProvidersFile) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let body = toml::to_string_pretty(file).map_err(|e| {
        std::io::Error::new(std::io::ErrorKind::Other, format!("toml serialise: {}", e))
    })?;
    // C10: atomic-write pattern (tempfile + rename) so an interrupted
    // mutation never leaves a partial TOML on disk.
    let dir = path.parent().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "atomic write: path has no parent",
        )
    })?;
    let pid = std::process::id();
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let tmp = dir.join(format!(
        ".{}.tmp-{pid}-{nonce}",
        path.file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("providers")
    ));
    std::fs::write(&tmp, body)?;
    std::fs::rename(&tmp, path)
}

#[derive(Debug, Deserialize)]
pub struct CreateProviderRequest {
    pub name: String,
    pub api_base: String,
    pub model: String,
    #[serde(default)]
    pub api_key_env: String,
    #[serde(default = "default_api_format")]
    pub api_format: String,
    #[serde(default)]
    pub tier: Option<String>,
    #[serde(default)]
    pub privacy: Option<String>,
    #[serde(default)]
    pub max_context: Option<u32>,
    #[serde(default)]
    pub supports_vision: Option<bool>,
}

fn default_api_format() -> String {
    "openai_compatible".into()
}

fn parse_api_format(s: &str) -> Result<ApiFormat, String> {
    match s.to_ascii_lowercase().as_str() {
        "openai" | "openai_compatible" | "openaicompatible" => Ok(ApiFormat::OpenAiCompatible),
        "gemini" => Ok(ApiFormat::Gemini),
        other => Err(format!("unknown api_format '{}'", other)),
    }
}

fn parse_tier(s: &str) -> Result<ProviderTier, String> {
    match s.to_ascii_lowercase().as_str() {
        "local" => Ok(ProviderTier::Local),
        "free" => Ok(ProviderTier::Free),
        "cheap" => Ok(ProviderTier::Cheap),
        "premium" => Ok(ProviderTier::Premium),
        other => Err(format!("unknown tier '{}'", other)),
    }
}

#[derive(Debug, Serialize)]
pub struct ProviderActionResponse {
    pub ok: bool,
    pub name: String,
    pub state: String,
    pub provider_count: usize,
}

/// SB15: env-var-name denylist. An attacker with a bootstrap token could
/// otherwise set `api_key_env="HOME"` (or PATH, USER, ...), and the next
/// outbound provider call would exfiltrate that variable as if it were
/// the API key. Reject anything that doesn't match a sane env-var
/// identifier and anything in this list.
const FORBIDDEN_API_KEY_ENV: &[&str] = &[
    "HOME",
    "USER",
    "PATH",
    "PWD",
    "OLDPWD",
    "SHELL",
    "LANG",
    "LC_ALL",
    "TERM",
    "DISPLAY",
    "XDG_RUNTIME_DIR",
    "DBUS_SESSION_BUS_ADDRESS",
    "MAIL",
    "LOGNAME",
    "HOSTNAME",
];

fn validate_api_key_env(s: &str) -> Result<(), (StatusCode, Json<ApiError>)> {
    if s.is_empty() {
        return Ok(()); // empty means "no api key required"; allowed.
    }
    let valid_shape = !s.is_empty()
        && s.len() <= 64
        && s.chars().enumerate().all(|(i, c)| {
            if i == 0 {
                c.is_ascii_uppercase() || c == '_'
            } else {
                c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_'
            }
        });
    if !valid_shape {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "invalid_api_key_env".into(),
                message:
                    "api_key_env must match POSIX env var name [A-Z_][A-Z0-9_]* (1..=64 chars)"
                        .into(),
                code: 400,
            }),
        ));
    }
    if FORBIDDEN_API_KEY_ENV
        .iter()
        .any(|f| f.eq_ignore_ascii_case(s))
    {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "forbidden_api_key_env".into(),
                message: format!(
                    "api_key_env '{}' is on the denylist (would leak environment to the provider)",
                    s
                ),
                code: 400,
            }),
        ));
    }
    Ok(())
}

fn validate_name(name: &str) -> Result<(), (StatusCode, Json<ApiError>)> {
    if name.is_empty() || name.len() > 64 {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "invalid_name".into(),
                message: "name must be 1..=64 chars".into(),
                code: 400,
            }),
        ));
    }
    if !name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
    {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "invalid_name".into(),
                message: "name may only contain [A-Za-z0-9._-]".into(),
                code: 400,
            }),
        ));
    }
    Ok(())
}

async fn create_provider(
    State(state): State<ApiState>,
    Json(body): Json<CreateProviderRequest>,
) -> Result<Json<ProviderActionResponse>, (StatusCode, Json<ApiError>)> {
    let _guard = provider_mutation_lock().lock().await;
    validate_name(&body.name)?;
    validate_api_key_env(&body.api_key_env)?;

    let api_format = parse_api_format(&body.api_format).map_err(|m| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "invalid_api_format".into(),
                message: m,
                code: 400,
            }),
        )
    })?;
    let tier = match body.tier.as_deref() {
        Some(t) => parse_tier(t).map_err(|m| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "invalid_tier".into(),
                    message: m,
                    code: 400,
                }),
            )
        })?,
        None => ProviderTier::Free,
    };

    if let Err(e) = crate::llm_router::validate_endpoint_safe(&body.api_base) {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "invalid_api_base".into(),
                message: e,
                code: 400,
            }),
        ));
    }

    let cfg = ProviderConfig {
        name: body.name.clone(),
        api_base: body.api_base,
        api_key_env: body.api_key_env,
        model: body.model,
        api_format,
        cost_input_per_m: 0.0,
        cost_output_per_m: 0.0,
        max_rpm: None,
        max_rpd: None,
        supports_vision: body.supports_vision.unwrap_or(false),
        max_context: body.max_context.unwrap_or(128_000),
        tier,
        chat_path: None,
        privacy: body.privacy.unwrap_or_default(),
    };

    let mut active = read_file(&active_path());
    if active.providers.iter().any(|p| p.name == body.name) {
        return Err((
            StatusCode::CONFLICT,
            Json(ApiError {
                error: "provider_exists".into(),
                message: format!("Provider '{}' already exists", body.name),
                code: 409,
            }),
        ));
    }
    let disabled = read_file(&disabled_path());
    if disabled.providers.iter().any(|p| p.name == body.name) {
        return Err((
            StatusCode::CONFLICT,
            Json(ApiError {
                error: "provider_exists_disabled".into(),
                message: format!(
                    "Provider '{}' exists in the disabled stash. Toggle it on first.",
                    body.name
                ),
                code: 409,
            }),
        ));
    }

    active.providers.push(cfg);
    write_file(&active_path(), &active).map_err(io_err)?;

    let count = reload(&state).await?;
    Ok(Json(ProviderActionResponse {
        ok: true,
        name: body.name,
        state: "active".into(),
        provider_count: count,
    }))
}

async fn toggle_provider(
    State(state): State<ApiState>,
    Path(name): Path<String>,
) -> Result<Json<ProviderActionResponse>, (StatusCode, Json<ApiError>)> {
    let _guard = provider_mutation_lock().lock().await;
    validate_name(&name)?;

    let mut active = read_file(&active_path());
    let mut disabled = read_file(&disabled_path());

    let new_state = if let Some(idx) = active.providers.iter().position(|p| p.name == name) {
        let cfg = active.providers.remove(idx);
        disabled.providers.push(cfg);
        write_file(&active_path(), &active).map_err(io_err)?;
        write_file(&disabled_path(), &disabled).map_err(io_err)?;
        "disabled"
    } else if let Some(idx) = disabled.providers.iter().position(|p| p.name == name) {
        let cfg = disabled.providers.remove(idx);
        active.providers.push(cfg);
        write_file(&active_path(), &active).map_err(io_err)?;
        write_file(&disabled_path(), &disabled).map_err(io_err)?;
        "active"
    } else {
        return Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "provider_not_found".into(),
                message: format!(
                    "Provider '{}' not found in user TOML. Built-in providers \
                     ship in the read-only image — copy them to {} first to \
                     toggle them.",
                    name,
                    active_path().display()
                ),
                code: 404,
            }),
        ));
    };

    let count = reload(&state).await?;
    Ok(Json(ProviderActionResponse {
        ok: true,
        name,
        state: new_state.into(),
        provider_count: count,
    }))
}

async fn delete_provider(
    State(state): State<ApiState>,
    Path(name): Path<String>,
) -> Result<Json<ProviderActionResponse>, (StatusCode, Json<ApiError>)> {
    let _guard = provider_mutation_lock().lock().await;
    validate_name(&name)?;

    let mut active = read_file(&active_path());
    let mut disabled = read_file(&disabled_path());

    let active_before = active.providers.len();
    let disabled_before = disabled.providers.len();
    active.providers.retain(|p| p.name != name);
    disabled.providers.retain(|p| p.name != name);

    if active.providers.len() == active_before && disabled.providers.len() == disabled_before {
        return Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "provider_not_found".into(),
                message: format!("Provider '{}' not found in user TOML", name),
                code: 404,
            }),
        ));
    }

    write_file(&active_path(), &active).map_err(io_err)?;
    write_file(&disabled_path(), &disabled).map_err(io_err)?;

    let count = reload(&state).await?;
    Ok(Json(ProviderActionResponse {
        ok: true,
        name,
        state: "deleted".into(),
        provider_count: count,
    }))
}

async fn reload(state: &ApiState) -> Result<usize, (StatusCode, Json<ApiError>)> {
    let mut router = state.llm_router.write().await;
    router.reload_providers().map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "reload_failed".into(),
                message: format!("Failed to reload providers: {}", e),
                code: 500,
            }),
        )
    })
}

fn io_err(e: std::io::Error) -> (StatusCode, Json<ApiError>) {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(ApiError {
            error: "io_error".into(),
            message: format!("file write failed: {}", e),
            code: 500,
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_api_format_accepts_known_values() {
        assert!(matches!(
            parse_api_format("openai_compatible"),
            Ok(ApiFormat::OpenAiCompatible)
        ));
        assert!(matches!(
            parse_api_format("OpenAI"),
            Ok(ApiFormat::OpenAiCompatible)
        ));
        assert!(matches!(parse_api_format("gemini"), Ok(ApiFormat::Gemini)));
        assert!(parse_api_format("nope").is_err());
    }

    #[test]
    fn parse_tier_accepts_known_values() {
        assert!(matches!(parse_tier("local"), Ok(ProviderTier::Local)));
        assert!(matches!(parse_tier("FREE"), Ok(ProviderTier::Free)));
        assert!(matches!(parse_tier("Cheap"), Ok(ProviderTier::Cheap)));
        assert!(matches!(parse_tier("premium"), Ok(ProviderTier::Premium)));
        assert!(parse_tier("ultra").is_err());
    }

    #[test]
    fn validate_api_key_env_accepts_sane_names() {
        assert!(validate_api_key_env("").is_ok());
        assert!(validate_api_key_env("OPENAI_API_KEY").is_ok());
        assert!(validate_api_key_env("LIFEOS_PROVIDER_KEY").is_ok());
        assert!(validate_api_key_env("_INTERNAL").is_ok());
    }

    #[test]
    fn validate_api_key_env_rejects_dangerous() {
        // Denylisted names — would exfiltrate the user's environment.
        assert!(validate_api_key_env("HOME").is_err());
        assert!(validate_api_key_env("PATH").is_err());
        assert!(validate_api_key_env("home").is_err()); // case-insensitive denylist
                                                        // Lowercase / mixed identifiers (POSIX env name regex demands upper).
        assert!(validate_api_key_env("openai_key").is_err());
        // Shell metachars.
        assert!(validate_api_key_env("FOO;rm -rf /").is_err());
        assert!(validate_api_key_env("FOO BAR").is_err());
        // Leading digit.
        assert!(validate_api_key_env("1FOO").is_err());
    }

    #[test]
    fn validate_name_rejects_bad_chars() {
        assert!(validate_name("good-name_1").is_ok());
        assert!(validate_name("").is_err());
        assert!(validate_name("bad name").is_err());
        assert!(validate_name("bad/slash").is_err());
        let too_long: String = "x".repeat(65);
        assert!(validate_name(&too_long).is_err());
    }

    #[test]
    fn read_file_returns_default_when_missing() {
        let tmp =
            std::env::temp_dir().join(format!("lifeos-test-providers-{}.toml", std::process::id()));
        let _ = std::fs::remove_file(&tmp);
        let f = read_file(&tmp);
        assert!(f.providers.is_empty());
    }

    #[test]
    fn write_then_read_roundtrip() {
        let tmp = std::env::temp_dir().join(format!(
            "lifeos-test-providers-rt-{}.toml",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&tmp);
        let cfg = ProviderConfig {
            name: "test-prov".into(),
            api_base: "https://example.com".into(),
            api_key_env: "TEST_KEY".into(),
            model: "test-model".into(),
            api_format: ApiFormat::OpenAiCompatible,
            cost_input_per_m: 0.0,
            cost_output_per_m: 0.0,
            max_rpm: None,
            max_rpd: None,
            supports_vision: false,
            max_context: 8000,
            tier: ProviderTier::Free,
            chat_path: None,
            privacy: String::new(),
        };
        let file = ProvidersFile {
            providers: vec![cfg],
        };
        write_file(&tmp, &file).expect("write");
        let read = read_file(&tmp);
        assert_eq!(read.providers.len(), 1);
        assert_eq!(read.providers[0].name, "test-prov");
        let _ = std::fs::remove_file(&tmp);
    }
}
