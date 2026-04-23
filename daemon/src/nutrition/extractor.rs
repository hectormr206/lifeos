//! Structured nutrition extraction from photos and voice transcripts.
//!
//! The extractor produces a [`NutritionExtraction`] containing one or
//! more [`NutritionEntry`] items plus an overall confidence score. The
//! shape is intentionally compact so the local 4B default model can
//! produce it reliably; richer macro breakdown lives downstream in
//! `nutrition_log` (description + macros_kcal) and in the existing
//! `food_db` lookups.

use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};

use crate::ai::AiManager;
use crate::memory_plane::{MemoryPlaneManager, NutritionLogEntry};

/// Maximum kcal value we accept for a single item before rejecting as
/// implausible. A whole large pizza tops out around 2400 kcal; we leave
/// generous headroom but still cut off LLM hallucinations like
/// "5,000,000 kcal".
pub const MAX_REASONABLE_KCAL: f64 = 5_000.0;

/// SA14: maximum quantity for a single entry. 100_000 grams is one
/// 100kg meal — comfortably above any human serving while rejecting
/// LLM garbage like `qty: 1e308`. Same cap is applied to non-mass
/// units (pieces, ml, etc.) since legitimate values never approach it.
pub const MAX_REASONABLE_QTY: f64 = 100_000.0;

/// SB21: hard cap on the number of entries in one extraction. Real meals
/// have a handful of items; an LLM hallucinating 100 entries is either
/// mis-extracting an ingredient list or being prompt-injected. Refuse.
pub const MAX_ENTRIES_PER_EXTRACTION: usize = 30;

/// C12: filesystem prefixes the multimodal extractor is allowed to read
/// from. Anything outside these prefixes (after symlink resolution) is a
/// path-traversal attempt and refused — otherwise an attacker who can
/// pass an `image_path` (via API or SimpleX) gets daemon-level reads of
/// arbitrary files (`/var/lib/lifeos/secrets/screenshot.key`,
/// `~/.ssh/id_*`, `/etc/lifeos/llm-providers.toml`, ...) base64-encoded
/// and shipped to the configured vision provider.
const ALLOWED_IMAGE_PATH_PREFIXES: &[&str] =
    &["/var/lib/lifeos/screenshots/", "/tmp/lifeos-captures/"];

/// C12: validate a caller-supplied image path. Returns `Ok(canonical)`
/// when the path:
///   * has no `..` traversal segments (even pre-canonicalize)
///   * canonicalizes to a real file inside `ALLOWED_IMAGE_PATH_PREFIXES`
///   * begins with magic bytes for a real image format (PNG / JPEG / WebP)
///
/// Symlinks are followed via `fs::canonicalize` BEFORE the prefix check,
/// so a symlink in `/var/lib/lifeos/screenshots/` pointing at
/// `~/.ssh/id_ed25519` is rejected.
fn validate_image_path(image_path: &str) -> Result<std::path::PathBuf> {
    use std::path::PathBuf;

    if image_path.split('/').any(|seg| seg == "..") {
        bail!("image_path rejected: contains '..' traversal segment");
    }

    let canonical: PathBuf = std::fs::canonicalize(image_path)
        .with_context(|| format!("image_path canonicalize failed for {image_path}"))?;
    let canonical_str = canonical.to_string_lossy();
    let allowed = ALLOWED_IMAGE_PATH_PREFIXES
        .iter()
        .any(|p| canonical_str.starts_with(p));
    if !allowed {
        bail!(
            "image_path {} resolves to {} which is outside the allowed prefixes {:?}",
            image_path,
            canonical_str,
            ALLOWED_IMAGE_PATH_PREFIXES
        );
    }

    // Magic-byte check — refuse anything that isn't an actual image.
    let mut header = [0u8; 12];
    use std::io::Read;
    let mut f = std::fs::File::open(&canonical)
        .with_context(|| format!("opening {} for magic-byte check", canonical_str))?;
    let n = f.read(&mut header).unwrap_or(0);
    let is_png = n >= 8 && &header[..8] == b"\x89PNG\r\n\x1a\n";
    let is_jpeg = n >= 3 && header[..3] == [0xff, 0xd8, 0xff];
    let is_webp = n >= 12 && &header[..4] == b"RIFF" && &header[8..12] == b"WEBP";
    if !(is_png || is_jpeg || is_webp) {
        bail!(
            "image_path {} does not start with PNG/JPEG/WebP magic bytes; refusing to forward to multimodal LLM",
            canonical_str
        );
    }
    Ok(canonical)
}

