//! Multilingual Translation Engine (Fase X)
//!
//! Provides offline-first translation with multiple backends:
//! 1. Argos Translate (Python CLI, fully offline)
//! 2. LLM Router (local or cloud via llm_router)
//!
//! Also supports document translation, real-time audio subtitle
//! generation, and voice interpreter mode.

use log::{debug, info, warn};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::process::Command;

use crate::llm_router::{ChatMessage, LlmRouter, RouterRequest, TaskComplexity};

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

/// Configuration for the translation engine.
pub struct TranslationEngine {
    /// Path to a GGUF translation model (NLLB-200 or Madlad-400).
    /// When `None`, the engine relies on Argos Translate or the LLM router.
    model_path: Option<PathBuf>,
}

/// A request to translate text.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranslationRequest {
    /// The text to translate.
    pub text: String,
    /// Source language ISO 639-1 code. `None` means auto-detect.
    pub source_lang: Option<String>,
    /// Target language ISO 639-1 code (e.g. "es", "en", "fr").
    pub target_lang: String,
}

/// The result of a translation operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranslationResult {
    pub original: String,
    pub translated: String,
    /// Detected or provided source language code.
    pub source_lang: String,
    pub target_lang: String,
    /// Which backend produced the translation: "argos", "llm-router".
    pub method: String,
}

/// Real-time subtitle translator for audio streams.
pub struct RealtimeTranslator {
    source_lang: String,
    target_lang: String,
    active: Arc<AtomicBool>,
}

/// Event emitted when a subtitle is generated during real-time translation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubtitleGenerated {
    pub original: String,
    pub translated: String,
    pub source_lang: String,
    pub target_lang: String,
    pub timestamp_ms: u64,
}

// ---------------------------------------------------------------------------
// Language detection
// ---------------------------------------------------------------------------

/// Detect the language of the given text.
///
/// Uses a simple heuristic first (Spanish markers, common English words),
/// and falls back to the LLM router when the heuristic is inconclusive.
pub async fn detect_language(text: &str, router: Option<&LlmRouter>) -> Result<String, String> {
    // --- Heuristic pass ---
    if let Some(lang) = heuristic_detect(text) {
        debug!("translation: heuristic detected language '{lang}'");
        return Ok(lang);
    }

    // --- LLM fallback ---
    if let Some(router) = router {
        let prompt = format!(
            "What language is the following text written in? \
             Return ONLY the ISO 639-1 two-letter code (e.g. en, es, fr, de, pt). \
             Text: {text}"
        );
        let req = RouterRequest {
            messages: vec![ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(prompt),
            }],
            complexity: Some(TaskComplexity::Simple),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(4),
        };
        match router.chat(&req).await {
            Ok(resp) => {
                let code = resp.text.trim().to_lowercase();
                if code.len() == 2 && code.chars().all(|c| c.is_ascii_lowercase()) {
                    return Ok(code);
                }
                warn!("translation: LLM returned non-ISO code '{code}', defaulting to 'en'");
                return Ok("en".into());
            }
            Err(e) => {
                warn!("translation: LLM detect_language failed: {e}");
            }
        }
    }

    Err("Could not detect language: heuristic inconclusive and no LLM available".into())
}

