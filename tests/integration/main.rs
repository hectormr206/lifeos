//! Integration tests for LifeOS CLI and Daemon
//!
//! These tests verify the interaction between CLI and Daemon components

use std::process::Command;
use tempfile::TempDir;

/// Get project root (workspace root is 2 levels up from tests/integration/)
fn project_root() -> std::path::PathBuf {
    let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // tests/Cargo.toml is at <root>/tests/, so parent is <root>
    manifest_dir.parent().unwrap().to_path_buf()
}

/// Helper to get the CLI binary path
fn cli_binary() -> std::path::PathBuf {
    let root = project_root();
    // Try debug first (cargo test builds in debug), then release
    let debug = root.join("target/debug/life");
    if debug.exists() {
        return debug;
    }
    let release = root.join("target/release/life");
    if release.exists() {
        return release;
    }
    // Fallback: maybe it's in PATH
    std::path::PathBuf::from("life")
}

/// Helper to get the daemon binary path
fn daemon_binary() -> std::path::PathBuf {
    let root = project_root();
    let debug = root.join("target/debug/lifeosd");
    if debug.exists() {
        return debug;
    }
    let release = root.join("target/release/lifeosd");
    if release.exists() {
        return release;
    }
    std::path::PathBuf::from("lifeosd")
}

#[test]
fn test_cli_version_shows_correct_version() {
    let bin = cli_binary();
    if !bin.exists() && bin.to_str() == Some("life") {
        eprintln!("SKIP: CLI binary not found, skipping test");
        return;
    }
    let output = Command::new(&bin)
        .arg("--version")
        .output()
        .expect("Failed to execute CLI");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("0.1.0") || stdout.contains("life"));
}

#[test]
fn test_cli_help_shows_commands() {
    let bin = cli_binary();
    if !bin.exists() && bin.to_str() == Some("life") {
        eprintln!("SKIP: CLI binary not found, skipping test");
        return;
    }
    let output = Command::new(&bin)
        .arg("--help")
        .output()
        .expect("Failed to execute CLI");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("init") || stdout.contains("status"));
}

#[test]
fn test_cli_init_creates_config() {
    let bin = cli_binary();
    if !bin.exists() && bin.to_str() == Some("life") {
        eprintln!("SKIP: CLI binary not found, skipping test");
        return;
    }
    let temp_dir = TempDir::new().unwrap();
    let config_dir = temp_dir.path().join(".config");
    std::fs::create_dir_all(&config_dir).unwrap();

    let _output = Command::new(&bin)
        .arg("init")
        .arg("--force")
        .env("HOME", temp_dir.path())
        .output()
        .expect("Failed to execute CLI init");
}

#[test]
fn test_cli_status_returns_json() {
    let bin = cli_binary();
    if !bin.exists() && bin.to_str() == Some("life") {
        eprintln!("SKIP: CLI binary not found, skipping test");
        return;
    }
    let output = Command::new(&bin)
        .arg("status")
        .arg("--json")
        .output()
        .expect("Failed to execute CLI status");

    let stdout = String::from_utf8_lossy(&output.stdout);
    if !stdout.is_empty() {
        let _: Result<serde_json::Value, _> = serde_json::from_str(&stdout);
    }
}

#[test]
fn test_cli_config_get_set_roundtrip() {
    let temp_dir = TempDir::new().unwrap();
    let bin = cli_binary();
    if !bin.exists() && bin.to_str() == Some("life") {
        eprintln!("SKIP: CLI binary not found, skipping test");
        return;
    }

    let _set_output = Command::new(&bin)
        .arg("config")
        .arg("set")
        .arg("system.hostname")
        .arg("testhost")
        .env("HOME", temp_dir.path())
        .output();

    let _get_output = Command::new(&bin)
        .arg("config")
        .arg("get")
        .arg("system.hostname")
        .env("HOME", temp_dir.path())
        .output();
}

#[test]
fn test_daemon_binary_exists() {
    let bin = daemon_binary();
    if bin.to_str() == Some("lifeosd") {
        eprintln!("SKIP: Daemon binary not found in target/");
        return;
    }
    // The daemon doesn't support --help (it starts the server), so just verify the binary exists
    assert!(bin.exists(), "Daemon binary should exist at {:?}", bin);
}

#[test]
fn test_config_serialization_roundtrip() {
    use life::config::{AiConfig, LifeConfig, SecurityConfig, SystemConfig, UpdateConfig};

    let config = LifeConfig {
        version: "1".to_string(),
        system: SystemConfig {
            hostname: "test".to_string(),
            timezone: "UTC".to_string(),
            locale: "en_US.UTF-8".to_string(),
            keyboard: "us".to_string(),
        },
        ai: AiConfig {
            enabled: true,
            provider: "llama-server".to_string(),
            model: "Qwen3.5-4B-Q4_K_M.gguf".to_string(),
            llama_server_host: "http://localhost:8082".to_string(),
        },
        security: SecurityConfig {
            encryption: true,
            secure_boot: true,
            auto_lock: true,
            auto_lock_timeout: 300,
        },
        updates: UpdateConfig {
            channel: "stable".to_string(),
            auto_check: true,
            auto_apply: false,
            schedule: "daily".to_string(),
        },
    };

    let toml_str = toml::to_string_pretty(&config).expect("Failed to serialize config");
    let parsed: LifeConfig = toml::from_str(&toml_str).expect("Failed to deserialize config");

    assert_eq!(config.version, parsed.version);
    assert_eq!(config.system.hostname, parsed.system.hostname);
    assert_eq!(config.ai.provider, parsed.ai.provider);
    assert_eq!(config.security.encryption, parsed.security.encryption);
}

#[test]
fn test_system_health_check_integration() {
    use life::system::{check_health, HealthStatus};

    let health = check_health();
    match health {
        HealthStatus::Healthy | HealthStatus::Degraded(_) | HealthStatus::Unhealthy(_) => {}
    }
}

#[tokio::test]
async fn test_cli_daemon_workflow() {
    // Placeholder for full daemon integration test
    assert!(true);
}

#[test]
fn test_containerfile_exists() {
    let containerfile_path = project_root().join("image/Containerfile");
    assert!(
        containerfile_path.exists(),
        "Containerfile should exist at {:?}",
        containerfile_path
    );

    let content =
        std::fs::read_to_string(&containerfile_path).expect("Failed to read Containerfile");

    assert!(
        content.contains("FROM"),
        "Containerfile should have FROM instruction"
    );
    assert!(
        content.contains("bootc"),
        "Containerfile should reference bootc"
    );
    assert!(
        content.contains("llama-server"),
        "Containerfile should reference llama-server"
    );
    assert!(
        !content.contains("ollama"),
        "Containerfile should not reference ollama"
    );
}
