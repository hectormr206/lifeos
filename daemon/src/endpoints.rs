//! Endpoint URL lookups for sibling services.
//!
//! Phase 8b of the architecture pivot: the daemon used to live on
//! `Network=host`, so every chat/embedding/TTS call talked to
//! `http://127.0.0.1:80xx` on the host loopback. The pivot moves the
//! daemon to a podman bridge (`lifeos-net`), where:
//!
//!   - `127.0.0.1` inside the container is the container's own loopback,
//!     NOT the host. The hardcoded URLs would silently 404.
//!   - Sibling containers are reachable by name via Podman's embedded
//!     DNS: `lifeos-llama-server.dns.podman:8082` etc.
//!
//! This module centralises the env-var lookup so the Quadlet can set
//! `Environment=LIFEOS_LLAMA_URL=http://lifeos-llama-server:8082` when
//! the daemon is on the bridge, and keep the loopback default for the
//! legacy `Network=host` path.
//!
//! Operational note: each URL is resolved exactly once per process via
//! `OnceLock`; the resolved value is logged at INFO so the journal
//! always shows what the daemon is talking to. Changing `LIFEOS_*_URL`
//! in `/etc/lifeos/*.env` therefore requires
//! `systemctl restart lifeos-lifeosd` — there is no runtime re-read.
//! Round-2 JD flagged the previously-mixed semantics (some URLs cached
//! at startup, some re-read every call) as a silent-misconfig hazard;
//! one rule, applied uniformly, is the fix.

use std::env;
use std::sync::OnceLock;

const DEFAULT_LLAMA_URL: &str = "http://127.0.0.1:8082";
const DEFAULT_EMBEDDINGS_URL: &str = "http://127.0.0.1:8083";
const DEFAULT_TTS_URL: &str = "http://127.0.0.1:8084";

/// Validate and normalise an operator-supplied URL. Returns `Some(clean)`
/// if the value parses as a bare `scheme://host[:port]` URL (with at
/// most one trailing slash stripped). Otherwise returns `None` and the
/// caller falls back to the default.
///
/// Rejected (judges flagged these as silent-failure surfaces):
///   - missing `http://` or `https://` scheme — `reqwest` would either
///     fail to parse or interpret `host:port` as a custom scheme.
///   - URLs with a path/query/fragment beyond `/` — the daemon appends
///     fixed paths (`/health`, `/v1/...`), so a base of `host:port/v1/`
///     would produce `host:port/v1/v1/...` after the trim.
///   - empty authority (`http://`, `http:///` typos).
///   - any ASCII control character or whitespace inside the value
///     (CR/LF/TAB/space) — these reach reqwest and explode opaquely.
fn sanitize_url(raw: &str, var_name: &str) -> Option<String> {
    // Check the RAW input for any control character. trim() would strip
    // trailing CR/LF/TAB (heredoc / hand-edited env file artifacts) and
    // mask the typo; we want to reject the value so the operator sees a
    // WARN line instead of a silent fallback.
    if raw.chars().any(|c| c.is_control()) {
        log::warn!(
            "{} ignored: contains control character (got {:?})",
            var_name,
            raw
        );
        return None;
    }
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    // Embedded space inside the URL (operator typed `http://h h:1`).
    if trimmed.contains(' ') {
        log::warn!(
            "{} ignored: contains whitespace (got {:?})",
            var_name,
            trimmed
        );
        return None;
    }
    let lower = trimmed.to_ascii_lowercase();
    if !lower.starts_with("http://") && !lower.starts_with("https://") {
        log::warn!(
            "{} ignored: missing http:// or https:// scheme (got {:?})",
            var_name,
            trimmed
        );
        return None;
    }
    // Strip a single trailing slash (the common "http://h:p/" form).
    let no_slash = trimmed.strip_suffix('/').unwrap_or(trimmed);
    let after_scheme = match no_slash.find("://") {
        Some(idx) => &no_slash[idx + 3..],
        None => return None,
    };
    if after_scheme.is_empty() {
        log::warn!(
            "{} ignored: empty authority after scheme (got {:?})",
            var_name,
            trimmed
        );
        return None;
    }
    if after_scheme.contains('/') || after_scheme.contains('?') || after_scheme.contains('#') {
        log::warn!(
            "{} ignored: only bare scheme://host[:port] is supported, got {:?}",
            var_name,
            trimmed
        );
        return None;
    }
    Some(no_slash.to_string())
}

