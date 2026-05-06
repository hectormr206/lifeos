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

use std::env;

const DEFAULT_LLAMA_URL: &str = "http://127.0.0.1:8082";
const DEFAULT_EMBEDDINGS_URL: &str = "http://127.0.0.1:8083";
const DEFAULT_TTS_URL: &str = "http://127.0.0.1:8084";

/// Base URL of the chat-inference llama-server (Quadlet:
/// `lifeos-llama-server`). Override with `LIFEOS_LLAMA_URL`.
pub fn llama_url() -> String {
    env::var("LIFEOS_LLAMA_URL")
        .unwrap_or_else(|_| DEFAULT_LLAMA_URL.to_string())
        .trim_end_matches('/')
        .to_string()
}

/// Base URL of the embeddings llama-server (Quadlet:
/// `lifeos-llama-embeddings`). Override with `LIFEOS_EMBED_URL`.
pub fn embeddings_url() -> String {
    env::var("LIFEOS_EMBED_URL")
        .unwrap_or_else(|_| DEFAULT_EMBEDDINGS_URL.to_string())
        .trim_end_matches('/')
        .to_string()
}

/// Base URL of the Kokoro TTS HTTP server (Quadlet: `lifeos-tts`).
/// Honors `LIFEOS_TTS_URL` first, then the legacy `LIFEOS_TTS_SERVER_URL`
/// for compatibility with operators who set the older name in
/// `/etc/lifeos/tts-server.env` before the pivot.
pub fn tts_url() -> String {
    env::var("LIFEOS_TTS_URL")
        .or_else(|_| env::var("LIFEOS_TTS_SERVER_URL"))
        .unwrap_or_else(|_| DEFAULT_TTS_URL.to_string())
        .trim_end_matches('/')
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // env::set_var / remove_var is process-global; serialise tests so
    // parallel runs don't clobber each other's overrides.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn with_env<F: FnOnce()>(vars: &[(&str, Option<&str>)], f: F) {
        let _g = ENV_LOCK.lock().unwrap();
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
        f();
        for (k, original) in snapshot {
            match original {
                Some(val) => env::set_var(&k, val),
                None => env::remove_var(&k),
            }
        }
    }

    #[test]
    fn llama_url_defaults_to_loopback() {
        with_env(&[("LIFEOS_LLAMA_URL", None)], || {
            assert_eq!(llama_url(), "http://127.0.0.1:8082");
        });
    }

    #[test]
    fn llama_url_honors_override() {
        with_env(
            &[("LIFEOS_LLAMA_URL", Some("http://lifeos-llama-server:8082"))],
            || {
                assert_eq!(llama_url(), "http://lifeos-llama-server:8082");
            },
        );
    }

    #[test]
    fn llama_url_strips_trailing_slash() {
        with_env(
            &[("LIFEOS_LLAMA_URL", Some("http://lifeos-llama-server:8082/"))],
            || {
                assert_eq!(llama_url(), "http://lifeos-llama-server:8082");
            },
        );
    }

    #[test]
    fn embeddings_url_defaults() {
        with_env(&[("LIFEOS_EMBED_URL", None)], || {
            assert_eq!(embeddings_url(), "http://127.0.0.1:8083");
        });
    }

    #[test]
    fn tts_url_prefers_new_var_over_legacy() {
        with_env(
            &[
                ("LIFEOS_TTS_URL", Some("http://lifeos-tts:8084")),
                ("LIFEOS_TTS_SERVER_URL", Some("http://legacy:8084")),
            ],
            || {
                assert_eq!(tts_url(), "http://lifeos-tts:8084");
            },
        );
    }

    #[test]
    fn tts_url_falls_back_to_legacy_var() {
        with_env(
            &[
                ("LIFEOS_TTS_URL", None),
                ("LIFEOS_TTS_SERVER_URL", Some("http://legacy:8084")),
            ],
            || {
                assert_eq!(tts_url(), "http://legacy:8084");
            },
        );
    }
}