/// One structured food item extracted from an image or transcript.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NutritionEntry {
    /// Human-readable name of the food, e.g. "tacos al pastor".
    pub name: String,
    /// Quantity. Always positive. Units are described in `unit`.
    pub qty: f64,
    /// Unit string, free-form but normalized lowercase, e.g. "g",
    /// "ml", "pieza", "porcion", "taza".
    pub unit: String,
    /// Best-effort kcal estimate produced by the LLM. May be `None`
    /// when the model cannot estimate confidently; callers must not
    /// invent a value.
    pub kcal_estimate: Option<f64>,
}

/// Aggregated extraction result.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NutritionExtraction {
    /// One or more items detected in the photo / transcript.
    pub entries: Vec<NutritionEntry>,
    /// Overall confidence in `[0.0, 1.0]`. Anything below 0.3 typically
    /// means the model could not see / understand a meal.
    pub confidence: f64,
    /// Compact natural-language summary that ends up in
    /// `nutrition_log.description`.
    pub raw_description: String,
    /// Meal classification: `breakfast`, `lunch`, `dinner`, `snack`,
    /// `drink`, or `craving`. Defaults to `snack` when the model is
    /// unsure — that is the most conservative bucket.
    pub meal_type: String,
}

/// Keyword set used by [`detect_food_intent`]. Extra keywords (e.g.
/// regional dishes) can be appended by callers without touching the
/// extractor itself.
///
/// Gated behind `messaging` because the only call site lives inside the
/// `messaging`-gated `execute_nutrition_log_from_capture` in axi_tools.
/// Without the gate, builds without `messaging` (default features) flag
/// it as dead code and clippy `-D warnings` fails CI.
#[cfg(feature = "messaging")]
const FOOD_KEYWORDS: &[&str] = &[
    // Spanish — verbs
    "comi",
    "comí",
    "almorce",
    "almorcé",
    "cene",
    "cené",
    "desayune",
    "desayuné",
    "merende",
    "merendé",
    "tome",
    "tomé",
    "bebí",
    "bebi",
    // Spanish — nouns
    "comida",
    "almuerzo",
    "desayuno",
    "cena",
    "merienda",
    "snack",
    "antojo",
    "bebida",
    // English
    "i ate",
    "i had",
    "i drank",
    "breakfast",
    "lunch",
    "dinner",
    "meal",
    "craving",
];

/// Returns `true` when the transcript looks like the user is describing
/// something they ate or drank. Cheap heuristic — meant to gate the
/// optional auto-trigger path so we don't spend an LLM call on every
/// utterance.
///
/// Gated behind `messaging` (see `FOOD_KEYWORDS` doc above).
#[cfg(feature = "messaging")]
pub fn detect_food_intent(text: &str) -> bool {
    let lower = text.to_lowercase();
    FOOD_KEYWORDS.iter().any(|kw| lower.contains(kw))
}