/// Simple heuristic language detection.
fn heuristic_detect(text: &str) -> Option<String> {
    let lower = text.to_lowercase();

    // Spanish markers
    let spanish_markers = ['¿', 'ñ'];
    let spanish_accents = ['á', 'é', 'í', 'ó', 'ú'];
    let has_spanish_marker = spanish_markers.iter().any(|&c| lower.contains(c));
    let accent_count: usize = spanish_accents
        .iter()
        .map(|&c| lower.matches(c).count())
        .sum();
    if has_spanish_marker || accent_count >= 2 {
        return Some("es".into());
    }

    // Common English words (high-frequency function words)
    let english_words = [
        "the ", " is ", " are ", " have ", " has ", " was ", " were ",
    ];
    let english_hits: usize = english_words.iter().filter(|&&w| lower.contains(w)).count();
    if english_hits >= 2 {
        return Some("en".into());
    }

    // French markers
    let french_markers = ['ç', 'œ', 'ë', 'ï', 'ù', 'û', 'ê', 'î', 'ô', 'â'];
    let french_hits: usize = french_markers
        .iter()
        .filter(|&&c| lower.contains(c))
        .count();
    if french_hits >= 2 {
        return Some("fr".into());
    }

    // German markers
    let german_markers = ['ä', 'ö', 'ü', 'ß'];
    let german_hits: usize = german_markers
        .iter()
        .filter(|&&c| lower.contains(c))
        .count();
    if german_hits >= 2 {
        return Some("de".into());
    }

    // Portuguese markers
    let portuguese_markers = ['ã', 'õ', 'ç'];
    let portuguese_hits: usize = portuguese_markers
        .iter()
        .filter(|&&c| lower.contains(c))
        .count();
    if portuguese_hits >= 2 {
        return Some("pt".into());
    }

    None
}

// ---------------------------------------------------------------------------
// Translation
// ---------------------------------------------------------------------------

impl TranslationEngine {
    /// Create a new `TranslationEngine`.
    ///
    /// `model_path` is an optional path to a local GGUF translation model
    /// (e.g. NLLB-200 or Madlad-400). Pass `None` to rely on Argos or the
    /// LLM router exclusively.
    pub fn new(model_path: Option<PathBuf>) -> Self {
        Self { model_path }
    }

    /// Return the configured model path, if any.
    pub fn model_path(&self) -> Option<&Path> {
        self.model_path.as_deref()
    }

    /// Translate text using the best available backend.
    ///
    /// Backends are tried in priority order:
    /// 1. **Argos Translate** — fully offline Python CLI
    /// 2. **LLM Router** — local llama-server or cloud provider
    ///
    /// Returns an error only if every backend fails.
    pub async fn translate(
        &self,
        req: &TranslationRequest,
        router: Option<&LlmRouter>,
    ) -> Result<TranslationResult, String> {
        // Resolve source language
        let source_lang = match &req.source_lang {
            Some(lang) => lang.clone(),
            None => detect_language(&req.text, router)
                .await
                .unwrap_or_else(|_| "auto".into()),
        };

        // 1. Try Argos Translate
        match self
            .try_argos(&req.text, &source_lang, &req.target_lang)
            .await
        {
            Ok(translated) => {
                info!(
                    "translation: argos {} -> {} ({} chars)",
                    source_lang,
                    req.target_lang,
                    req.text.len()
                );
                return Ok(TranslationResult {
                    original: req.text.clone(),
                    translated,
                    source_lang,
                    target_lang: req.target_lang.clone(),
                    method: "argos".into(),
                });
            }
            Err(e) => {
                debug!("translation: argos unavailable: {e}");
            }
        }

        // 2. Try LLM Router
        if let Some(router) = router {
            match self
                .try_llm_router(router, &req.text, &source_lang, &req.target_lang)
                .await
            {
                Ok(translated) => {
                    info!(
                        "translation: llm-router {} -> {} ({} chars)",
                        source_lang,
                        req.target_lang,
                        req.text.len()
                    );
                    return Ok(TranslationResult {
                        original: req.text.clone(),
                        translated,
                        source_lang,
                        target_lang: req.target_lang.clone(),
                        method: "llm-router".into(),
                    });
                }
                Err(e) => {
                    debug!("translation: llm-router failed: {e}");
                }
            }
        }

        Err(format!(
            "All translation backends failed for {} -> {}",
            source_lang, req.target_lang
        ))
    }

    // --- Backend: Argos Translate ---

