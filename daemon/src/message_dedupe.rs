//! Message Deduplication — prevents processing the same inbound message twice.
//!
//! Uses a time-bounded cache keyed by (channel, peer_id, message_id).
//! Messages seen within the TTL window are silently dropped.

#![allow(dead_code)]

use std::collections::HashMap;
use std::time::{Duration, Instant};
use tokio::sync::RwLock;

const DEDUPE_TTL_SECS: u64 = 300; // 5 minutes
const MAX_CACHE_SIZE: usize = 10_000;

/// Deduplication key: channel + peer + message identifier
#[derive(Hash, Eq, PartialEq, Clone, Debug)]
pub struct DedupeKey {
    pub channel: String,
    pub peer_id: String,
    pub message_id: String,
}

pub struct MessageDedupe {
    cache: RwLock<HashMap<DedupeKey, Instant>>,
}

impl MessageDedupe {
    pub fn new() -> Self {
        Self {
            cache: RwLock::new(HashMap::new()),
        }
    }

    /// Check if a message has already been seen. Returns `true` if it is a DUPLICATE.
    /// If it is new, records it and returns `false`.
    pub async fn is_duplicate(&self, key: DedupeKey) -> bool {
        let now = Instant::now();
        let ttl = Duration::from_secs(DEDUPE_TTL_SECS);

        let mut cache = self.cache.write().await;

        // Prune expired entries if cache is getting large
        if cache.len() > MAX_CACHE_SIZE {
            cache.retain(|_, seen_at| now.duration_since(*seen_at) < ttl);
        }

        // Check if already seen
        if let Some(seen_at) = cache.get(&key) {
            if now.duration_since(*seen_at) < ttl {
                return true; // Duplicate
            }
        }

        // Record as seen
        cache.insert(key, now);
        false // Not a duplicate
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn new_message_is_not_duplicate() {
        let dedupe = MessageDedupe::new();
        let key = DedupeKey {
            channel: "telegram".into(),
            peer_id: "123".into(),
            message_id: "1".into(),
        };
        assert!(!dedupe.is_duplicate(key).await);
    }

    #[tokio::test]
    async fn same_message_is_duplicate() {
        let dedupe = MessageDedupe::new();
        let key = DedupeKey {
            channel: "telegram".into(),
            peer_id: "123".into(),
            message_id: "1".into(),
        };
        assert!(!dedupe.is_duplicate(key.clone()).await);
        assert!(dedupe.is_duplicate(key).await);
    }

    #[tokio::test]
    async fn different_messages_are_not_duplicates() {
        let dedupe = MessageDedupe::new();
        let key1 = DedupeKey {
            channel: "telegram".into(),
            peer_id: "123".into(),
            message_id: "1".into(),
        };
        let key2 = DedupeKey {
            channel: "telegram".into(),
            peer_id: "123".into(),
            message_id: "2".into(),
        };
        assert!(!dedupe.is_duplicate(key1).await);
        assert!(!dedupe.is_duplicate(key2).await);
    }
}
