//! Screenshot at-rest encryption — AES-256-GCM-SIV with persisted key.
//!
//! THREAT MODEL — be honest about what this protects against:
//!
//! - YES: stolen laptop with the disk pulled out and read offline.
//!   The attacker sees only ciphertext; the key lives in
//!   `/var/lib/lifeos/secrets/screenshot.key` (mode 0600, parent dir 0700)
//!   and is itself protected by file permissions, but a cold-disk attacker
//!   reading a powered-off filesystem cannot bypass DAC enforcement on
//!   most layouts (LUKS-at-rest is the layered defence).
//! - YES: a backup of `/var/lib/lifeos/screenshots/` shipped to a cloud
//!   bucket or another machine — the ciphertext is useless without the
//!   key, which lives in a separate directory that should NOT be backed up.
//! - YES: a process running as a different UID, or a sandboxed payload
//!   (flatpak, systemd-run scope) that can read screenshot files but not
//!   the secrets directory.
//!
//! - NO: a process running as the same UID as the daemon. It can read
//!   both the screenshots and the key file. That threat already wins.
//! - NO: an online attacker with root or with the ability to call the
//!   daemon API. Decryption happens inside the daemon; anyone who can
//!   make the daemon decrypt for them defeats this layer.
//! - NO: side-channel attacks against the running daemon (memory dumps,
//!   /proc/pid/mem reads). Use OS-level mitigations for that.
//!
//! File layout: each encrypted file is `[nonce(12 bytes)][ciphertext+tag]`.
//! Standard AES-GCM-SIV — nonce-misuse-resistant, authenticated.
//! Filename convention: append `.enc` to the original name (e.g.
//! `lifeos_screenshot_20260422_143015.png.enc`).

use aes_gcm_siv::aead::{Aead, KeyInit};
use aes_gcm_siv::{Aes256GcmSiv, Nonce};
use anyhow::{Context, Result};
use rand::RngCore;
use std::fs;
use std::path::{Path, PathBuf};

const SECRETS_DIR: &str = "/var/lib/lifeos/secrets";
const SCREENSHOT_KEY_FILE: &str = "/var/lib/lifeos/secrets/screenshot.key";
const NONCE_LEN: usize = 12;
const KEY_LEN: usize = 32;

/// File extension appended to encrypted screenshots.
pub const ENC_EXTENSION: &str = "enc";

/// Load (or generate on first run) the AES-256-GCM-SIV key used to
/// encrypt screenshots at rest.
///
/// The key is generated once with 32 bytes from the OS RNG and persisted
/// at `/var/lib/lifeos/secrets/screenshot.key` (mode 0600). The parent
/// directory is created with mode 0700. Subsequent loads return the same
/// key, which is required so previously encrypted screenshots remain
/// readable.
///
/// Returns the raw 32-byte key. Callers should treat the bytes as
/// secret and avoid logging them.
pub fn load_or_create_screenshot_key() -> Result<Vec<u8>> {
    load_or_create_key_at(Path::new(SCREENSHOT_KEY_FILE), Path::new(SECRETS_DIR))
}