    async fn try_argos(&self, text: &str, source: &str, target: &str) -> Result<String, String> {
        let output = Command::new("argos-translate")
            .arg("--from")
            .arg(source)
            .arg("--to")
            .arg(target)
            .arg(text)
            .output()
            .await
            .map_err(|e| format!("Failed to spawn argos-translate: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("argos-translate exited with error: {stderr}"));
        }

        let translated = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if translated.is_empty() {
            return Err("argos-translate returned empty output".into());
        }
        Ok(translated)
    }

    // --- Backend: LLM Router ---

    async fn try_llm_router(
        &self,
        router: &LlmRouter,
        text: &str,
        source: &str,
        target: &str,
    ) -> Result<String, String> {
        let prompt = format!(
            "Translate the following text from {source} to {target}. \
             Return ONLY the translation, nothing else:\n{text}"
        );
        let req = RouterRequest {
            messages: vec![ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(prompt),
            }],
            complexity: Some(TaskComplexity::Medium),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(2048),
        };
        let resp = router
            .chat(&req)
            .await
            .map_err(|e| format!("LLM router error: {e}"))?;
        let translated = resp.text.trim().to_string();
        if translated.is_empty() {
            return Err("LLM router returned empty translation".into());
        }
        Ok(translated)
    }
}

// ---------------------------------------------------------------------------
// Document translation
// ---------------------------------------------------------------------------

/// Translate an entire file, writing the result alongside the original.
///
/// Supported file types: `.txt`, `.md`, `.pdf` (via `pdftotext`),
/// `.docx` (via `pandoc`).
///
/// The output file is written as `{stem}.{target_lang}.{ext}`, e.g.
/// `report.es.txt`. Returns the path to the translated file.
pub async fn translate_file(
    engine: &TranslationEngine,
    path: &str,
    target_lang: &str,
    router: Option<&LlmRouter>,
) -> Result<String, String> {
    let file_path = Path::new(path);
    if !file_path.exists() {
        return Err(format!("File not found: {path}"));
    }

    let ext = file_path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("txt")
        .to_lowercase();

    // 1. Extract text
    let text = extract_text(file_path, &ext).await?;

    // 2. Split into chunks (~1000 words each)
    let chunks = split_into_chunks(&text, 1000);

    // 3. Translate each chunk
    let mut translated_parts = Vec::with_capacity(chunks.len());
    for (i, chunk) in chunks.iter().enumerate() {
        debug!(
            "translation: translating chunk {}/{} ({} words)",
            i + 1,
            chunks.len(),
            chunk.split_whitespace().count()
        );
        let req = TranslationRequest {
            text: chunk.clone(),
            source_lang: None,
            target_lang: target_lang.to_string(),
        };
        let result = engine.translate(&req, router).await?;
        translated_parts.push(result.translated);
    }

    let translated_text = translated_parts.join("\n\n");

    // 4. Write output file
    let stem = file_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("output");
    let parent = file_path.parent().unwrap_or_else(|| Path::new("."));
    let output_path = parent.join(format!("{stem}.{target_lang}.{ext}"));

    tokio::fs::write(&output_path, &translated_text)
        .await
        .map_err(|e| format!("Failed to write output file: {e}"))?;

    let output_str = output_path.to_string_lossy().to_string();
    info!("translation: wrote translated file to {output_str}");
    Ok(output_str)
}

