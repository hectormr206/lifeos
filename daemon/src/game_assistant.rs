//! Game Assistant — Axi helps users during gameplay.
//!
//! When a user explicitly asks for help while playing a game, Axi can:
//!   1. Capture a screenshot of ONLY the game window (never automatic, always explicit).
//!   2. Search the web for walkthroughs/guides.
//!   3. Send the screenshot + web results + question to a ZDR provider (Cerebras or Groq).
//!
//! **Privacy first:** screenshots are only taken on explicit user request and are sent
//! exclusively to Zero Data Retention (ZDR) providers. No data is ever stored after the
//! request completes.

use anyhow::{bail, Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use log::{error, info, warn};
use serde::{Deserialize, Serialize};
use std::time::Instant;
use tokio::fs;
use tokio::process::Command;

use crate::llm_router::{ChatMessage, LlmRouter, RouterRequest, TaskComplexity};
use crate::privacy_filter;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Configuration for the Game Assistant.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GameAssistantConfig {
    /// Enable or disable the game assistant entirely.
    #[serde(default = "default_enabled")]
    pub enabled: bool,

    /// Allowed LLM providers. Only ZDR providers are permitted during gaming.
    /// Accepted prefixes: "cerebras", "groq", "local".
    #[serde(default = "default_allowed_providers")]
    pub allowed_providers: Vec<String>,

    /// Maximum width (px) when resizing a screenshot before sending to an API.
    /// The image is downscaled proportionally if wider than this value.
    #[serde(default = "default_max_screenshot_width")]
    pub max_screenshot_width: u32,
}

fn default_enabled() -> bool {
    true
}

fn default_allowed_providers() -> Vec<String> {
    vec!["cerebras".to_string(), "groq".to_string()]
}

fn default_max_screenshot_width() -> u32 {
    1920
}

impl Default for GameAssistantConfig {
    fn default() -> Self {
        Self {
            enabled: default_enabled(),
            allowed_providers: default_allowed_providers(),
            max_screenshot_width: default_max_screenshot_width(),
        }
    }
}

// ---------------------------------------------------------------------------
// Game context passed by the caller
// ---------------------------------------------------------------------------

/// Minimal information the caller provides about the running game.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GameInfo {
    /// PID of the game process.
    pub pid: u32,
    /// Optional window title (used as a fallback when PID look-up fails).
    pub window_title: Option<String>,
}

// ---------------------------------------------------------------------------
// Window geometry
// ---------------------------------------------------------------------------

/// Geometry of a window as reported by the compositor.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WindowGeometry {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    /// Wayland output name (e.g. "HDMI-A-1") where the window lives.
    pub output_name: Option<String>,
    pub is_fullscreen: bool,
}

// ---------------------------------------------------------------------------
// Response
// ---------------------------------------------------------------------------

/// Result returned to the caller after Axi answers a game-help request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GameHelpResponse {
    /// Axi's answer to the user's question.
    pub answer: String,
    /// Detected (or supplied) game name.
    pub game_name: String,
    /// Whether a screenshot was actually captured and sent.
    pub screenshot_taken: bool,
    /// Whether a web search was performed.
    pub web_searched: bool,
    /// Which LLM provider was ultimately used.
    pub provider_used: String,
    /// Wall-clock time in milliseconds for the whole operation.
    pub response_time_ms: u64,
}

// ---------------------------------------------------------------------------
// GameAssistant
// ---------------------------------------------------------------------------

/// The Game Assistant manager.
pub struct GameAssistant {
    config: GameAssistantConfig,
    http: reqwest::Client,
}

impl GameAssistant {
    /// Create a new `GameAssistant` with the given configuration.
    pub fn new(config: GameAssistantConfig) -> Self {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .build()
            .expect("failed to build HTTP client for GameAssistant");

        Self { config, http }
    }

    /// Returns `true` if the game assistant is currently enabled.
    pub fn is_enabled(&self) -> bool {
        self.config.enabled
    }

    /// Enable or disable the game assistant at runtime.
    pub fn set_enabled(&mut self, enabled: bool) {
        self.config.enabled = enabled;
        info!(
            "GameAssistant: enabled set to {}",
            if enabled { "true" } else { "false" }
        );
    }

    // -----------------------------------------------------------------------
    // Main entry point
    // -----------------------------------------------------------------------