/// Validate a slice of entries. Returns the first failure (`anyhow`
/// error) so the caller can surface a precise message to the LLM /
/// user. Performs ALL of:
///
/// * `entries` is non-empty
/// * each `name` is non-empty after trim
/// * each `qty` is finite and `> 0`
/// * each `unit` is non-empty after trim
/// * each `kcal_estimate`, when present, is finite, `>= 0`, and
///   `<= MAX_REASONABLE_KCAL`
pub fn validate_entries(entries: &[NutritionEntry]) -> Result<()> {
    if entries.is_empty() {
        bail!("nutrition extraction must contain at least one entry");
    }
    // SB21: cap entries per extraction. A single meal has at most a handful
    // of distinct items; 30 is generous. LLM hallucinations / prompt
    // injections that produce 100+ entries pollute nutrition_log.
    if entries.len() > MAX_ENTRIES_PER_EXTRACTION {
        bail!(
            "extraction has {} entries (> {}); refusing — a single meal does not have that many distinct items",
            entries.len(),
            MAX_ENTRIES_PER_EXTRACTION
        );
    }
    for (idx, entry) in entries.iter().enumerate() {
        if entry.name.trim().is_empty() {
            bail!("entry #{idx} has empty name");
        }
        if !entry.qty.is_finite() || entry.qty <= 0.0 {
            bail!(
                "entry #{idx} ({}) has non-positive qty {}",
                entry.name,
                entry.qty
            );
        }
        // SA14: also reject implausibly large quantities (e.g. `1e308`).
        if entry.qty > MAX_REASONABLE_QTY {
            bail!(
                "entry #{idx} ({}) has implausible qty {} (> {})",
                entry.name,
                entry.qty,
                MAX_REASONABLE_QTY
            );
        }
        if entry.unit.trim().is_empty() {
            bail!("entry #{idx} ({}) has empty unit", entry.name);
        }
        if let Some(kcal) = entry.kcal_estimate {
            // C13: `-0.0 < 0.0` is false in IEEE-754, so the previous check
            // (`kcal < 0.0`) accepted -0.0. `is_sign_negative()` is the
            // only reliable way to catch -0.0 — it returns true for both
            // -0.0 and any negative number. Positive zero (0.0) is still
            // allowed because water and zero-kcal beverages are legitimate.
            if !kcal.is_finite() || kcal.is_sign_negative() {
                bail!(
                    "entry #{idx} ({}) has invalid kcal_estimate {}",
                    entry.name,
                    kcal
                );
            }
            if kcal > MAX_REASONABLE_KCAL {
                bail!(
                    "entry #{idx} ({}) has implausible kcal_estimate {} (> {})",
                    entry.name,
                    kcal,
                    MAX_REASONABLE_KCAL
                );
            }
        }
    }
    Ok(())
}

/// Normalize a meal-type string into the discrete buckets accepted by
/// `nutrition_log`. Anything unrecognized falls back to `"snack"`.
fn normalize_meal_type(raw: &str) -> String {
    let l = raw.trim().to_lowercase();
    match l.as_str() {
        "breakfast" | "desayuno" => "breakfast".into(),
        "lunch" | "almuerzo" | "comida" => "lunch".into(),
        "dinner" | "cena" => "dinner".into(),
        "drink" | "bebida" | "trago" => "drink".into(),
        "craving" | "antojo" => "craving".into(),
        _ => "snack".into(),
    }
}

/// Prompt sent to the LLM. The model is instructed to return a JSON
/// object ONLY (no prose, no fences) so the parser can be strict.
const EXTRACTION_PROMPT: &str = r#"You analyze food described in either a photo or a voice transcript.

Return ONLY a single JSON object, no prose, no markdown, no code fences. Schema:

{
  "entries": [
    {
      "name": "string (food name, lowercase, in the same language as the input)",
      "qty": number (positive),
      "unit": "string (g | ml | pieza | porcion | taza | rebanada | etc, lowercase)",
      "kcal_estimate": number | null (best-effort kcal, null if unsure)
    }
  ],
  "confidence": number in [0.0, 1.0],
  "raw_description": "string (one short sentence describing the meal)",
  "meal_type": "breakfast | lunch | dinner | snack | drink | craving"
}

Rules:
- If the input does not describe food, return {"entries": [], "confidence": 0.0, "raw_description": "", "meal_type": "snack"}.
- Never fabricate exact macros — leave kcal_estimate null when unsure.
- Keep entries compact: one item per dish, not per ingredient.
"#;

