//! Speaker Identification — passive voice enrollment and recognition.
//!
//! Provides transparent speaker identification so Axi can greet users by name
//! and personalize responses. Works like Alexa Voice Profiles:
//!
//! 1. **Passive enrollment**: Speaker embeddings are extracted from every voice
//!    interaction and clustered. No explicit training required.
//! 2. **Progressive refinement**: Each interaction refines the speaker's
//!    voice profile, adapting to variations (tired, sick, happy, etc.).
//! 3. **Speaker matching**: Incoming audio is compared against stored profiles
//!    using cosine similarity on embedding vectors.
//!
//! Architecture (future):
//!   - WeSpeaker ONNX model for embedding extraction (~15MB ResNet34)
//!   - Stored in memory_plane (encrypted at rest)
//!   - Cosine similarity threshold for matching (>0.75 = match)
//!
//! Current implementation:
//!   - Profile management and matching logic ready
//!   - Embedding extraction uses a placeholder until WeSpeaker ONNX is integrated

use chrono::{DateTime, Utc};
use log::{debug, info, warn};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Minimum cosine similarity to consider a match.
const MATCH_THRESHOLD: f32 = 0.75;
/// Minimum interactions before Axi asks the speaker's name.
const ASK_NAME_AFTER_INTERACTIONS: u32 = 3;
/// Maximum number of embeddings to keep per speaker (rolling average).
const MAX_EMBEDDINGS_PER_SPEAKER: usize = 50;
/// Embedding dimension (WeSpeaker ResNet34 output).
const EMBEDDING_DIM: usize = 256;

/// A speaker profile with voice embeddings and metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpeakerProfile {
    pub id: String,
    pub name: Option<String>,
    pub created_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
    pub interaction_count: u32,
    /// Rolling collection of embeddings for this speaker.
    pub embeddings: Vec<Vec<f32>>,
    /// Averaged embedding vector (centroid) for fast matching.
    pub centroid: Vec<f32>,
}

impl SpeakerProfile {
    fn new(id: String, embedding: Vec<f32>) -> Self {
        let now = Utc::now();
        Self {
            id,
            name: None,
            created_at: now,
            last_seen_at: now,
            interaction_count: 1,
            centroid: embedding.clone(),
            embeddings: vec![embedding],
        }
    }

    /// Add a new embedding and update the centroid.
    fn add_embedding(&mut self, embedding: Vec<f32>) {
        self.last_seen_at = Utc::now();
        self.interaction_count += 1;

        self.embeddings.push(embedding);

        // Keep only the most recent embeddings
        if self.embeddings.len() > MAX_EMBEDDINGS_PER_SPEAKER {
            self.embeddings
                .drain(..self.embeddings.len() - MAX_EMBEDDINGS_PER_SPEAKER);
        }

        // Recompute centroid
        self.centroid = compute_centroid(&self.embeddings);
    }

    /// Whether Axi should ask for this speaker's name.
    pub fn should_ask_name(&self) -> bool {
        self.name.is_none() && self.interaction_count >= ASK_NAME_AFTER_INTERACTIONS
    }
}

/// Result of identifying a speaker from an audio segment.
#[derive(Debug, Clone)]
pub struct SpeakerMatch {
    pub profile_id: String,
    pub name: Option<String>,
    pub confidence: f32,
    pub is_new: bool,
    pub should_ask_name: bool,
}

/// Manages speaker profiles and identification.
pub struct SpeakerIdManager {
    profiles: HashMap<String, SpeakerProfile>,
    data_dir: PathBuf,
}

impl SpeakerIdManager {
    pub fn new(data_dir: PathBuf) -> Self {
        let mut manager = Self {
            profiles: HashMap::new(),
            data_dir,
        };
        manager.load_profiles();
        manager
    }