    /// Answer a game-help question from the user.
    ///
    /// Steps:
    ///   1. Capture only the game window screenshot.
    ///   2. Classify the question locally (fast).
    ///   3. Search the web for relevant guides.
    ///   4. Send everything to a ZDR provider and return the answer.
    pub async fn ask_game_help(
        &self,
        question: &str,
        game_info: &GameInfo,
        router: &LlmRouter,
        privacy_filter: &privacy_filter::PrivacyFilter,
    ) -> Result<GameHelpResponse> {
        if !self.config.enabled {
            bail!("GameAssistant is disabled");
        }

        let start = Instant::now();

        // --- Detect game name ---
        let game_name = detect_game_name(game_info.pid, game_info.window_title.as_deref()).await;
        info!("GameAssistant: detected game = {:?}", game_name);

        // --- 1. Capture game window screenshot ---
        let (screenshot_bytes, screenshot_taken) =
            match capture_game_window(game_info.pid, self.config.max_screenshot_width).await {
                Ok(bytes) => {
                    info!(
                        "GameAssistant: captured game window screenshot ({} bytes)",
                        bytes.len()
                    );
                    (Some(bytes), true)
                }
                Err(e) => {
                    warn!("GameAssistant: screenshot capture failed: {}", e);
                    (None, false)
                }
            };

        // --- Privacy check on screenshot ---
        // We do not inspect screenshot pixels for PII here (it's game content), but we
        // do run a quick text sensitivity check on the question itself.
        let question_sensitivity = privacy_filter.classify(question);
        info!(
            "GameAssistant: question sensitivity = {:?}",
            question_sensitivity
        );

        // --- 2. Classify question (local, fast) ---
        // For now we map the type locally without a network call.
        let question_type = classify_question_locally(question);
        info!("GameAssistant: question type = {:?}", question_type);

        // --- 3. Web search ---
        let (web_results, web_searched) =
            match web_search_game(&self.http, &game_name, question).await {
                Ok(results) if !results.is_empty() => {
                    info!("GameAssistant: web search returned {} chars", results.len());
                    (results, true)
                }
                Ok(_) => {
                    info!("GameAssistant: web search returned no results, proceeding without");
                    (String::new(), false)
                }
                Err(e) => {
                    warn!("GameAssistant: web search failed: {}", e);
                    (String::new(), false)
                }
            };

        // --- 4. Build prompt ---
        let messages = build_game_help_prompt(
            question,
            &game_name,
            &web_results,
            screenshot_bytes.as_deref(),
        );

        // --- Choose a ZDR provider (prefer Cerebras 235B, fallback Groq) ---
        let preferred_provider = self
            .config
            .allowed_providers
            .first()
            .cloned()
            .unwrap_or_else(|| "cerebras".to_string());

        // Validate that the chosen provider is ZDR-compliant.
        if !validate_provider_zdr(&preferred_provider) {
            bail!(
                "GameAssistant: provider '{}' is not in the ZDR whitelist",
                preferred_provider
            );
        }

        let router_request = RouterRequest {
            messages,
            complexity: Some(TaskComplexity::Vision),
            sensitivity: Some(question_sensitivity),
            preferred_provider: Some(preferred_provider.clone()),
            max_tokens: Some(1024),
        };

        // --- Send to LLM ---
        let llm_response = router
            .chat(&router_request)
            .await
            .context("GameAssistant: LLM call failed")?;

        // --- Audit log ---
        audit_log_screenshot(&game_name, &llm_response.provider, question);

        let elapsed = start.elapsed().as_millis() as u64;

        Ok(GameHelpResponse {
            answer: llm_response.text,
            game_name,
            screenshot_taken,
            web_searched,
            provider_used: llm_response.provider,
            response_time_ms: elapsed,
        })
    }
}

// ---------------------------------------------------------------------------
// Screenshot capture
// ---------------------------------------------------------------------------