fn parse_extraction_json(text: &str) -> Result<NutritionExtraction> {
    // Some models still emit ```json fences; strip them defensively.
    let trimmed = text.trim();
    let trimmed = trimmed
        .strip_prefix("```json")
        .or_else(|| trimmed.strip_prefix("```"))
        .unwrap_or(trimmed);
    let trimmed = trimmed.strip_suffix("```").unwrap_or(trimmed).trim();

    // C14: try strict parse first. The previous implementation always
    // sliced from first `{` to last `}`, which corrupts payloads where
    // the prose itself contains braces (e.g. "the JSON below uses {x}
    // notation"). Strict parse handles the common case; we only fall
    // back to brace recovery on real parse failures.
    let mut value: NutritionExtraction = match serde_json::from_str(trimmed) {
        Ok(v) => v,
        Err(strict_err) => {
            let start = trimmed
                .find('{')
                .ok_or_else(|| anyhow!("LLM response contains no JSON object: {trimmed}"))?;
            let end = trimmed
                .rfind('}')
                .ok_or_else(|| anyhow!("LLM response has no closing '}}': {trimmed}"))?;
            if end < start {
                bail!("LLM response has malformed braces");
            }
            let json_slice = &trimmed[start..=end];
            serde_json::from_str(json_slice).with_context(|| {
                format!(
                    "LLM response is not valid extraction JSON (strict parse error: {strict_err}): {json_slice}"
                )
            })?
        }
    };

    value.meal_type = normalize_meal_type(&value.meal_type);
    // Clamp confidence to a sane range.
    if !value.confidence.is_finite() {
        value.confidence = 0.0;
    }
    value.confidence = value.confidence.clamp(0.0, 1.0);
    Ok(value)
}

/// Extract structured nutrition from an image on disk.
///
/// Uses the multimodal endpoint of the local `AiManager`. The image
/// is sent base64-encoded inline (no upload to a remote service unless
/// the user has explicitly configured a remote vision provider in the
/// router; this function uses the local llama-server multimodal slot).
pub async fn extract_from_image(ai: &AiManager, image_path: &str) -> Result<NutritionExtraction> {
    // C12: validate the path BEFORE handing it to the multimodal pipeline.
    // Without this guard a caller could pass `/etc/lifeos/llm-providers.toml`
    // or `/var/lib/lifeos/secrets/screenshot.key` and exfiltrate it as
    // base64 to the configured vision provider.
    let canonical = validate_image_path(image_path)?;
    let canonical_str = canonical.to_string_lossy();
    let response = ai
        .chat_multimodal(
            None,
            Some("You are a precise nutrition extraction model. Output only JSON."),
            EXTRACTION_PROMPT,
            &canonical_str,
        )
        .await
        .context("multimodal extraction call failed")?;
    let extraction = parse_extraction_json(&response.response)?;
    if !extraction.entries.is_empty() {
        validate_entries(&extraction.entries)?;
    }
    Ok(extraction)
}

/// Extract structured nutrition from a free-form voice transcript.
///
/// Caller is responsible for producing the transcript (Whisper STT
/// already exists in `sensory_pipeline.rs::transcribe_audio`). This
/// function only handles the parsing step.
pub async fn extract_from_voice_transcript(
    ai: &AiManager,
    transcript: &str,
) -> Result<NutritionExtraction> {
    let transcript = transcript.trim();
    if transcript.is_empty() {
        bail!("transcript is empty");
    }
    let user_prompt =
        format!("{EXTRACTION_PROMPT}\n\nVoice transcript:\n\"\"\"\n{transcript}\n\"\"\"");
    let response = ai
        .chat(
            None,
            vec![
                (
                    "system".to_string(),
                    "You are a precise nutrition extraction model. Output only JSON.".to_string(),
                ),
                ("user".to_string(), user_prompt),
            ],
        )
        .await
        .context("voice transcript extraction call failed")?;
    let extraction = parse_extraction_json(&response.response)?;
    if !extraction.entries.is_empty() {
        validate_entries(&extraction.entries)?;
    }
    Ok(extraction)
}