    /// Identify a speaker from an audio embedding.
    /// Returns the matched or newly created speaker profile.
    pub fn identify(&mut self, embedding: &[f32]) -> SpeakerMatch {
        // Find the best matching profile
        let mut best_match: Option<(&str, f32)> = None;

        for (id, profile) in &self.profiles {
            let similarity = cosine_similarity(embedding, &profile.centroid);
            if similarity > MATCH_THRESHOLD
                && (best_match.is_none() || similarity > best_match.unwrap().1)
            {
                best_match = Some((id, similarity));
            }
        }

        if let Some((id, confidence)) = best_match {
            let id = id.to_string();
            let profile = self.profiles.get_mut(&id).unwrap();
            profile.add_embedding(embedding.to_vec());
            let result = SpeakerMatch {
                profile_id: id.clone(),
                name: profile.name.clone(),
                confidence,
                is_new: false,
                should_ask_name: profile.should_ask_name(),
            };
            debug!(
                "Speaker matched: {} (confidence: {:.3})",
                profile.name.as_deref().unwrap_or(&id),
                confidence
            );
            self.save_profiles();
            result
        } else {
            // New speaker
            let id = format!("speaker_{}", uuid::Uuid::new_v4().simple());
            let profile = SpeakerProfile::new(id.clone(), embedding.to_vec());
            info!("New speaker detected: {id}");
            let should_ask = profile.should_ask_name();
            self.profiles.insert(id.clone(), profile);
            self.save_profiles();
            SpeakerMatch {
                profile_id: id,
                name: None,
                confidence: 1.0,
                is_new: true,
                should_ask_name: should_ask,
            }
        }
    }

    /// Set a speaker's name (after Axi asks or user tells).
    /// Returns true if the profile existed and was updated.
    pub fn set_name(&mut self, profile_id: &str, name: &str) -> bool {
        if let Some(profile) = self.profiles.get_mut(profile_id) {
            info!("Speaker {profile_id} identified as '{name}'");
            profile.name = Some(name.to_string());
            self.save_profiles();
            true
        } else {
            false
        }
    }

    /// Remove a speaker profile (user mis-identified it or wants to reset).
    /// Returns true if a profile was removed.
    pub fn delete_profile(&mut self, profile_id: &str) -> bool {
        if self.profiles.remove(profile_id).is_some() {
            info!("Speaker profile {profile_id} deleted");
            self.save_profiles();
            true
        } else {
            false
        }
    }

    /// Get all profiles.
    pub fn profiles(&self) -> Vec<&SpeakerProfile> {
        self.profiles.values().collect()
    }

    /// Get a profile by ID.
    pub fn get_profile(&self, id: &str) -> Option<&SpeakerProfile> {
        self.profiles.get(id)
    }

    /// Get profile count.
    pub fn profile_count(&self) -> usize {
        self.profiles.len()
    }

    // ── Persistence ──────────────────────────────────────────────────

    fn profiles_path(&self) -> PathBuf {
        self.data_dir.join("speaker_profiles.json")
    }

    fn load_profiles(&mut self) {
        let path = self.profiles_path();
        if !path.exists() {
            return;
        }
        match std::fs::read_to_string(&path) {
            Ok(data) => match serde_json::from_str::<HashMap<String, SpeakerProfile>>(&data) {
                Ok(profiles) => {
                    info!("Loaded {} speaker profiles", profiles.len());
                    self.profiles = profiles;
                }
                Err(e) => warn!("Failed to parse speaker profiles: {e}"),
            },
            Err(e) => warn!("Failed to read speaker profiles: {e}"),
        }
    }

    fn save_profiles(&self) {
        let path = self.profiles_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        match serde_json::to_string_pretty(&self.profiles) {
            Ok(data) => {
                if let Err(e) = std::fs::write(&path, data) {
                    warn!("Failed to save speaker profiles: {e}");
                }
                // Hearing audit C-13: 256-float voice embeddings are
                // biometric PII. Chmod 0o600 after every save so the
                // file stays owner-only even on a fresh write that
                // inherits the umask default.
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    if let Ok(md) = std::fs::metadata(&path) {
                        let mut perms = md.permissions();
                        perms.set_mode(0o600);
                        let _ = std::fs::set_permissions(&path, perms);
                    }
                }
            }
            Err(e) => warn!("Failed to serialize speaker profiles: {e}"),
        }
    }
}

