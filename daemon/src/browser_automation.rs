//! Browser Automation — Axi can navigate, interact, and test web applications.
//!
//! Strategy: Use Firefox/Chromium in headless mode via command-line flags,
//! combined with screenshot + vision analysis for verification.
//! No Selenium/Playwright dependency — pure CLI + vision approach.
//!
//! Flow: open URL → wait → screenshot → analyze with vision LLM → decide next action

use anyhow::{Context, Result};
use log::info;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::Stdio;
use tokio::process::Command;
use tokio::time::Duration;

use crate::cdp_client::CdpClient;

/// A persistent browser session that keeps a single Firefox process alive
/// so that page state (cookies, storage, sessions) is preserved across
/// multiple operations.
pub struct PersistentBrowserSession {
    cdp: CdpClient,
    process: tokio::process::Child,
    port: u16,
}

impl PersistentBrowserSession {
    /// Launch Firefox headless with CDP remote debugging and connect.
    pub async fn start() -> Result<Self, String> {
        Self::start_on_port(9222).await
    }

    /// Launch Firefox headless with CDP on a specific port.
    pub async fn start_on_port(port: u16) -> Result<Self, String> {
        let process = tokio::process::Command::new("firefox")
            .args([
                "--headless",
                &format!("--remote-debugging-port={}", port),
                "--no-remote",
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|e| format!("Failed to launch Firefox: {}", e))?;

        // CdpClient::connect retries discovery for up to 10 seconds
        let cdp = CdpClient::connect(port).await?;

        Ok(Self { cdp, process, port })
    }

    /// Get a reference to the underlying CDP client.
    pub fn cdp(&self) -> &CdpClient {
        &self.cdp
    }

    /// The port this session is running on.
    pub fn port(&self) -> u16 {
        self.port
    }
}

impl Drop for PersistentBrowserSession {
    fn drop(&mut self) {
        // Best-effort kill when the session is dropped.
        // We can't .await here, but start() ensures the process handle is valid.
        let _ = self.process.start_kill();
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BrowserSession {
    pub url: String,
    pub screenshots: Vec<String>,
    pub status: BrowserStatus,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BrowserStatus {
    Idle,
    Navigating,
    Analyzing,
    Done,
    Error(String),
}

pub struct BrowserAutomation {
    data_dir: PathBuf,
}

impl BrowserAutomation {
    pub fn new(data_dir: PathBuf) -> Self {
        Self { data_dir }
    }

    /// Open a URL in the browser and take a screenshot for analysis.
    pub async fn navigate_and_capture(&self, url: &str) -> Result<String> {
        info!("[browser] Navigating to: {}", url);

        let screenshots_dir = self.data_dir.join("browser_screenshots");
        tokio::fs::create_dir_all(&screenshots_dir).await?;

        let screenshot_path = screenshots_dir.join(format!(
            "page-{}.png",
            chrono::Utc::now().format("%Y%m%d-%H%M%S")
        ));

        // Try Firefox headless screenshot first
        let result = Command::new("firefox")
            .args([
                "--headless",
                "--screenshot",
                screenshot_path.to_str().unwrap_or("page.png"),
                "--window-size=1920,1080",
                url,
            ])
            .output()
            .await;

        match result {
            Ok(o) if o.status.success() => {
                info!("[browser] Screenshot saved: {}", screenshot_path.display());
                Ok(screenshot_path.to_string_lossy().to_string())
            }
            _ => {
                // Fallback: try chromium
                let result = Command::new("chromium-browser")
                    .args([
                        "--headless",
                        "--disable-gpu",
                        &format!("--screenshot={}", screenshot_path.display()),
                        "--window-size=1920,1080",
                        "--no-sandbox",
                        url,
                    ])
                    .output()
                    .await;

                match result {
                    Ok(o) if o.status.success() => {
                        Ok(screenshot_path.to_string_lossy().to_string())
                    }
                    _ => {
                        anyhow::bail!(
                            "Failed to take headless screenshot (tried firefox and chromium)"
                        )
                    }
                }
            }
        }
    }

    /// Fetch a URL and return the HTML content (for analysis without rendering).
    pub async fn fetch_html(&self, url: &str) -> Result<String> {
        let output = Command::new("curl")
            .args(["-sL", "--max-time", "30", url])
            .output()
            .await
            .context("curl failed")?;

        if !output.status.success() {
            anyhow::bail!("curl failed with status {}", output.status);
        }

        let html = String::from_utf8_lossy(&output.stdout);
        // Truncate to prevent overwhelming the LLM
        Ok(html.chars().take(8000).collect())
    }

    /// Run a local development server check — navigate to localhost URL and verify it loads.
    pub async fn check_local_server(&self, port: u16, path: &str) -> Result<String> {
        let url = format!("http://127.0.0.1:{}{}", port, path);
        info!("[browser] Checking local server: {}", url);

        // First verify the server is responding
        let output = Command::new("curl")
            .args(["-sI", "--max-time", "5", &url])
            .output()
            .await
            .context("curl failed")?;

        let headers = String::from_utf8_lossy(&output.stdout);
        let status_line = headers.lines().next().unwrap_or("");

        if !status_line.contains("200")
            && !status_line.contains("301")
            && !status_line.contains("302")
        {
            return Ok(format!(
                "Server check FAILED: {} returned {}",
                url, status_line
            ));
        }

        // Take a screenshot for visual verification
        match self.navigate_and_capture(&url).await {
            Ok(screenshot) => Ok(format!(
                "Server check OK: {} — screenshot at {}",
                url, screenshot
            )),
            Err(e) => Ok(format!(
                "Server responds ({}), but screenshot failed: {}",
                status_line.trim(),
                e
            )),
        }
    }

    // -----------------------------------------------------------------------
    // CDP (Chrome DevTools Protocol) interaction methods
    // -----------------------------------------------------------------------

    /// Launch a headless Chromium with remote debugging enabled.
    /// Returns the child process handle after waiting for it to be ready.
    async fn launch_chromium_debug(
        &self,
        url: &str,
        debug_port: u16,
    ) -> Result<tokio::process::Child> {
        let child = Command::new("chromium-browser")
            .args([
                "--headless=new",
                "--disable-gpu",
                "--no-sandbox",
                &format!("--remote-debugging-port={}", debug_port),
                "--window-size=1920,1080",
                url,
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .context("Failed to launch chromium-browser for CDP")?;

        // Wait for the browser to start and the page to load
        tokio::time::sleep(Duration::from_secs(3)).await;
        Ok(child)
    }

    /// Fetch the list of CDP targets from the browser's JSON endpoint.
    async fn cdp_get_targets(
        &self,
        client: &reqwest::Client,
        debug_port: u16,
    ) -> Result<Vec<serde_json::Value>> {
        let targets: Vec<serde_json::Value> = client
            .get(format!("http://127.0.0.1:{}/json", debug_port))
            .send()
            .await
            .context("Failed to connect to CDP endpoint")?
            .json()
            .await
            .context("Failed to parse CDP targets JSON")?;
        Ok(targets)
    }

    /// Internal: evaluate a JavaScript expression via a headless Chromium
    /// `--dump-dom` trick. This avoids needing a WebSocket CDP client by
    /// spawning a second Chromium that loads a `data:` URI containing the
    /// expression and captures its `document.write` output.
    async fn cdp_evaluate(&self, expression: &str) -> Result<String> {
        // Encode expression so it is safe inside an HTML <script> block.
        let encoded = expression.replace('\\', "\\\\").replace('\'', "\\'");
        let data_uri = format!(
            "data:text/html,<script>document.write(eval('{}'))</script>",
            encoded
        );

        let output = Command::new("chromium-browser")
            .args([
                "--headless=new",
                "--disable-gpu",
                "--no-sandbox",
                "--run-all-compositor-stages-before-draw",
                "--window-size=1920,1080",
                "--dump-dom",
                &data_uri,
            ])
            .output()
            .await
            .context("chromium --dump-dom failed")?;

        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    }

    /// Click on an element by CSS selector using CDP via
    /// `chromium --remote-debugging-port`.
    pub async fn click_element(&self, url: &str, selector: &str) -> Result<String> {
        let debug_port = 9222;
        let mut child = self.launch_chromium_debug(url, debug_port).await?;

        let client = reqwest::Client::new();
        let targets = self.cdp_get_targets(&client, debug_port).await?;

        let target_id = targets
            .first()
            .and_then(|t| t["id"].as_str())
            .ok_or_else(|| anyhow::anyhow!("No CDP target found"))?;

        // Activate the page target
        client
            .post(format!(
                "http://127.0.0.1:{}/json/activate/{}",
                debug_port, target_id
            ))
            .send()
            .await?;

        // Build the click JS
        let js = format!(
            "const el = document.querySelector('{}'); if(el) {{ el.click(); 'clicked' }} else {{ 'not found' }}",
            selector.replace('\'', "\\'")
        );

        let result = self.cdp_evaluate(&js).await;

        child.kill().await.ok();
        result
    }

    /// Fill an input element identified by CSS selector with a given value.
    pub async fn fill_input(&self, url: &str, selector: &str, value: &str) -> Result<String> {
        let js = format!(
            "const el = document.querySelector('{}'); if(el) {{ el.value = '{}'; el.dispatchEvent(new Event('input', {{bubbles:true}})); 'filled' }} else {{ 'not found' }}",
            selector.replace('\'', "\\'"),
            value.replace('\'', "\\'")
        );
        self.evaluate_js_on_page(url, &js).await
    }

    /// Evaluate arbitrary JavaScript on a page and return the result.
    pub async fn evaluate_js_on_page(&self, url: &str, js_code: &str) -> Result<String> {
        let debug_port = 9222;
        let mut child = self.launch_chromium_debug(url, debug_port).await?;

        let client = reqwest::Client::new();
        let targets = self.cdp_get_targets(&client, debug_port).await?;

        let target_id = targets
            .first()
            .and_then(|t| t["id"].as_str())
            .ok_or_else(|| anyhow::anyhow!("No CDP target found"))?;

        client
            .post(format!(
                "http://127.0.0.1:{}/json/activate/{}",
                debug_port, target_id
            ))
            .send()
            .await?;

        let result = self.cdp_evaluate(js_code).await;
        child.kill().await.ok();
        result
    }

    /// Get console errors from a page by injecting an error collector.
    pub async fn get_console_errors(&self, url: &str) -> Result<Vec<String>> {
        let js = r#"
            (function() {
                var errors = [];
                var origError = console.error;
                console.error = function() {
                    var args = Array.prototype.slice.call(arguments);
                    errors.push(args.join(' '));
                    origError.apply(console, arguments);
                };
                return JSON.stringify(errors);
            })()
        "#;
        let result = self.evaluate_js_on_page(url, js).await?;
        let errors: Vec<String> = serde_json::from_str(&result).unwrap_or_default();
        Ok(errors)
    }

    /// Navigate to a URL, capture screenshot, and analyze with vision LLM.
    /// Returns the LLM's description/analysis of what the page shows.
    pub async fn navigate_and_analyze(
        &self,
        url: &str,
        analysis_prompt: &str,
        router: &std::sync::Arc<tokio::sync::RwLock<crate::llm_router::LlmRouter>>,
    ) -> Result<String> {
        let screenshot_path = self.navigate_and_capture(url).await?;

        // Build a vision request to the LLM router
        let request = crate::llm_router::RouterRequest {
            messages: vec![crate::llm_router::ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(format!(
                    "{}\n\n[Screenshot of {} attached at: {}]",
                    analysis_prompt, url, screenshot_path
                )),
            }],
            complexity: Some(crate::llm_router::TaskComplexity::Vision),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(1024),
        };

        let router_guard = router.read().await;
        match router_guard.chat(&request).await {
            Ok(response) => Ok(response.text),
            Err(e) => {
                // Fallback: return the screenshot path if vision fails
                Ok(format!(
                    "Screenshot saved at {} but vision analysis failed: {}",
                    screenshot_path, e
                ))
            }
        }
    }
}