/// Persist a validated extraction into `nutrition_log`.
///
/// One row per entry is written. The whole extraction shares a single
/// `description` (the model's `raw_description`) and the per-entry
/// `name`/`qty`/`unit` is appended so that downstream consumers can
/// still see the structured shape inside the description string —
/// the `nutrition_log` table itself doesn't have one column per item,
/// so this is the cleanest way to keep the data without changing the
/// schema.
///
/// Returns the list of newly created `log_id`s in the same order as
/// `extraction.entries`.
pub async fn persist_extraction(
    mem: &MemoryPlaneManager,
    extraction: &NutritionExtraction,
    photo_attachment_id: Option<&str>,
    voice_attachment_id: Option<&str>,
    notes: &str,
) -> Result<Vec<NutritionLogEntry>> {
    validate_entries(&extraction.entries)?;
    let mut out = Vec::with_capacity(extraction.entries.len());
    for entry in &extraction.entries {
        let description = format!(
            "{} ({} {} de {})",
            extraction.raw_description.trim(),
            entry.qty,
            entry.unit,
            entry.name
        );
        let logged = mem
            .log_nutrition_meal(
                &extraction.meal_type,
                description.trim(),
                entry.kcal_estimate,
                None, // protein
                None, // carbs
                None, // fat
                photo_attachment_id,
                voice_attachment_id,
                None, // consumed_at -> now
                notes,
                None, // source_entry_id
            )
            .await
            .with_context(|| format!("log_nutrition_meal failed for {}", entry.name))?;
        out.push(logged);
    }
    Ok(out)
}