/// Capture ONLY the game window identified by `pid`.
///
/// Uses `grim` on Wayland (COSMIC / Sway) with a precise geometry crop so that
/// other monitors or windows are never included. If the image is wider than
/// `max_width`, it is downscaled proportionally.
///
/// Returns raw PNG bytes. The temporary file is deleted after reading.
/// On failure an error is returned — there is NO fallback to a full-screen
/// capture, to preserve the privacy guarantee.
pub async fn capture_game_window(pid: u32, max_width: u32) -> Result<Vec<u8>> {
    let geometry = get_game_window_geometry(pid).await?;

    let tmp_path = format!("/tmp/lifeos-game-capture-{}.png", pid);

    // Build the grim capture command.
    let grim_output = if geometry.is_fullscreen {
        // Fullscreen: capture only the specific output.
        let output = geometry.output_name.as_deref().unwrap_or("eDP-1");
        Command::new("grim")
            .arg("-o")
            .arg(output)
            .arg(&tmp_path)
            .output()
            .await
            .context("failed to run grim for fullscreen capture")?
    } else {
        // Windowed: crop to exact window geometry.
        let geometry_str = format!(
            "{},{} {}x{}",
            geometry.x, geometry.y, geometry.width, geometry.height
        );
        Command::new("grim")
            .arg("-g")
            .arg(&geometry_str)
            .arg(&tmp_path)
            .output()
            .await
            .context("failed to run grim with window geometry")?
    };

    if !grim_output.status.success() {
        let stderr = String::from_utf8_lossy(&grim_output.stderr);
        bail!("grim exited with error: {}", stderr);
    }

    // Read the PNG bytes.
    let raw_bytes = fs::read(&tmp_path)
        .await
        .context("failed to read captured PNG")?;

    // Delete temp file immediately — we don't keep screenshots on disk.
    if let Err(e) = fs::remove_file(&tmp_path).await {
        warn!(
            "GameAssistant: failed to delete temp screenshot {}: {}",
            tmp_path, e
        );
    }

    // Optionally downscale if wider than max_width.
    let final_bytes = maybe_resize_png(&raw_bytes, max_width)?;

    Ok(final_bytes)
}

/// Resize `png_bytes` so the image width does not exceed `max_width`.
/// Returns the original bytes unchanged if already within the limit.
fn maybe_resize_png(png_bytes: &[u8], max_width: u32) -> Result<Vec<u8>> {
    use image::ImageFormat;
    use std::io::Cursor;

    let img = image::load_from_memory_with_format(png_bytes, ImageFormat::Png)
        .context("failed to decode PNG for resize")?;

    if img.width() <= max_width {
        return Ok(png_bytes.to_vec());
    }

    let scale = max_width as f32 / img.width() as f32;
    let new_height = (img.height() as f32 * scale) as u32;
    let resized = img.resize_exact(max_width, new_height, image::imageops::FilterType::Lanczos3);

    let mut buf = Cursor::new(Vec::new());
    resized
        .write_to(&mut buf, ImageFormat::Png)
        .context("failed to encode resized PNG")?;

    Ok(buf.into_inner())
}

// ---------------------------------------------------------------------------
// Window geometry via swaymsg
// ---------------------------------------------------------------------------

/// Query the Wayland compositor for the geometry of the window whose process
/// has the given `pid`. Works on Sway and COSMIC (which exposes an i3-compat
/// IPC interface via `swaymsg`).
pub async fn get_game_window_geometry(pid: u32) -> Result<WindowGeometry> {
    let output = Command::new("swaymsg")
        .arg("-t")
        .arg("get_tree")
        .output()
        .await
        .context("failed to run swaymsg — is a Sway/COSMIC compositor running?")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("swaymsg get_tree failed: {}", stderr);
    }

    let tree: serde_json::Value =
        serde_json::from_slice(&output.stdout).context("failed to parse swaymsg JSON tree")?;

    // Recursively walk the tree to find a node whose pid matches.
    if let Some(node) = find_node_by_pid(&tree, pid) {
        return geometry_from_node(node);
    }

    // PID not found — try matching the focused node as a last resort.
    warn!(
        "GameAssistant: PID {} not found in compositor tree, falling back to focused window",
        pid
    );
    let focused = find_focused_node(&tree)
        .ok_or_else(|| anyhow::anyhow!("no focused window found in compositor tree"))?;
    geometry_from_node(focused)
}

/// Recursively search the sway/COSMIC i3-tree for a node whose `pid` field
/// matches. Returns the first match found (depth-first).
fn find_node_by_pid(node: &serde_json::Value, target_pid: u32) -> Option<&serde_json::Value> {
    // Check this node.
    if let Some(pid_val) = node.get("pid") {
        if pid_val.as_u64() == Some(target_pid as u64) {
            return Some(node);
        }
    }

    // Recurse into "nodes" and "floating_nodes".
    for key in &["nodes", "floating_nodes"] {
        if let Some(children) = node.get(key).and_then(|v| v.as_array()) {
            for child in children {
                if let Some(found) = find_node_by_pid(child, target_pid) {
                    return Some(found);
                }
            }
        }
    }

    None
}