// ── Embedding extraction ─────────────────────────────────────────────────

const SPEAKER_EMBEDDING_SCRIPT: &str = "/usr/local/bin/lifeos-speaker-embedding.py";
const WESPEAKER_MODEL_PATH: &str = "/usr/share/lifeos/models/wespeaker/voxceleb_resnet34_LM.onnx";

/// Extract a speaker embedding from a WAV audio file.
///
/// Uses the WeSpeaker ONNX model (ResNet34, 26.5MB) via a Python subprocess.
/// The script computes mel filterbank features and runs ONNX inference,
/// outputting a JSON array of 256 floats (the L2-normalized embedding).
///
/// Falls back to a lightweight audio-statistics embedding if the model
/// or Python dependencies are not available.
pub async fn extract_embedding(audio_path: &Path) -> anyhow::Result<Vec<f32>> {
    // Try WeSpeaker ONNX first
    if Path::new(SPEAKER_EMBEDDING_SCRIPT).exists() && Path::new(WESPEAKER_MODEL_PATH).exists() {
        match extract_embedding_wespeaker(audio_path).await {
            Ok(emb) => return Ok(emb),
            Err(e) => {
                warn!("WeSpeaker extraction failed, using fallback: {e}");
            }
        }
    }

    // Fallback: audio-statistics embedding
    extract_embedding_fallback(audio_path).await
}

/// Extract embedding using WeSpeaker ONNX via Python subprocess.
async fn extract_embedding_wespeaker(audio_path: &Path) -> anyhow::Result<Vec<f32>> {
    let output = tokio::process::Command::new("python3")
        .args([
            SPEAKER_EMBEDDING_SCRIPT,
            audio_path.to_string_lossy().as_ref(),
            "--model",
            WESPEAKER_MODEL_PATH,
        ])
        .output()
        .await?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("Speaker embedding script failed: {stderr}");
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let embedding: Vec<f32> = serde_json::from_str(stdout.trim())?;

    if embedding.len() != EMBEDDING_DIM {
        anyhow::bail!(
            "Expected {} dimensions, got {}",
            EMBEDDING_DIM,
            embedding.len()
        );
    }

    Ok(embedding)
}

/// Fallback embedding extraction using audio statistics.
/// Not production quality but allows the system to function without ONNX.
async fn extract_embedding_fallback(audio_path: &Path) -> anyhow::Result<Vec<f32>> {
    let data = tokio::fs::read(audio_path).await?;

    if data.len() < 44 {
        anyhow::bail!("Audio file too small for WAV header");
    }

    let pcm: Vec<i16> = data[44..]
        .chunks_exact(2)
        .map(|c| i16::from_le_bytes([c[0], c[1]]))
        .collect();

    if pcm.is_empty() {
        anyhow::bail!("No audio samples in file");
    }

    let mut embedding = vec![0.0f32; EMBEDDING_DIM];
    let chunk_size = pcm.len().max(EMBEDDING_DIM) / EMBEDDING_DIM;
    for (i, chunk) in pcm.chunks(chunk_size).enumerate() {
        if i >= EMBEDDING_DIM {
            break;
        }
        let rms: f32 =
            (chunk.iter().map(|&s| (s as f32).powi(2)).sum::<f32>() / chunk.len() as f32).sqrt();
        let zcr: f32 = chunk
            .windows(2)
            .filter(|w| (w[0] > 0) != (w[1] > 0))
            .count() as f32
            / chunk.len() as f32;
        embedding[i] = rms * 0.001 + zcr;
    }

    let norm: f32 = embedding.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 1e-8 {
        for x in &mut embedding {
            *x /= norm;
        }
    }

    Ok(embedding)
}