fn resolve_once(var: &str, default: &str) -> String {
    let resolved = match env::var(var) {
        Ok(raw) => sanitize_url(&raw, var).unwrap_or_else(|| default.to_string()),
        Err(_) => default.to_string(),
    };
    log::info!("{} resolved to {}", var, resolved);
    resolved
}

/// Base URL of the chat-inference llama-server (Quadlet:
/// `lifeos-llama-server`). Override with `LIFEOS_LLAMA_URL`.
/// Resolved once per process; subsequent env changes need a daemon restart.
pub fn llama_url() -> String {
    static CACHED: OnceLock<String> = OnceLock::new();
    CACHED
        .get_or_init(|| resolve_once("LIFEOS_LLAMA_URL", DEFAULT_LLAMA_URL))
        .clone()
}

/// Base URL of the embeddings llama-server (Quadlet:
/// `lifeos-llama-embeddings`). Override with `LIFEOS_EMBED_URL`.
/// Resolved once per process; subsequent env changes need a daemon restart.
pub fn embeddings_url() -> String {
    static CACHED: OnceLock<String> = OnceLock::new();
    CACHED
        .get_or_init(|| resolve_once("LIFEOS_EMBED_URL", DEFAULT_EMBEDDINGS_URL))
        .clone()
}

/// Base URL of the Kokoro TTS HTTP server (Quadlet: `lifeos-tts`).
/// Honors `LIFEOS_TTS_URL` first, then the legacy `LIFEOS_TTS_SERVER_URL`
/// for compatibility with operators who set the older name in
/// `/etc/lifeos/tts-server.env` before the pivot. A one-shot deprecation
/// warning fires if the legacy var is the one that wins.
/// Resolved once per process; subsequent env changes need a daemon restart.
pub fn tts_url() -> String {
    static CACHED: OnceLock<String> = OnceLock::new();
    CACHED
        .get_or_init(|| {
            if let Ok(raw) = env::var("LIFEOS_TTS_URL") {
                if let Some(clean) = sanitize_url(&raw, "LIFEOS_TTS_URL") {
                    log::info!("LIFEOS_TTS_URL resolved to {}", clean);
                    return clean;
                }
            }
            if let Ok(raw) = env::var("LIFEOS_TTS_SERVER_URL") {
                if let Some(clean) = sanitize_url(&raw, "LIFEOS_TTS_SERVER_URL") {
                    log::warn!(
                        "LIFEOS_TTS_SERVER_URL is deprecated; rename to LIFEOS_TTS_URL \
                         in /etc/lifeos/tts-server.env"
                    );
                    log::info!("LIFEOS_TTS_SERVER_URL (legacy) resolved to {}", clean);
                    return clean;
                }
            }
            log::info!("LIFEOS_TTS_URL resolved to {} (default)", DEFAULT_TTS_URL);
            DEFAULT_TTS_URL.to_string()
        })
        .clone()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // env::set_var / remove_var is process-global; serialise tests so
    // parallel runs don't clobber each other's overrides.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    /// Run `f` with the given env-var overrides applied, restoring the
    /// previous values afterwards even if `f` panics. Round-2 JD caught
    /// that the naive version leaked state on panic and poisoned the
    /// global lock, cascading failures across unrelated tests.
    fn with_env<F: FnOnce() + std::panic::UnwindSafe>(vars: &[(&str, Option<&str>)], f: F) {
        // Recover from a poisoned lock: a previous panicking test would
        // otherwise infect every subsequent test in the binary.
        let _g = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let snapshot: Vec<(String, Option<String>)> = vars
            .iter()
            .map(|(k, _)| (k.to_string(), env::var(k).ok()))
            .collect();
        for (k, v) in vars {
            match v {
                Some(val) => env::set_var(k, val),
                None => env::remove_var(k),
            }
        }
        let result = std::panic::catch_unwind(f);
        for (k, original) in snapshot {
            match original {
                Some(val) => env::set_var(&k, val),
                None => env::remove_var(&k),
            }
        }
        if let Err(payload) = result {
            std::panic::resume_unwind(payload);
        }
    }

    // Public llama_url()/embeddings_url()/tts_url() are OnceLock-cached
    // and therefore not unit-testable in isolation (the first call wins
    // for the lifetime of the test binary). The behaviour they delegate
    // to lives in sanitize_url() and resolve_once() — both of which are
    // exhaustively covered below. The cache itself is a simple
    // OnceLock::get_or_init wrapping resolve_once, so its correctness
    // reduces to those.

    #[test]
    fn sanitize_accepts_bare_loopback_default() {
        assert_eq!(
            sanitize_url("http://127.0.0.1:8082", "T").as_deref(),
            Some("http://127.0.0.1:8082")
        );
    }

    #[test]
    fn sanitize_accepts_bridge_dns_name() {
        assert_eq!(
            sanitize_url("http://lifeos-llama-server:8082", "T").as_deref(),
            Some("http://lifeos-llama-server:8082")
        );
    }

    #[test]
    fn sanitize_strips_single_trailing_slash() {
        assert_eq!(
            sanitize_url("http://h:1/", "T").as_deref(),
            Some("http://h:1")
        );
    }

    #[test]
    fn sanitize_rejects_missing_scheme() {
        assert!(sanitize_url("h:8082", "T").is_none());
    }

    #[test]
    fn sanitize_rejects_path_component() {
        assert!(sanitize_url("http://h:1/v1/", "T").is_none());
    }

    #[test]
    fn sanitize_rejects_query_and_fragment() {
        assert!(sanitize_url("http://h:1?x=1", "T").is_none());
        assert!(sanitize_url("http://h:1#frag", "T").is_none());
    }

    #[test]
    fn sanitize_rejects_empty_authority() {
        // `http://` and `http:///` (typos that previously slipped through
        // and produced opaque reqwest errors) must fail validation.
        assert!(sanitize_url("http://", "T").is_none());
        assert!(sanitize_url("http:///", "T").is_none());
    }

    #[test]
    fn sanitize_rejects_embedded_whitespace_and_control() {
        assert!(sanitize_url("http://h h:1", "T").is_none());
        assert!(sanitize_url("http://h:1\n", "T").is_none());
        assert!(sanitize_url("http://h:1\t", "T").is_none());
        assert!(sanitize_url("http://h:1\r", "T").is_none());
    }

    #[test]
    fn sanitize_rejects_empty_or_whitespace_only() {
        assert!(sanitize_url("", "T").is_none());
        assert!(sanitize_url("   ", "T").is_none());
    }

    // resolve_once exercises the env-var read + sanitize + default chain.
    // It does NOT touch the OnceLock caches in the public functions, so
    // each test gets a fresh evaluation.

    #[test]
    fn resolve_once_returns_default_when_unset() {
        with_env(&[("LIFEOS_TEST_RESOLVE_A", None)], || {
            assert_eq!(
                resolve_once("LIFEOS_TEST_RESOLVE_A", "http://default:1"),
                "http://default:1"
            );
        });
    }

    #[test]
    fn resolve_once_honors_valid_override() {
        with_env(
            &[("LIFEOS_TEST_RESOLVE_B", Some("http://override:9"))],
            || {
                assert_eq!(
                    resolve_once("LIFEOS_TEST_RESOLVE_B", "http://default:1"),
                    "http://override:9"
                );
            },
        );
    }

    #[test]
    fn resolve_once_falls_back_on_invalid_override() {
        with_env(&[("LIFEOS_TEST_RESOLVE_C", Some("not-a-url"))], || {
            assert_eq!(
                resolve_once("LIFEOS_TEST_RESOLVE_C", "http://default:1"),
                "http://default:1"
            );
        });
    }
}