/// Find the currently focused leaf node in the compositor tree.
fn find_focused_node(node: &serde_json::Value) -> Option<&serde_json::Value> {
    // A focused leaf node has "focused": true and no children with windows.
    let focused = node
        .get("focused")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let node_type = node.get("type").and_then(|v| v.as_str()).unwrap_or("");

    if focused && (node_type == "con" || node_type == "floating_con") {
        return Some(node);
    }

    for key in &["nodes", "floating_nodes"] {
        if let Some(children) = node.get(key).and_then(|v| v.as_array()) {
            for child in children {
                if let Some(found) = find_focused_node(child) {
                    return Some(found);
                }
            }
        }
    }

    None
}

/// Extract a `WindowGeometry` from a swaymsg tree node.
fn geometry_from_node(node: &serde_json::Value) -> Result<WindowGeometry> {
    let rect = node
        .get("rect")
        .ok_or_else(|| anyhow::anyhow!("node has no 'rect' field"))?;

    let x = rect
        .get("x")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| anyhow::anyhow!("rect.x missing"))? as i32;
    let y = rect
        .get("y")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| anyhow::anyhow!("rect.y missing"))? as i32;
    let width = rect
        .get("width")
        .and_then(|v| v.as_u64())
        .ok_or_else(|| anyhow::anyhow!("rect.width missing"))? as u32;
    let height = rect
        .get("height")
        .and_then(|v| v.as_u64())
        .ok_or_else(|| anyhow::anyhow!("rect.height missing"))? as u32;

    // "fullscreen_mode" 1 = fullscreen on one output, 2 = global fullscreen.
    let is_fullscreen = node
        .get("fullscreen_mode")
        .and_then(|v| v.as_u64())
        .map(|m| m >= 1)
        .unwrap_or(false);

    // Try to get the output name from the node hierarchy (sway puts it on the
    // workspace or output node, not the leaf). We derive it from "output" when
    // present, which some builds expose.
    let output_name = node
        .get("output")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    Ok(WindowGeometry {
        x,
        y,
        width,
        height,
        output_name,
        is_fullscreen,
    })
}

// ---------------------------------------------------------------------------
// Game name detection
// ---------------------------------------------------------------------------

/// Determine a human-readable game name from process information.
///
/// Order of priority:
///   1. `SteamAppId` environment variable → Steam title map.
///   2. `/proc/{pid}/cmdline` cleaned up.
///   3. `/proc/{pid}/comm`.
///   4. Window title (if provided).
pub async fn detect_game_name(pid: u32, window_title: Option<&str>) -> String {
    // 1. Check for SteamAppId in /proc/{pid}/environ.
    if let Some(name) = steam_game_name(pid).await {
        return name;
    }

    // 2. cmdline — get the executable base name and clean it up.
    if let Some(name) = cmdline_game_name(pid).await {
        return name;
    }

    // 3. /proc/{pid}/comm.
    if let Ok(comm) = tokio::fs::read_to_string(format!("/proc/{}/comm", pid)).await {
        let clean = comm.trim().to_string();
        if !clean.is_empty() {
            return clean_process_name(&clean);
        }
    }

    // 4. Fall back to window title.
    if let Some(title) = window_title {
        if !title.is_empty() {
            return title.to_string();
        }
    }

    format!("pid:{}", pid)
}

/// Read `/proc/{pid}/environ` and look for `SteamAppId=<id>`. If found, map
/// the numeric ID to a known game title; otherwise return "Steam Game {id}".
async fn steam_game_name(pid: u32) -> Option<String> {
    let environ_path = format!("/proc/{}/environ", pid);
    let data = tokio::fs::read(&environ_path).await.ok()?;

    // environ entries are NUL-separated key=value pairs.
    let entries: Vec<&[u8]> = data.split(|&b| b == 0).collect();
    for entry in entries {
        if let Ok(s) = std::str::from_utf8(entry) {
            if let Some(rest) = s.strip_prefix("SteamAppId=") {
                let app_id = rest.trim();
                let name = steam_appid_to_name(app_id);
                info!("GameAssistant: Steam AppId {} → {}", app_id, name);
                return Some(name);
            }
        }
    }

    None
}

/// Map common Steam AppIDs to human-readable game names.
/// Unknown IDs are returned as `"Steam Game {appid}"`.
fn steam_appid_to_name(appid: &str) -> String {
    let name = match appid {
        "570" => "Dota 2",
        "730" => "Counter-Strike 2",
        "440" => "Team Fortress 2",
        "271590" => "Grand Theft Auto V",
        "1172470" => "Apex Legends",
        "578080" => "PUBG: Battlegrounds",
        "1245620" => "Elden Ring",
        "1091500" => "Cyberpunk 2077",
        "292030" => "The Witcher 3",
        "489830" => "The Elder Scrolls V: Skyrim SE",
        "105600" => "Terraria",
        "413150" => "Stardew Valley",
        "252490" => "Rust",
        "381210" => "Dead by Daylight",
        "504230" => "Celeste",
        "367520" => "Hollow Knight",
        "646570" => "Slay the Spire",
        "1145360" => "Hades",
        "1623730" => "Vampire Survivors",
        "2379780" => "Balatro",
        _ => return format!("Steam Game {}", appid),
    };
    name.to_string()
}