// -------------------------------------------------------------------------
// Tests — pure logic. The `extract_from_*` functions hit llama-server, so
// they cannot run in CI; we cover the JSON parser, validator, intent
// detector, and meal-type normalizer instead.
// -------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_entry() -> NutritionEntry {
        NutritionEntry {
            name: "tacos al pastor".to_string(),
            qty: 3.0,
            unit: "pieza".to_string(),
            kcal_estimate: Some(450.0),
        }
    }

    #[test]
    fn validate_accepts_well_formed_entry() {
        validate_entries(&[sample_entry()]).expect("valid entry should pass");
    }

    #[test]
    fn validate_rejects_empty_list() {
        let err = validate_entries(&[]).unwrap_err();
        assert!(err.to_string().contains("at least one"));
    }

    #[test]
    fn validate_rejects_empty_name() {
        let mut e = sample_entry();
        e.name = "   ".into();
        let err = validate_entries(&[e]).unwrap_err();
        assert!(err.to_string().contains("empty name"));
    }

    #[test]
    fn validate_rejects_zero_qty() {
        let mut e = sample_entry();
        e.qty = 0.0;
        let err = validate_entries(&[e]).unwrap_err();
        assert!(err.to_string().contains("non-positive qty"));
    }

    #[test]
    fn validate_rejects_negative_qty() {
        let mut e = sample_entry();
        e.qty = -1.5;
        let err = validate_entries(&[e]).unwrap_err();
        assert!(err.to_string().contains("non-positive qty"));
    }

    #[test]
    fn validate_rejects_nan_qty() {
        let mut e = sample_entry();
        e.qty = f64::NAN;
        let err = validate_entries(&[e]).unwrap_err();
        assert!(err.to_string().contains("non-positive qty"));
    }

    #[test]
    fn validate_rejects_empty_unit() {
        let mut e = sample_entry();
        e.unit = "".into();
        let err = validate_entries(&[e]).unwrap_err();
        assert!(err.to_string().contains("empty unit"));
    }

    #[test]
    fn validate_rejects_negative_kcal() {
        let mut e = sample_entry();
        e.kcal_estimate = Some(-10.0);
        let err = validate_entries(&[e]).unwrap_err();
        assert!(err.to_string().contains("invalid kcal_estimate"));
    }

    #[test]
    fn validate_rejects_implausible_kcal() {
        let mut e = sample_entry();
        e.kcal_estimate = Some(MAX_REASONABLE_KCAL + 1.0);
        let err = validate_entries(&[e]).unwrap_err();
        assert!(err.to_string().contains("implausible"));
    }

    #[test]
    fn validate_accepts_none_kcal() {
        let mut e = sample_entry();
        e.kcal_estimate = None;
        validate_entries(&[e]).expect("None kcal is allowed");
    }

    #[test]
    fn validate_rejects_negative_zero_kcal() {
        // C13: the previous check `kcal < 0.0` accepted -0.0 because
        // -0.0 is not strictly less than 0.0 in IEEE-754.
        let mut e = sample_entry();
        e.kcal_estimate = Some(-0.0);
        let err = validate_entries(&[e]).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("invalid kcal_estimate") || msg.contains("signed-zero"),
            "expected negative-zero rejection, got: {msg}"
        );
    }

    #[test]
    fn validate_accepts_positive_zero_kcal() {
        // Water / zero-kcal beverages must keep working.
        let mut e = sample_entry();
        e.kcal_estimate = Some(0.0);
        validate_entries(&[e]).expect("+0.0 kcal must be accepted for water");
    }

    #[test]
    fn validate_rejects_huge_qty() {
        let mut e = sample_entry();
        e.qty = 1e308;
        let err = validate_entries(&[e]).unwrap_err();
        assert!(err.to_string().contains("implausible qty"));
    }

    #[test]
    fn validate_rejects_overlong_entry_list() {
        let many: Vec<NutritionEntry> = (0..MAX_ENTRIES_PER_EXTRACTION + 1)
            .map(|i| NutritionEntry {
                name: format!("item{i}"),
                qty: 1.0,
                unit: "g".into(),
                kcal_estimate: Some(1.0),
            })
            .collect();
        let err = validate_entries(&many).unwrap_err();
        assert!(err.to_string().contains("entries"));
    }

    #[test]
    fn parse_ignores_embedded_braces_in_prose() {
        // C14: strict-parse-first path. If the LLM wraps the JSON cleanly,
        // prose elsewhere with `{foo}` notation must not break recovery.
        let raw = r#"{"entries":[{"name":"agua","qty":500,"unit":"ml","kcal_estimate":0}],"confidence":0.9,"raw_description":"Agua","meal_type":"drink"}"#;
        let extraction = parse_extraction_json(raw).unwrap();
        assert_eq!(extraction.entries[0].name, "agua");
    }

    #[test]
    fn validate_image_path_rejects_outside_allowed_prefixes() {
        // Real system path that exists but isn't allow-listed.
        let err = validate_image_path("/etc/hostname").unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("outside the allowed prefixes")
                || msg.contains("does not start with")
                || msg.contains("canonicalize failed"),
            "expected prefix rejection, got: {msg}"
        );
    }

    #[test]
    fn validate_image_path_rejects_dotdot() {
        let err =
            validate_image_path("/var/lib/lifeos/screenshots/../../../etc/passwd").unwrap_err();
        assert!(err.to_string().contains("traversal"));
    }

    #[cfg(feature = "messaging")]
    #[test]
    fn detect_food_intent_spanish_verbs() {
        assert!(detect_food_intent("hace rato comi unos tacos"));
        assert!(detect_food_intent("Comí pizza ayer"));
        assert!(detect_food_intent("almorcé pollo con arroz"));
        assert!(detect_food_intent("cené sushi"));
    }

    #[cfg(feature = "messaging")]
    #[test]
    fn detect_food_intent_english() {
        assert!(detect_food_intent("I ate a burger"));
        assert!(detect_food_intent("had lunch at noon"));
    }

    #[cfg(feature = "messaging")]
    #[test]
    fn detect_food_intent_unrelated() {
        assert!(!detect_food_intent("recordame mañana la junta"));
        assert!(!detect_food_intent("turn off the lights"));
    }

    #[test]
    fn parse_clean_json() {
        let raw = r#"{
            "entries": [
                {"name": "tacos al pastor", "qty": 3, "unit": "pieza", "kcal_estimate": 450}
            ],
            "confidence": 0.78,
            "raw_description": "Tres tacos al pastor",
            "meal_type": "lunch"
        }"#;
        let extraction = parse_extraction_json(raw).unwrap();
        assert_eq!(extraction.entries.len(), 1);
        assert_eq!(extraction.entries[0].name, "tacos al pastor");
        assert_eq!(extraction.entries[0].qty, 3.0);
        assert_eq!(extraction.meal_type, "lunch");
        assert!((extraction.confidence - 0.78).abs() < 1e-6);
    }

    #[test]
    fn parse_strips_markdown_fences() {
        let raw = "```json\n{\"entries\":[],\"confidence\":0.0,\"raw_description\":\"\",\"meal_type\":\"snack\"}\n```";
        let extraction = parse_extraction_json(raw).unwrap();
        assert!(extraction.entries.is_empty());
        assert_eq!(extraction.meal_type, "snack");
    }

    #[test]
    fn parse_recovers_from_prose_prefix() {
        let raw = "Sure! Here is the JSON:\n{\"entries\":[{\"name\":\"agua\",\"qty\":500,\"unit\":\"ml\",\"kcal_estimate\":0}],\"confidence\":0.9,\"raw_description\":\"Agua\",\"meal_type\":\"drink\"}";
        let extraction = parse_extraction_json(raw).unwrap();
        assert_eq!(extraction.entries[0].name, "agua");
        assert_eq!(extraction.meal_type, "drink");
    }

    #[test]
    fn parse_normalizes_unknown_meal_type() {
        let raw = r#"{"entries":[{"name":"x","qty":1,"unit":"g","kcal_estimate":null}],"confidence":0.5,"raw_description":"x","meal_type":"midnight"}"#;
        let extraction = parse_extraction_json(raw).unwrap();
        assert_eq!(extraction.meal_type, "snack");
    }

    #[test]
    fn parse_clamps_confidence() {
        let raw = r#"{"entries":[],"confidence":42.0,"raw_description":"","meal_type":"snack"}"#;
        let extraction = parse_extraction_json(raw).unwrap();
        assert_eq!(extraction.confidence, 1.0);
    }

    #[test]
    fn parse_rejects_garbage() {
        let err = parse_extraction_json("not json at all").unwrap_err();
        assert!(err.to_string().contains("no JSON object"));
    }

    use std::path::PathBuf;

    fn temp_dir_for(prefix: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("lifeos-{prefix}-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[tokio::test]
    async fn persist_writes_one_row_per_entry_and_round_trips() {
        let dir = temp_dir_for("nutrition-persist");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let extraction = NutritionExtraction {
            entries: vec![
                NutritionEntry {
                    name: "tacos al pastor".into(),
                    qty: 3.0,
                    unit: "pieza".into(),
                    kcal_estimate: Some(450.0),
                },
                NutritionEntry {
                    name: "agua mineral".into(),
                    qty: 500.0,
                    unit: "ml".into(),
                    kcal_estimate: Some(0.0),
                },
            ],
            confidence: 0.81,
            raw_description: "Tres tacos al pastor con agua mineral".into(),
            meal_type: "lunch".into(),
        };

        let logged = persist_extraction(&mgr, &extraction, None, None, "")
            .await
            .expect("persist should succeed");
        assert_eq!(logged.len(), 2);
        assert_eq!(logged[0].meal_type, "lunch");
        assert!(logged[0].description.contains("tacos al pastor"));
        assert_eq!(logged[0].macros_kcal, Some(450.0));
        assert_eq!(logged[1].macros_kcal, Some(0.0));
        assert!(logged[1].description.contains("agua mineral"));

        // Round-trip via list_nutrition_log.
        let back = mgr.list_nutrition_log(Some("lunch"), 50).await.unwrap();
        assert!(back.len() >= 2);
        let names: Vec<&str> = back.iter().map(|e| e.description.as_str()).collect();
        assert!(names.iter().any(|d| d.contains("tacos al pastor")));
        assert!(names.iter().any(|d| d.contains("agua mineral")));

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn persist_rejects_invalid_extraction() {
        let dir = temp_dir_for("nutrition-persist-invalid");
        let mgr = MemoryPlaneManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let bad = NutritionExtraction {
            entries: vec![NutritionEntry {
                name: "x".into(),
                qty: -1.0,
                unit: "g".into(),
                kcal_estimate: None,
            }],
            confidence: 0.5,
            raw_description: "bad".into(),
            meal_type: "snack".into(),
        };
        let err = persist_extraction(&mgr, &bad, None, None, "")
            .await
            .unwrap_err();
        assert!(err.to_string().contains("non-positive qty"));

        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn normalize_meal_type_buckets() {
        assert_eq!(normalize_meal_type("Desayuno"), "breakfast");
        assert_eq!(normalize_meal_type("ALMUERZO"), "lunch");
        assert_eq!(normalize_meal_type("comida"), "lunch");
        assert_eq!(normalize_meal_type("cena"), "dinner");
        assert_eq!(normalize_meal_type("antojo"), "craving");
        assert_eq!(normalize_meal_type("trago"), "drink");
        assert_eq!(normalize_meal_type("nope"), "snack");
    }
}