// ── Math utilities ───────────────────────────────────────────────────────

fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let dot: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let norm_a: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let norm_b: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm_a < 1e-8 || norm_b < 1e-8 {
        return 0.0;
    }
    dot / (norm_a * norm_b)
}

fn compute_centroid(embeddings: &[Vec<f32>]) -> Vec<f32> {
    if embeddings.is_empty() {
        return vec![];
    }
    let dim = embeddings[0].len();
    let mut centroid = vec![0.0f32; dim];
    for emb in embeddings {
        for (i, &val) in emb.iter().enumerate() {
            if i < dim {
                centroid[i] += val;
            }
        }
    }
    let n = embeddings.len() as f32;
    for x in &mut centroid {
        *x /= n;
    }
    // L2 normalize the centroid
    let norm: f32 = centroid.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 1e-8 {
        for x in &mut centroid {
            *x /= norm;
        }
    }
    centroid
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cosine_similarity_identical_vectors() {
        let a = vec![1.0, 0.0, 0.0];
        let b = vec![1.0, 0.0, 0.0];
        assert!((cosine_similarity(&a, &b) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn cosine_similarity_orthogonal_vectors() {
        let a = vec![1.0, 0.0, 0.0];
        let b = vec![0.0, 1.0, 0.0];
        assert!(cosine_similarity(&a, &b).abs() < 1e-6);
    }

    #[test]
    fn speaker_profile_creation_and_update() {
        let emb1 = vec![1.0, 0.0, 0.5];
        let emb2 = vec![0.9, 0.1, 0.5];
        let mut profile = SpeakerProfile::new("test".into(), emb1);
        assert_eq!(profile.interaction_count, 1);
        assert!(!profile.should_ask_name());

        profile.add_embedding(emb2);
        assert_eq!(profile.interaction_count, 2);
        assert_eq!(profile.embeddings.len(), 2);
    }

    #[test]
    fn manager_identifies_and_matches() {
        let dir = std::env::temp_dir().join(format!("lifeos-speaker-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut mgr = SpeakerIdManager::new(dir.clone());

        let emb1 = vec![1.0; EMBEDDING_DIM];
        let result1 = mgr.identify(&emb1);
        assert!(result1.is_new);
        assert_eq!(mgr.profile_count(), 1);

        // Same speaker should match
        let result2 = mgr.identify(&emb1);
        assert!(!result2.is_new);
        assert_eq!(result2.profile_id, result1.profile_id);

        // Very different speaker should be new
        let mut emb2 = vec![0.0; EMBEDDING_DIM];
        emb2[0] = -1.0;
        emb2[1] = 1.0;
        // Normalize
        let norm: f32 = emb2.iter().map(|x| x * x).sum::<f32>().sqrt();
        for x in &mut emb2 {
            *x /= norm;
        }
        let result3 = mgr.identify(&emb2);
        assert!(result3.is_new);
        assert_eq!(mgr.profile_count(), 2);

        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn ask_name_after_threshold() {
        let dir = std::env::temp_dir().join(format!("lifeos-speaker-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut mgr = SpeakerIdManager::new(dir.clone());

        let emb = vec![1.0; EMBEDDING_DIM];
        for i in 0..ASK_NAME_AFTER_INTERACTIONS {
            let result = mgr.identify(&emb);
            if i < ASK_NAME_AFTER_INTERACTIONS - 1 {
                assert!(!result.should_ask_name);
            }
        }
        let result = mgr.identify(&emb);
        assert!(result.should_ask_name);

        // Set name — should stop asking
        mgr.set_name(&result.profile_id, "Héctor");
        let result = mgr.identify(&emb);
        assert!(!result.should_ask_name);
        assert_eq!(result.name.as_deref(), Some("Héctor"));

        std::fs::remove_dir_all(dir).ok();
    }
}