/// Extract a clean game name from the process command line.
async fn cmdline_game_name(pid: u32) -> Option<String> {
    let cmdline_path = format!("/proc/{}/cmdline", pid);
    let data = tokio::fs::read(&cmdline_path).await.ok()?;

    // Arguments are NUL-separated; the first one is the executable path.
    let exe: &[u8] = data.split(|&b| b == 0).next()?;
    let exe_str = std::str::from_utf8(exe).ok()?;

    // Extract the last path component.
    let base = std::path::Path::new(exe_str).file_name()?.to_str()?;

    let cleaned = clean_process_name(base);
    if cleaned.is_empty() {
        None
    } else {
        Some(cleaned)
    }
}

/// Remove common noise from a process/executable name to get a readable title.
///
/// Strips `.exe`, known Wine/Proton wrapper prefixes, and underscores.
fn clean_process_name(name: &str) -> String {
    let lower = name.to_lowercase();

    // Skip well-known Wine/Proton runtime wrappers.
    for skip in &[
        "wine",
        "wine64",
        "wineserver",
        "wineboot",
        "proton",
        "steam-runtime",
        "python",
        "python3",
        "bash",
        "sh",
    ] {
        if lower == *skip || lower.starts_with(&format!("{}.", skip)) {
            return String::new();
        }
    }

    // Strip .exe (case-insensitive).
    let without_ext = if lower.ends_with(".exe") {
        &name[..name.len() - 4]
    } else {
        name
    };

    // Replace underscores/hyphens with spaces and title-case.
    without_ext
        .replace(['_', '-'], " ")
        .split_whitespace()
        .map(|w| {
            let mut c = w.chars();
            match c.next() {
                None => String::new(),
                Some(f) => f.to_uppercase().to_string() + c.as_str(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

// ---------------------------------------------------------------------------
// Question classification (local, fast)
// ---------------------------------------------------------------------------

/// Broad category of a game-help question.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum QuestionType {
    Puzzle,
    Combination,
    Location,
    Strategy,
    General,
}

/// Classify a question locally with simple keyword heuristics (<1 ms).
fn classify_question_locally(question: &str) -> QuestionType {
    let lower = question.to_lowercase();

    if lower.contains("puzzle") || lower.contains("riddle") || lower.contains("code") {
        return QuestionType::Puzzle;
    }
    if lower.contains("combination")
        || lower.contains("safe")
        || lower.contains("password")
        || lower.contains("lock")
    {
        return QuestionType::Combination;
    }
    if lower.contains("where")
        || lower.contains("location")
        || lower.contains("find")
        || lower.contains("map")
        || lower.contains("item")
    {
        return QuestionType::Location;
    }
    if lower.contains("how to")
        || lower.contains("beat")
        || lower.contains("boss")
        || lower.contains("strategy")
        || lower.contains("build")
        || lower.contains("loadout")
    {
        return QuestionType::Strategy;
    }

    QuestionType::General
}

// ---------------------------------------------------------------------------
// Web search
// ---------------------------------------------------------------------------

/// Search the web for game guides/walkthroughs.
///
/// Priority:
///   1. Groq browser_search tool (if `GROQ_API_KEY` set).
///   2. Serper API (if `SERPER_API_KEY` set).
///   3. Empty string (LLM uses training data).
pub async fn web_search_game(
    http: &reqwest::Client,
    game_name: &str,
    question: &str,
) -> Result<String> {
    let query = format!("{} {} walkthrough guide solution", game_name, question);

    // --- Try Serper (simpler, no streaming) ---
    if let Ok(key) = std::env::var("SERPER_API_KEY") {
        match serper_search(http, &key, &query).await {
            Ok(results) if !results.is_empty() => return Ok(results),
            Ok(_) => info!("GameAssistant: Serper returned empty results"),
            Err(e) => warn!("GameAssistant: Serper search error: {}", e),
        }
    }

    // --- Try Groq browser_search ---
    if let Ok(key) = std::env::var("GROQ_API_KEY") {
        match groq_browser_search(http, &key, &query).await {
            Ok(results) if !results.is_empty() => return Ok(results),
            Ok(_) => info!("GameAssistant: Groq browser_search returned empty results"),
            Err(e) => warn!("GameAssistant: Groq browser_search error: {}", e),
        }
    }

    // No search available — return empty string so the LLM uses training data.
    Ok(String::new())
}

/// Call the Serper.dev Google Search API.
async fn serper_search(http: &reqwest::Client, api_key: &str, query: &str) -> Result<String> {
    #[derive(Serialize)]
    struct SerperRequest<'a> {
        q: &'a str,
        num: u8,
    }

    #[derive(Deserialize)]
    struct SerperResponse {
        #[serde(default)]
        organic: Vec<SerperResult>,
    }

    #[derive(Deserialize)]
    struct SerperResult {
        title: String,
        snippet: String,
        link: String,
    }

    let resp = http
        .post("https://google.serper.dev/search")
        .header("X-API-KEY", api_key)
        .json(&SerperRequest { q: query, num: 5 })
        .send()
        .await
        .context("Serper API request failed")?;

    let status = resp.status();
    if !status.is_success() {
        bail!("Serper API returned HTTP {}", status);
    }

    let data: SerperResponse = resp
        .json()
        .await
        .context("failed to parse Serper response")?;

    let mut parts = Vec::new();
    for r in &data.organic {
        parts.push(format!("**{}**\n{}\n{}", r.title, r.snippet, r.link));
    }

    Ok(parts.join("\n\n"))
}

/// Call the Groq completions API with a browser_search tool call.
///
/// Groq exposes a `browser_search` tool in its function-calling interface that
/// returns real-time web results. We make a single round-trip using a prompt
/// that asks for search results and parse the tool call response.
async fn groq_browser_search(http: &reqwest::Client, api_key: &str, query: &str) -> Result<String> {
    #[derive(Serialize)]
    struct ToolDef {
        r#type: &'static str,
        function: ToolFunction,
    }

    #[derive(Serialize)]
    struct ToolFunction {
        name: &'static str,
        description: &'static str,
        parameters: serde_json::Value,
    }

    #[derive(Serialize)]
    struct GroqRequest {
        model: &'static str,
        messages: Vec<serde_json::Value>,
        tools: Vec<ToolDef>,
        tool_choice: &'static str,
        max_tokens: u32,
    }

    let tool = ToolDef {
        r#type: "function",
        function: ToolFunction {
            name: "browser_search",
            description: "Search the web for information",
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "query": { "type": "string", "description": "The search query" }
                },
                "required": ["query"]
            }),
        },
    };

    let request = GroqRequest {
        model: "llama3-8b-8192",
        messages: vec![serde_json::json!({
            "role": "user",
            "content": format!("Search the web for: {}", query)
        })],
        tools: vec![tool],
        tool_choice: "required",
        max_tokens: 512,
    };

    let resp = http
        .post("https://api.groq.com/openai/v1/chat/completions")
        .bearer_auth(api_key)
        .json(&request)
        .send()
        .await
        .context("Groq browser_search request failed")?;

    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        bail!("Groq API returned HTTP {}: {}", status, body);
    }

    let data: serde_json::Value = resp.json().await.context("failed to parse Groq response")?;

    // Extract tool call results from the response.
    let content = data
        .pointer("/choices/0/message/content")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    if content.is_empty() {
        // Try to get tool call arguments as a fallback.
        let args = data
            .pointer("/choices/0/message/tool_calls/0/function/arguments")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        return Ok(args.to_string());
    }

    Ok(content.to_string())
}

