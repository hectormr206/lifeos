use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;

#[derive(Debug, Clone, Copy)]
pub struct TufVersions {
    pub root: u64,
    pub timestamp: u64,
    pub snapshot: u64,
    pub targets: u64,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct TufState {
    root: u64,
    timestamp: u64,
    snapshot: u64,
    targets: u64,
}

#[derive(Debug, Deserialize)]
struct Envelope<T> {
    signed: T,
}

#[derive(Debug, Deserialize)]
struct RootMetadata {
    version: u64,
    expires: String,
}

#[derive(Debug, Deserialize)]
struct TimestampMetadata {
    version: u64,
    expires: String,
    meta: HashMap<String, MetaFile>,
}

#[derive(Debug, Deserialize)]
struct SnapshotMetadata {
    version: u64,
    expires: String,
    meta: HashMap<String, MetaFile>,
}

#[derive(Debug, Deserialize)]
struct TargetsMetadata {
    version: u64,
    expires: String,
    targets: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct MetaFile {
    version: u64,
}

pub fn validate_tuf_metadata(metadata_dir: &Path, state_path: &Path) -> anyhow::Result<TufVersions> {
    ensure_required_files(metadata_dir)?;

    let root: Envelope<RootMetadata> = read_metadata(metadata_dir.join("root.json"))?;
    let timestamp: Envelope<TimestampMetadata> = read_metadata(metadata_dir.join("timestamp.json"))?;
    let snapshot: Envelope<SnapshotMetadata> = read_metadata(metadata_dir.join("snapshot.json"))?;
    let targets: Envelope<TargetsMetadata> = read_metadata(metadata_dir.join("targets.json"))?;

    ensure_not_expired("root", &root.signed.expires)?;
    ensure_not_expired("timestamp", &timestamp.signed.expires)?;
    ensure_not_expired("snapshot", &snapshot.signed.expires)?;
    ensure_not_expired("targets", &targets.signed.expires)?;

    if targets.signed.targets.is_empty() {
        anyhow::bail!("targets metadata is empty; update trust policy is incomplete");
    }

    let timestamp_snapshot_version = timestamp
        .signed
        .meta
        .get("snapshot.json")
        .map(|m| m.version)
        .ok_or_else(|| anyhow::anyhow!("timestamp metadata missing snapshot.json entry"))?;
    if snapshot.signed.version != timestamp_snapshot_version {
        anyhow::bail!(
            "snapshot version mismatch: timestamp expects {}, got {}",
            timestamp_snapshot_version,
            snapshot.signed.version
        );
    }

    let snapshot_targets_version = snapshot
        .signed
        .meta
        .get("targets.json")
        .map(|m| m.version)
        .ok_or_else(|| anyhow::anyhow!("snapshot metadata missing targets.json entry"))?;
    if targets.signed.version != snapshot_targets_version {
        anyhow::bail!(
            "targets version mismatch: snapshot expects {}, got {}",
            snapshot_targets_version,
            targets.signed.version
        );
    }

    let versions = TufVersions {
        root: root.signed.version,
        timestamp: timestamp.signed.version,
        snapshot: snapshot.signed.version,
        targets: targets.signed.version,
    };

    enforce_anti_rollback(state_path, versions)?;

    Ok(versions)
}

pub fn metadata_exists(metadata_dir: &Path) -> bool {
    ["root.json", "timestamp.json", "snapshot.json", "targets.json"]
        .iter()
        .all(|name| metadata_dir.join(name).exists())
}

fn ensure_required_files(metadata_dir: &Path) -> anyhow::Result<()> {
    let required = ["root.json", "timestamp.json", "snapshot.json", "targets.json"];
    for name in required {
        if !metadata_dir.join(name).exists() {
            anyhow::bail!("missing TUF metadata file: {}", metadata_dir.join(name).display());
        }
    }
    Ok(())
}

fn ensure_not_expired(name: &str, expires: &str) -> anyhow::Result<()> {
    let expires_at = DateTime::parse_from_rfc3339(expires)
        .map_err(|e| anyhow::anyhow!("invalid {} expires field: {}", name, e))?
        .with_timezone(&Utc);
    if expires_at <= Utc::now() {
        anyhow::bail!("{} metadata expired at {}", name, expires_at.to_rfc3339());
    }
    Ok(())
}

fn read_metadata<T: for<'de> Deserialize<'de>>(path: std::path::PathBuf) -> anyhow::Result<T> {
    let content = std::fs::read_to_string(&path)?;
    let parsed = serde_json::from_str::<T>(&content)?;
    Ok(parsed)
}

fn enforce_anti_rollback(state_path: &Path, versions: TufVersions) -> anyhow::Result<()> {
    let mut previous = TufState::default();
    if state_path.exists() {
        let content = std::fs::read_to_string(state_path)?;
        previous = serde_json::from_str::<TufState>(&content).unwrap_or_default();
    }

    if versions.root < previous.root {
        anyhow::bail!(
            "root metadata rollback detected ({} < {})",
            versions.root,
            previous.root
        );
    }
    if versions.timestamp < previous.timestamp {
        anyhow::bail!(
            "timestamp metadata rollback detected ({} < {})",
            versions.timestamp,
            previous.timestamp
        );
    }
    if versions.snapshot < previous.snapshot {
        anyhow::bail!(
            "snapshot metadata rollback detected ({} < {})",
            versions.snapshot,
            previous.snapshot
        );
    }
    if versions.targets < previous.targets {
        anyhow::bail!(
            "targets metadata rollback detected ({} < {})",
            versions.targets,
            previous.targets
        );
    }

    if let Some(parent) = state_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let next_state = TufState {
        root: versions.root,
        timestamp: versions.timestamp,
        snapshot: versions.snapshot,
        targets: versions.targets,
    };
    std::fs::write(state_path, serde_json::to_string_pretty(&next_state)?)?;
    Ok(())
}