/// Extract plain text from a file based on its extension.
async fn extract_text(path: &Path, ext: &str) -> Result<String, String> {
    match ext {
        "txt" | "md" => tokio::fs::read_to_string(path)
            .await
            .map_err(|e| format!("Failed to read {}: {e}", path.display())),

        "pdf" => {
            let output = Command::new("pdftotext")
                .arg(path.as_os_str())
                .arg("-")
                .output()
                .await
                .map_err(|e| format!("Failed to run pdftotext: {e}"))?;
            if !output.status.success() {
                return Err(format!(
                    "pdftotext failed: {}",
                    String::from_utf8_lossy(&output.stderr)
                ));
            }
            Ok(String::from_utf8_lossy(&output.stdout).to_string())
        }

        "docx" => {
            let output = Command::new("pandoc")
                .arg(path.as_os_str())
                .arg("-t")
                .arg("plain")
                .output()
                .await
                .map_err(|e| format!("Failed to run pandoc: {e}"))?;
            if !output.status.success() {
                return Err(format!(
                    "pandoc failed: {}",
                    String::from_utf8_lossy(&output.stderr)
                ));
            }
            Ok(String::from_utf8_lossy(&output.stdout).to_string())
        }

        _ => Err(format!("Unsupported file type: .{ext}")),
    }
}

/// Split text into chunks of approximately `max_words` words each,
/// breaking at paragraph boundaries when possible.
fn split_into_chunks(text: &str, max_words: usize) -> Vec<String> {
    let paragraphs: Vec<&str> = text.split("\n\n").collect();
    let mut chunks = Vec::new();
    let mut current_chunk = String::new();
    let mut current_words = 0usize;

    for para in paragraphs {
        let para_words = para.split_whitespace().count();
        if current_words + para_words > max_words && !current_chunk.is_empty() {
            chunks.push(current_chunk.trim().to_string());
            current_chunk = String::new();
            current_words = 0;
        }
        if !current_chunk.is_empty() {
            current_chunk.push_str("\n\n");
        }
        current_chunk.push_str(para);
        current_words += para_words;
    }

    if !current_chunk.trim().is_empty() {
        chunks.push(current_chunk.trim().to_string());
    }

    // If no chunks were produced (e.g. empty text), return one empty chunk
    if chunks.is_empty() {
        chunks.push(String::new());
    }

    chunks
}

// ---------------------------------------------------------------------------
// Real-time audio subtitle translation
// ---------------------------------------------------------------------------