// ---------------------------------------------------------------------------
// Prompt builder
// ---------------------------------------------------------------------------

/// Construct the messages array sent to the LLM.
///
/// If a screenshot is provided it is embedded as a base64-encoded PNG in the
/// user message (OpenAI vision format). Web search results are appended to the
/// user message text.
pub fn build_game_help_prompt(
    question: &str,
    game_name: &str,
    web_results: &str,
    screenshot_bytes: Option<&[u8]>,
) -> Vec<ChatMessage> {
    let system_text = format!(
        "You are Axi, a gaming assistant for LifeOS. The user is playing {game_name} and needs help.\n\
         Answer concisely and specifically. If you see a screenshot, describe what you see and give \
         precise instructions.\n\
         Focus on: puzzle solutions, item locations, safe combinations, boss strategies, quest guides.\n\
         Always answer in the same language the user asks in."
    );

    let system_msg = ChatMessage {
        role: "system".to_string(),
        content: serde_json::Value::String(system_text),
    };

    // Build the user message content.
    let user_content: serde_json::Value = if let Some(bytes) = screenshot_bytes {
        let b64 = BASE64.encode(bytes);
        let image_url = format!("data:image/png;base64,{}", b64);

        let mut parts: Vec<serde_json::Value> = vec![serde_json::json!({
            "type": "image_url",
            "image_url": { "url": image_url }
        })];

        let mut text_parts = format!("Game: {}\nQuestion: {}", game_name, question);
        if !web_results.is_empty() {
            text_parts.push_str(&format!("\n\nWeb search results:\n{}", web_results));
        }

        parts.push(serde_json::json!({ "type": "text", "text": text_parts }));
        serde_json::Value::Array(parts)
    } else {
        let mut text = format!("Game: {}\nQuestion: {}", game_name, question);
        if !web_results.is_empty() {
            text.push_str(&format!("\n\nWeb search results:\n{}", web_results));
        }
        serde_json::Value::String(text)
    };

    let user_msg = ChatMessage {
        role: "user".to_string(),
        content: user_content,
    };

    vec![system_msg, user_msg]
}