fn load_or_create_key_at(key_path: &Path, secrets_dir: &Path) -> Result<Vec<u8>> {
    if let Ok(existing) = fs::read(key_path) {
        if existing.len() == KEY_LEN {
            return Ok(existing);
        }
        log::warn!(
            "screenshot_crypt: existing key at {} has wrong length ({} bytes), regenerating",
            key_path.display(),
            existing.len()
        );
    }

    fs::create_dir_all(secrets_dir)
        .with_context(|| format!("creating secrets dir {}", secrets_dir.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(secrets_dir, fs::Permissions::from_mode(0o700));
    }

    let mut key = vec![0u8; KEY_LEN];
    rand::thread_rng().fill_bytes(&mut key);
    fs::write(key_path, &key)
        .with_context(|| format!("writing screenshot key {}", key_path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(key_path, fs::Permissions::from_mode(0o600));
    }
    log::info!(
        "screenshot_crypt: generated new screenshot key at {}",
        key_path.display()
    );
    Ok(key)
}

/// Encrypt `plaintext` with the persisted screenshot key and write the
/// result to `path` as `[nonce(12)][ciphertext+tag]`. The destination
/// file is created with mode 0600.
pub fn encrypt_to_file(path: &Path, plaintext: &[u8]) -> Result<()> {
    let key = load_or_create_screenshot_key()?;
    encrypt_to_file_with_key(path, plaintext, &key)
}

fn encrypt_to_file_with_key(path: &Path, plaintext: &[u8], key: &[u8]) -> Result<()> {
    let cipher = Aes256GcmSiv::new_from_slice(key)
        .map_err(|e| anyhow::anyhow!("invalid screenshot key length: {}", e))?;

    let mut nonce_bytes = [0u8; NONCE_LEN];
    rand::thread_rng().fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|e| anyhow::anyhow!("screenshot encryption failed: {}", e))?;

    let mut blob = Vec::with_capacity(NONCE_LEN + ciphertext.len());
    blob.extend_from_slice(&nonce_bytes);
    blob.extend_from_slice(&ciphertext);

    fs::write(path, &blob)
        .with_context(|| format!("writing encrypted screenshot {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

/// Decrypt the file at `path` and return the original plaintext bytes.
/// The file MUST be in the format produced by `encrypt_to_file`:
/// `[nonce(12)][ciphertext+tag]`. Authentication failure (tampering) or
/// any other cryptographic error returns an `Err`.
///
/// Currently consumed by the startup self-test below; this is the
/// designated read-path for future consumers (e.g. when
/// `sensory_pipeline.rs` is refactored to consume bytes via this fn so
/// the plaintext sidecar can be removed entirely).
fn decrypt_from_file(path: &Path) -> Result<Vec<u8>> {
    let key = load_or_create_screenshot_key()?;
    decrypt_from_file_with_key(path, &key)
}

/// Self-test invoked at daemon startup. Writes a small probe ciphertext
/// to a tempfile via the public `encrypt_to_file` path, decrypts it via
/// `decrypt_from_file`, and verifies the round-trip. This catches a
/// corrupt or unreadable key file before the first real screenshot
/// capture, ensures the secrets directory is writable, and exercises
/// both halves of the public API on every boot — keeping the surface
/// honest (no dead code).
pub fn self_test_at_startup() -> Result<()> {
    let key = load_or_create_screenshot_key()?;
    if key.len() != KEY_LEN {
        anyhow::bail!(
            "screenshot key has wrong length: {} (expected {})",
            key.len(),
            KEY_LEN
        );
    }
    let probe_path = std::env::temp_dir().join(format!(
        "lifeos-screenshot-crypt-selftest-{}.enc",
        std::process::id()
    ));
    let probe = b"lifeos-screenshot-crypt-self-test";
    encrypt_to_file(&probe_path, probe)?;
    let recovered = decrypt_from_file(&probe_path)?;
    let _ = fs::remove_file(&probe_path);
    if recovered != probe {
        anyhow::bail!("screenshot crypt self-test round-trip mismatch");
    }
    Ok(())
}

fn decrypt_from_file_with_key(path: &Path, key: &[u8]) -> Result<Vec<u8>> {
    let blob = fs::read(path)
        .with_context(|| format!("reading encrypted screenshot {}", path.display()))?;
    if blob.len() < NONCE_LEN + 16 {
        anyhow::bail!(
            "encrypted screenshot {} is too short ({} bytes)",
            path.display(),
            blob.len()
        );
    }

    let cipher = Aes256GcmSiv::new_from_slice(key)
        .map_err(|e| anyhow::anyhow!("invalid screenshot key length: {}", e))?;
    let (nonce_bytes, ciphertext) = blob.split_at(NONCE_LEN);
    let nonce = Nonce::from_slice(nonce_bytes);

    cipher.decrypt(nonce, ciphertext).map_err(|e| {
        anyhow::anyhow!(
            "screenshot decryption failed (tampered or wrong key): {}",
            e
        )
    })
}

/// Return the encrypted-file path for a given plaintext path by
/// appending the `.enc` extension. Filename-only — does not touch disk.
pub fn encrypted_path_for(plain: &Path) -> PathBuf {
    let mut as_str = plain.as_os_str().to_owned();
    as_str.push(".");
    as_str.push(ENC_EXTENSION);
    PathBuf::from(as_str)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    fn tempdir() -> PathBuf {
        let base = env::temp_dir().join(format!(
            "lifeos-screenshot-crypt-{}-{}",
            std::process::id(),
            rand::random::<u32>()
        ));
        fs::create_dir_all(&base).unwrap();
        base
    }

    #[test]
    fn round_trip_recovers_plaintext() {
        let dir = tempdir();
        let key_path = dir.join("k.key");
        let secrets_dir = dir.clone();
        let key = load_or_create_key_at(&key_path, &secrets_dir).unwrap();
        assert_eq!(key.len(), KEY_LEN);

        let plaintext = b"PNG-bytes-pretend-this-is-an-image".repeat(1000);
        let enc_path = dir.join("shot.png.enc");
        encrypt_to_file_with_key(&enc_path, &plaintext, &key).unwrap();

        let recovered = decrypt_from_file_with_key(&enc_path, &key).unwrap();
        assert_eq!(recovered, plaintext);
    }

    #[test]
    fn tamper_detection_fails_decrypt() {
        let dir = tempdir();
        let key_path = dir.join("k.key");
        let key = load_or_create_key_at(&key_path, &dir).unwrap();

        let plaintext = b"sensitive screen contents";
        let enc_path = dir.join("shot.png.enc");
        encrypt_to_file_with_key(&enc_path, plaintext, &key).unwrap();

        // Flip one byte deep inside the ciphertext (past the nonce).
        let mut blob = fs::read(&enc_path).unwrap();
        let target = NONCE_LEN + 5;
        blob[target] ^= 0xff;
        fs::write(&enc_path, &blob).unwrap();

        let result = decrypt_from_file_with_key(&enc_path, &key);
        assert!(
            result.is_err(),
            "tampered ciphertext must fail authentication"
        );
    }

    #[test]
    fn key_persists_across_loads() {
        let dir = tempdir();
        let key_path = dir.join("k.key");
        let first = load_or_create_key_at(&key_path, &dir).unwrap();
        let second = load_or_create_key_at(&key_path, &dir).unwrap();
        assert_eq!(first, second, "second load must return identical key");
    }

    #[test]
    fn wrong_key_fails_decrypt() {
        let dir = tempdir();
        let plaintext = b"top secret";
        let enc_path = dir.join("shot.png.enc");
        let key_a = load_or_create_key_at(&dir.join("a.key"), &dir).unwrap();
        // Force a different key by overwriting the file with random bytes.
        let mut key_b = vec![0u8; KEY_LEN];
        rand::thread_rng().fill_bytes(&mut key_b);
        assert_ne!(key_a, key_b);

        encrypt_to_file_with_key(&enc_path, plaintext, &key_a).unwrap();
        let result = decrypt_from_file_with_key(&enc_path, &key_b);
        assert!(result.is_err(), "decrypt with wrong key must fail");
    }

    #[test]
    fn encrypted_path_for_appends_enc() {
        let p = PathBuf::from("/var/lib/lifeos/screenshots/lifeos_screenshot_20260422_143015.png");
        let enc = encrypted_path_for(&p);
        assert_eq!(
            enc.to_string_lossy(),
            "/var/lib/lifeos/screenshots/lifeos_screenshot_20260422_143015.png.enc"
        );
    }

    #[test]
    fn short_blob_is_rejected() {
        let dir = tempdir();
        let key = load_or_create_key_at(&dir.join("k.key"), &dir).unwrap();
        let bad = dir.join("bad.enc");
        fs::write(&bad, b"too short").unwrap();
        assert!(decrypt_from_file_with_key(&bad, &key).is_err());
    }
}