impl RealtimeTranslator {
    /// Create a new real-time translator.
    pub fn new(source_lang: &str, target_lang: &str) -> Self {
        Self {
            source_lang: source_lang.to_string(),
            target_lang: target_lang.to_string(),
            active: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Whether the translator is currently streaming.
    pub fn is_active(&self) -> bool {
        self.active.load(Ordering::Relaxed)
    }

    /// Get a clone of the active flag for use in other tasks (e.g. to stop).
    pub fn active_flag(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.active)
    }

    /// Start capturing audio, transcribing, and translating in real time.
    ///
    /// Steps for each 5-second chunk:
    /// 1. Record audio from `audio_source` via `pw-record`
    /// 2. Transcribe with Whisper
    /// 3. Translate the transcription
    /// 4. Emit `SubtitleGenerated` event
    ///
    /// This method runs until [`stop`] is called.
    pub async fn start_subtitle_stream(
        &mut self,
        audio_source: &str,
        engine: &TranslationEngine,
        router: Option<&LlmRouter>,
        event_tx: Option<&tokio::sync::broadcast::Sender<SubtitleGenerated>>,
    ) -> Result<(), String> {
        self.active.store(true, Ordering::Relaxed);
        info!(
            "translation: starting subtitle stream {} -> {} on '{}'",
            self.source_lang, self.target_lang, audio_source
        );

        let chunk_duration_secs = 5;
        let tmp_dir = std::env::temp_dir().join("lifeos-subtitles");
        tokio::fs::create_dir_all(&tmp_dir)
            .await
            .map_err(|e| format!("Failed to create temp dir: {e}"))?;

        let mut chunk_idx: u64 = 0;

        while self.active.load(Ordering::Relaxed) {
            let chunk_file = tmp_dir.join(format!("chunk_{chunk_idx}.wav"));

            // 1. Record audio chunk via PipeWire
            let record_status = Command::new("pw-record")
                .arg("--target")
                .arg(audio_source)
                .arg(chunk_file.as_os_str())
                .arg("--rate")
                .arg("16000")
                .arg("--channels")
                .arg("1")
                .kill_on_drop(true)
                .spawn()
                .map_err(|e| format!("Failed to start pw-record: {e}"))?;

            // Let it record for the chunk duration
            tokio::time::sleep(std::time::Duration::from_secs(chunk_duration_secs)).await;
            drop(record_status); // kills the pw-record process

            // Small delay to let the file flush
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;

            if !chunk_file.exists() {
                warn!("translation: chunk file missing, skipping");
                chunk_idx += 1;
                continue;
            }

            // 2. Transcribe with Whisper
            let transcript = match transcribe_audio(chunk_file.to_str().unwrap_or_default()).await {
                Ok(t) if !t.trim().is_empty() => t,
                Ok(_) => {
                    debug!("translation: empty transcript for chunk {chunk_idx}");
                    chunk_idx += 1;
                    continue;
                }
                Err(e) => {
                    warn!("translation: transcription failed for chunk {chunk_idx}: {e}");
                    chunk_idx += 1;
                    continue;
                }
            };

            // 3. Translate the transcript
            let req = TranslationRequest {
                text: transcript.clone(),
                source_lang: Some(self.source_lang.clone()),
                target_lang: self.target_lang.clone(),
            };

            match engine.translate(&req, router).await {
                Ok(result) => {
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as u64;

                    let event = SubtitleGenerated {
                        original: transcript,
                        translated: result.translated,
                        source_lang: result.source_lang,
                        target_lang: result.target_lang,
                        timestamp_ms: now,
                    };

                    info!("translation: subtitle chunk {chunk_idx}: {:?}", event);

                    // 4. Emit event
                    if let Some(tx) = event_tx {
                        let _ = tx.send(event);
                    }
                }
                Err(e) => {
                    warn!("translation: chunk {chunk_idx} translation failed: {e}");
                }
            }

            // Clean up chunk file
            let _ = tokio::fs::remove_file(&chunk_file).await;
            chunk_idx += 1;
        }

        info!("translation: subtitle stream stopped");
        Ok(())
    }

    /// Stop the real-time subtitle stream.
    pub fn stop(&self) {
        self.active.store(false, Ordering::Relaxed);
        info!("translation: stopping subtitle stream");
    }
}

// ---------------------------------------------------------------------------
// Voice interpreter mode
// ---------------------------------------------------------------------------

/// Interpret a voice recording: transcribe, translate, and synthesize.
///
/// Steps:
/// 1. Transcribe audio via Whisper (auto-detects language)
/// 2. Translate to `target_lang`
/// 3. Synthesize translated text via Piper TTS
/// 4. Return the path to the translated audio file
pub async fn interpret_voice(
    engine: &TranslationEngine,
    audio_path: &str,
    target_lang: &str,
    router: Option<&LlmRouter>,
) -> Result<String, String> {
    let audio = Path::new(audio_path);
    if !audio.exists() {
        return Err(format!("Audio file not found: {audio_path}"));
    }

    // 1. Transcribe
    let transcript = transcribe_audio(audio_path).await?;
    if transcript.trim().is_empty() {
        return Err("Transcription produced empty text".into());
    }

    // 2. Detect source language and translate
    let req = TranslationRequest {
        text: transcript,
        source_lang: None,
        target_lang: target_lang.to_string(),
    };
    let result = engine.translate(&req, router).await?;

    // 3. Synthesize via Piper TTS
    let parent = audio.parent().unwrap_or_else(|| Path::new("/tmp"));
    let stem = audio
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("interpreted");
    let output_path = parent.join(format!("{stem}.{target_lang}.wav"));

    let mut piper_status = Command::new("piper")
        .arg("--model")
        .arg(format!("{target_lang}-medium"))
        .arg("--output_file")
        .arg(output_path.as_os_str())
        .stdin(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to start piper: {e}"))?;

    // Write translated text to piper's stdin, then close it
    if let Some(mut stdin) = piper_status.stdin.take() {
        use tokio::io::AsyncWriteExt;
        stdin
            .write_all(result.translated.as_bytes())
            .await
            .map_err(|e| format!("Failed to write to piper stdin: {e}"))?;
        drop(stdin);
    }

    let piper_output = piper_status
        .wait_with_output()
        .await
        .map_err(|e| format!("Piper TTS failed: {e}"))?;

    if !piper_output.status.success() {
        return Err(format!(
            "Piper TTS exited with error: {}",
            String::from_utf8_lossy(&piper_output.stderr)
        ));
    }

    let output_str = output_path.to_string_lossy().to_string();
    info!("translation: interpreter wrote audio to {output_str}");
    Ok(output_str)
}

// ---------------------------------------------------------------------------
// Whisper transcription helper
// ---------------------------------------------------------------------------

/// Transcribe an audio file using Whisper (whisper-cpp CLI).
async fn transcribe_audio(audio_path: &str) -> Result<String, String> {
    // Try whisper-cpp first, then fall back to whisper CLI
    let output = Command::new("whisper-cpp")
        .arg("--model")
        .arg("/var/lib/lifeos/models/whisper-base.bin")
        .arg("--file")
        .arg(audio_path)
        .arg("--no-timestamps")
        .arg("--output-txt")
        .output()
        .await;

    match output {
        Ok(o) if o.status.success() => {
            let text = String::from_utf8_lossy(&o.stdout).trim().to_string();
            Ok(text)
        }
        _ => {
            // Fallback: try the Python whisper CLI
            let output = Command::new("whisper")
                .arg(audio_path)
                .arg("--model")
                .arg("base")
                .arg("--output_format")
                .arg("txt")
                .arg("--fp16")
                .arg("False")
                .output()
                .await
                .map_err(|e| format!("Failed to run whisper: {e}"))?;

            if !output.status.success() {
                return Err(format!(
                    "Whisper failed: {}",
                    String::from_utf8_lossy(&output.stderr)
                ));
            }

            Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_heuristic_detect_spanish() {
        assert_eq!(heuristic_detect("¿Cómo estás hoy?"), Some("es".into()));
        assert_eq!(heuristic_detect("El niño corrió rápido"), Some("es".into()));
    }

    #[test]
    fn test_heuristic_detect_english() {
        assert_eq!(
            heuristic_detect("the cat is on the table and they have food"),
            Some("en".into())
        );
    }

    #[test]
    fn test_heuristic_detect_french() {
        assert_eq!(
            heuristic_detect("le garçon mange des crêpes"),
            Some("fr".into())
        );
    }

    #[test]
    fn test_heuristic_detect_german() {
        assert_eq!(
            heuristic_detect("der Bär isst Würstchen mit Käse"),
            Some("de".into())
        );
    }

    #[test]
    fn test_heuristic_detect_unknown() {
        assert_eq!(heuristic_detect("xyz 123"), None);
    }

    #[test]
    fn test_split_into_chunks_small() {
        let text = "Hello world. This is a test.";
        let chunks = split_into_chunks(text, 1000);
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0], text);
    }

    #[test]
    fn test_split_into_chunks_large() {
        // Create text with ~20 words per paragraph, 5 paragraphs = 100 words
        let para = "word ".repeat(20).trim().to_string();
        let text = (0..5)
            .map(|_| para.as_str())
            .collect::<Vec<_>>()
            .join("\n\n");
        let chunks = split_into_chunks(&text, 50);
        // Should split into roughly 2 chunks (40 words, 40 words, 20 words -> depends on boundary)
        assert!(
            chunks.len() >= 2,
            "Expected at least 2 chunks, got {}",
            chunks.len()
        );
    }

    #[test]
    fn test_split_into_chunks_empty() {
        let chunks = split_into_chunks("", 1000);
        assert_eq!(chunks.len(), 1);
    }
}