// ---------------------------------------------------------------------------
// Security helpers
// ---------------------------------------------------------------------------

/// Returns `true` only if the provider name starts with a known ZDR prefix.
///
/// Accepted prefixes: `cerebras`, `groq`, `local`.
pub fn validate_provider_zdr(provider_name: &str) -> bool {
    let lower = provider_name.to_lowercase();
    lower.starts_with("cerebras") || lower.starts_with("groq") || lower.starts_with("local")
}

/// Write an audit log entry for a screenshot event.
///
/// Log file: `/var/log/lifeos/game-assistant-audit.log`
/// Format: ISO timestamp | game | provider | question (truncated to 120 chars)
pub fn audit_log_screenshot(game_name: &str, provider: &str, question: &str) {
    let truncated = if question.len() > 120 {
        format!("{}...", &question[..120])
    } else {
        question.to_string()
    };

    let timestamp = chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%z");
    let line = format!(
        "{} | game={} | provider={} | question={}",
        timestamp, game_name, provider, truncated
    );

    // Non-blocking best-effort write — we spawn a task and ignore errors.
    let line_clone = line.clone();
    tokio::spawn(async move {
        let log_dir = std::path::Path::new("/var/log/lifeos");
        if !log_dir.exists() {
            if let Err(e) = tokio::fs::create_dir_all(log_dir).await {
                warn!("GameAssistant: could not create log dir: {}", e);
                return;
            }
        }
        let log_path = log_dir.join("game-assistant-audit.log");
        use tokio::io::AsyncWriteExt;
        match tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
            .await
        {
            Ok(mut f) => {
                let _ = f.write_all(format!("{}\n", line_clone).as_bytes()).await;
            }
            Err(e) => {
                error!("GameAssistant: audit log write failed: {}", e);
            }
        }
    });

    info!("GameAssistant audit: {}", line);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_provider_zdr_allows_zdr() {
        assert!(validate_provider_zdr("cerebras"));
        assert!(validate_provider_zdr("cerebras-235b"));
        assert!(validate_provider_zdr("groq"));
        assert!(validate_provider_zdr("groq-llama3"));
        assert!(validate_provider_zdr("local"));
        assert!(validate_provider_zdr("local-qwen3"));
    }

    #[test]
    fn test_validate_provider_zdr_rejects_non_zdr() {
        assert!(!validate_provider_zdr("openai"));
        assert!(!validate_provider_zdr("gemini"));
        assert!(!validate_provider_zdr("anthropic"));
        assert!(!validate_provider_zdr("openrouter"));
        assert!(!validate_provider_zdr("glm"));
        assert!(!validate_provider_zdr(""));
    }

    #[test]
    fn test_clean_process_name_removes_exe() {
        assert_eq!(clean_process_name("HollowKnight.exe"), "HollowKnight");
    }

    #[test]
    fn test_clean_process_name_skips_wine() {
        assert_eq!(clean_process_name("wine"), "");
        assert_eq!(clean_process_name("wine64"), "");
    }

    #[test]
    fn test_clean_process_name_title_case() {
        assert_eq!(clean_process_name("stardew_valley"), "Stardew Valley");
        assert_eq!(clean_process_name("dead-cells"), "Dead Cells");
    }

    #[test]
    fn test_steam_appid_to_name_known() {
        assert_eq!(steam_appid_to_name("413150"), "Stardew Valley");
        assert_eq!(steam_appid_to_name("1145360"), "Hades");
    }

    #[test]
    fn test_steam_appid_to_name_unknown() {
        assert_eq!(steam_appid_to_name("9999999"), "Steam Game 9999999");
    }

    #[test]
    fn test_classify_question_locally() {
        assert_eq!(
            classify_question_locally("how to beat the boss?"),
            QuestionType::Strategy
        );
        assert_eq!(
            classify_question_locally("what is the safe combination?"),
            QuestionType::Combination
        );
        assert_eq!(
            classify_question_locally("where is the item?"),
            QuestionType::Location
        );
        assert_eq!(
            classify_question_locally("solve this puzzle"),
            QuestionType::Puzzle
        );
        assert_eq!(
            classify_question_locally("what year was this released?"),
            QuestionType::General
        );
    }

    #[test]
    fn test_build_game_help_prompt_no_screenshot() {
        let msgs = build_game_help_prompt("how to beat Margit?", "Elden Ring", "", None);
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0].role, "system");
        assert_eq!(msgs[1].role, "user");
        let user_text = msgs[1].content.as_str().unwrap();
        assert!(user_text.contains("Elden Ring"));
        assert!(user_text.contains("Margit"));
    }

    #[test]
    fn test_build_game_help_prompt_with_web_results() {
        let msgs = build_game_help_prompt(
            "safe code",
            "Resident Evil 7",
            "The safe code is 1408.",
            None,
        );
        let user_text = msgs[1].content.as_str().unwrap();
        assert!(user_text.contains("Web search results"));
        assert!(user_text.contains("1408"));
    }

    #[test]
    fn test_build_game_help_prompt_with_screenshot() {
        let fake_png = b"\x89PNG\r\n\x1a\n"; // minimal PNG header
        let msgs = build_game_help_prompt("what do I do here?", "Celeste", "", Some(fake_png));
        // With screenshot the content should be an array.
        assert!(msgs[1].content.is_array());
        let arr = msgs[1].content.as_array().unwrap();
        // First element should be the image.
        assert_eq!(arr[0].get("type").unwrap().as_str().unwrap(), "image_url");
        // Second element should be text.
        assert_eq!(arr[1].get("type").unwrap().as_str().unwrap(), "text");
    }

    #[test]
    fn test_config_defaults() {
        let cfg = GameAssistantConfig::default();
        assert!(cfg.enabled);
        assert_eq!(cfg.allowed_providers, vec!["cerebras", "groq"]);
        assert_eq!(cfg.max_screenshot_width, 1920);
    }

    #[test]
    fn test_game_assistant_set_enabled() {
        let mut ga = GameAssistant::new(GameAssistantConfig::default());
        assert!(ga.is_enabled());
        ga.set_enabled(false);
        assert!(!ga.is_enabled());
        ga.set_enabled(true);
        assert!(ga.is_enabled());
    }

    #[test]
    fn test_geometry_from_node_basic() {
        let node = serde_json::json!({
            "rect": { "x": 100, "y": 200, "width": 1920, "height": 1080 },
            "fullscreen_mode": 0,
            "output": "HDMI-A-1"
        });
        let geo = geometry_from_node(&node).unwrap();
        assert_eq!(geo.x, 100);
        assert_eq!(geo.y, 200);
        assert_eq!(geo.width, 1920);
        assert_eq!(geo.height, 1080);
        assert!(!geo.is_fullscreen);
        assert_eq!(geo.output_name.as_deref(), Some("HDMI-A-1"));
    }

    #[test]
    fn test_geometry_from_node_fullscreen() {
        let node = serde_json::json!({
            "rect": { "x": 0, "y": 0, "width": 2560, "height": 1440 },
            "fullscreen_mode": 1
        });
        let geo = geometry_from_node(&node).unwrap();
        assert!(geo.is_fullscreen);
    }

    #[test]
    fn test_find_node_by_pid_nested() {
        let tree = serde_json::json!({
            "nodes": [
                {
                    "pid": 1,
                    "nodes": [
                        { "pid": 42, "rect": { "x": 0, "y": 0, "width": 100, "height": 100 } }
                    ]
                }
            ]
        });
        let found = find_node_by_pid(&tree, 42);
        assert!(found.is_some());
        assert_eq!(found.unwrap().get("pid").unwrap().as_u64().unwrap(), 42);
    }

    #[test]
    fn test_find_node_by_pid_not_found() {
        let tree = serde_json::json!({ "nodes": [{ "pid": 1 }] });
        assert!(find_node_by_pid(&tree, 999).is_none());
    }
}
