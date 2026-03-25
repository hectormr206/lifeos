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
use tokio::process::Command;

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
}
