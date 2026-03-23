use clap::Subcommand;
use colored::Colorize;
use reqwest::Url;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Subcommand)]
pub enum BrowserCommands {
    /// Initialize a secure browser-operator policy template
    PolicyInit {
        #[arg(long, default_value = "browser-policy.json")]
        output: String,
    },
    /// Run multi-step browser workflow under policy guardrails
    Run {
        /// Policy JSON path
        #[arg(long)]
        policy: String,
        /// Step definition (repeatable): open:<url>, find:<text>, title, save:<path>
        #[arg(long, required = true)]
        step: Vec<String>,
    },
    /// Show recent browser operator audit entries
    Audit {
        #[arg(short, long, default_value_t = 20)]
        limit: usize,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BrowserPolicy {
    allowed_domains: Vec<String>,
    #[serde(default)]
    blocked_domains: Vec<String>,
    #[serde(default = "default_max_steps")]
    max_steps: usize,
    #[serde(default = "default_timeout")]
    timeout_seconds: u64,
}

#[derive(Debug, Clone)]
enum BrowserStep {
    Open(String),
    Find(String),
    Title,
    Save(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BrowserAuditEntry {
    timestamp: String,
    step: String,
    status: String,
    detail: String,
}

fn default_max_steps() -> usize {
    10
}

fn default_timeout() -> u64 {
    15
}

pub async fn execute(cmd: BrowserCommands) -> anyhow::Result<()> {
    match cmd {
        BrowserCommands::PolicyInit { output } => cmd_policy_init(&output),
        BrowserCommands::Run { policy, step } => cmd_run(&policy, &step).await,
        BrowserCommands::Audit { limit } => cmd_audit(limit),
    }
}

fn cmd_policy_init(output: &str) -> anyhow::Result<()> {
    let template = BrowserPolicy {
        allowed_domains: vec!["example.com".to_string(), "docs.rs".to_string()],
        blocked_domains: vec!["localhost".to_string()],
        max_steps: default_max_steps(),
        timeout_seconds: default_timeout(),
    };
    std::fs::write(output, serde_json::to_string_pretty(&template)?)?;
    println!("{}", "Browser policy template created".green().bold());
    println!("  file: {}", output.cyan());
    Ok(())
}

async fn cmd_run(policy_path: &str, raw_steps: &[String]) -> anyhow::Result<()> {
    let policy = load_policy(policy_path)?;
    if raw_steps.len() > policy.max_steps {
        anyhow::bail!(
            "step count {} exceeds policy max_steps {}",
            raw_steps.len(),
            policy.max_steps
        );
    }
    let steps = raw_steps
        .iter()
        .map(|s| parse_step(s))
        .collect::<Result<Vec<_>, _>>()?;

    println!("{}", "Browser operator run".bold().blue());
    println!("  policy: {}", policy_path.cyan());
    println!("  steps: {}", steps.len());

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(
            policy.timeout_seconds.max(1),
        ))
        .build()?;

    let mut last_content = String::new();
    let mut last_url = String::new();
    for step in steps {
        match step {
            BrowserStep::Open(url) => {
                enforce_policy(&policy, &url)?;
                let resp = client.get(&url).send().await?;
                let status = resp.status();
                let body = resp.text().await?;
                last_content = body;
                last_url = url.clone();
                let detail = format!("open {} -> HTTP {}", url, status);
                println!("  {}", detail.green());
                append_audit(BrowserAuditEntry {
                    timestamp: chrono::Utc::now().to_rfc3339(),
                    step: format!("open:{}", url),
                    status: "ok".to_string(),
                    detail,
                })?;
            }
            BrowserStep::Find(needle) => {
                let found = last_content.contains(&needle);
                let status = if found { "ok" } else { "failed" };
                let detail = if found {
                    format!("pattern found: {}", needle)
                } else {
                    format!("pattern not found: {}", needle)
                };
                println!(
                    "  {}",
                    if found {
                        detail.green()
                    } else {
                        detail.yellow()
                    }
                );
                append_audit(BrowserAuditEntry {
                    timestamp: chrono::Utc::now().to_rfc3339(),
                    step: format!("find:{}", needle),
                    status: status.to_string(),
                    detail: detail.clone(),
                })?;
                if !found {
                    anyhow::bail!("Browser operator step failed: {}", detail);
                }
            }
            BrowserStep::Title => {
                let title =
                    extract_html_title(&last_content).unwrap_or_else(|| "<none>".to_string());
                let detail = format!("title {} from {}", title, last_url);
                println!("  {}", detail.green());
                append_audit(BrowserAuditEntry {
                    timestamp: chrono::Utc::now().to_rfc3339(),
                    step: "title".to_string(),
                    status: "ok".to_string(),
                    detail,
                })?;
            }
            BrowserStep::Save(path) => {
                std::fs::write(&path, &last_content)?;
                let detail = format!("saved content to {}", path);
                println!("  {}", detail.green());
                append_audit(BrowserAuditEntry {
                    timestamp: chrono::Utc::now().to_rfc3339(),
                    step: format!("save:{}", path),
                    status: "ok".to_string(),
                    detail,
                })?;
            }
        }
    }

    Ok(())
}

fn cmd_audit(limit: usize) -> anyhow::Result<()> {
    let path = audit_log_path();
    println!("{}", "Browser operator audit".bold().blue());
    if !path.exists() {
        println!("  {}", "No audit entries yet.".dimmed());
        return Ok(());
    }

    let raw = std::fs::read_to_string(&path)?;
    let mut lines = raw.lines().collect::<Vec<_>>();
    lines.reverse();
    for line in lines.into_iter().take(limit.clamp(1, 500)) {
        println!("  {}", line);
    }
    Ok(())
}

fn load_policy(path: &str) -> anyhow::Result<BrowserPolicy> {
    let raw = std::fs::read_to_string(path)?;
    let policy: BrowserPolicy = serde_json::from_str(&raw)
        .map_err(|e| anyhow::anyhow!("Invalid browser policy '{}': {}", path, e))?;
    if policy.allowed_domains.is_empty() {
        anyhow::bail!("policy.allowed_domains cannot be empty");
    }
    Ok(policy)
}

fn parse_step(raw: &str) -> anyhow::Result<BrowserStep> {
    let trimmed = raw.trim();
    if trimmed.eq_ignore_ascii_case("title") {
        return Ok(BrowserStep::Title);
    }
    if let Some(url) = trimmed.strip_prefix("open:") {
        return Ok(BrowserStep::Open(url.trim().to_string()));
    }
    if let Some(needle) = trimmed.strip_prefix("find:") {
        return Ok(BrowserStep::Find(needle.trim().to_string()));
    }
    if let Some(path) = trimmed.strip_prefix("save:") {
        return Ok(BrowserStep::Save(path.trim().to_string()));
    }
    anyhow::bail!("Invalid step '{}'", raw)
}

fn enforce_policy(policy: &BrowserPolicy, url: &str) -> anyhow::Result<()> {
    let parsed = Url::parse(url)?;
    let host = parsed
        .host_str()
        .ok_or_else(|| anyhow::anyhow!("URL has no host: {}", url))?;
    if policy
        .blocked_domains
        .iter()
        .any(|d| host.eq_ignore_ascii_case(d))
    {
        anyhow::bail!("Host '{}' blocked by policy", host);
    }
    if !policy
        .allowed_domains
        .iter()
        .any(|d| host.eq_ignore_ascii_case(d))
    {
        anyhow::bail!("Host '{}' not in policy allowlist", host);
    }
    Ok(())
}

fn extract_html_title(content: &str) -> Option<String> {
    let lower = content.to_lowercase();
    let start_idx = lower.find("<title>")?;
    let end_idx = lower.find("</title>")?;
    if end_idx <= start_idx + 7 {
        return None;
    }
    Some(content[start_idx + 7..end_idx].trim().to_string())
}

fn audit_log_path() -> PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("lifeos")
        .join("browser-operator")
        .join("audit.jsonl")
}

fn append_audit(entry: BrowserAuditEntry) -> anyhow::Result<()> {
    let path = audit_log_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let line = serde_json::to_string(&entry)?;
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    writeln!(file, "{}", line)?;
    Ok(())
}

/// Fetch a URL and return its text content (HTML stripped to plain text).
/// Used by the supervisor for web browsing tasks.
pub async fn fetch_url_text(url: &str, timeout_secs: u64) -> anyhow::Result<String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(timeout_secs.max(5)))
        .user_agent("LifeOS-Axi/0.1")
        .build()?;

    let resp = client.get(url).send().await?;
    let status = resp.status();
    if !status.is_success() {
        anyhow::bail!("HTTP {} for {}", status, url);
    }

    let body = resp.text().await?;
    let text = html_to_text(&body);

    // Truncate to reasonable size for LLM context
    if text.len() > 8000 {
        Ok(format!("{}...\n[truncated, {} chars total]", &text[..8000], text.len()))
    } else {
        Ok(text)
    }
}

/// Crude HTML-to-text conversion: strips tags, decodes common entities.
fn html_to_text(html: &str) -> String {
    let mut result = String::with_capacity(html.len() / 2);
    let mut in_tag = false;
    let mut in_script = false;
    let mut last_was_space = false;

    let lower = html.to_lowercase();
    let chars: Vec<char> = html.chars().collect();
    let lower_chars: Vec<char> = lower.chars().collect();

    let mut i = 0;
    while i < chars.len() {
        if !in_tag && !in_script && chars[i] == '<' {
            // Check for <script or <style
            let rest: String = lower_chars[i..].iter().take(10).collect();
            if rest.starts_with("<script") || rest.starts_with("<style") {
                in_script = true;
            }
            in_tag = true;
            i += 1;
            continue;
        }
        if in_tag && chars[i] == '>' {
            if in_script {
                let rest: String = lower_chars[i.saturating_sub(8)..=i].iter().collect();
                if rest.contains("/script>") || rest.contains("/style>") {
                    in_script = false;
                }
            }
            in_tag = false;
            i += 1;
            continue;
        }
        if in_tag || in_script {
            i += 1;
            continue;
        }
        // Entity decoding
        if chars[i] == '&' {
            let rest: String = chars[i..].iter().take(10).collect();
            if rest.starts_with("&amp;") {
                result.push('&');
                i += 5;
                last_was_space = false;
                continue;
            } else if rest.starts_with("&lt;") {
                result.push('<');
                i += 4;
                last_was_space = false;
                continue;
            } else if rest.starts_with("&gt;") {
                result.push('>');
                i += 4;
                last_was_space = false;
                continue;
            } else if rest.starts_with("&quot;") {
                result.push('"');
                i += 6;
                last_was_space = false;
                continue;
            } else if rest.starts_with("&nbsp;") {
                result.push(' ');
                i += 6;
                last_was_space = true;
                continue;
            }
        }
        // Collapse whitespace
        if chars[i].is_whitespace() {
            if !last_was_space {
                result.push(' ');
                last_was_space = true;
            }
        } else {
            result.push(chars[i]);
            last_was_space = false;
        }
        i += 1;
    }
    result.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_browser_step_variants() {
        assert!(matches!(
            parse_step("open:https://example.com").unwrap(),
            BrowserStep::Open(_)
        ));
        assert!(matches!(parse_step("title").unwrap(), BrowserStep::Title));
        assert!(parse_step("unknown").is_err());
    }

    #[test]
    fn policy_blocks_disallowed_domain() {
        let policy = BrowserPolicy {
            allowed_domains: vec!["example.com".to_string()],
            blocked_domains: vec!["localhost".to_string()],
            max_steps: 5,
            timeout_seconds: 5,
        };
        assert!(enforce_policy(&policy, "https://example.com/page").is_ok());
        assert!(enforce_policy(&policy, "https://localhost").is_err());
        assert!(enforce_policy(&policy, "https://not-allowed.org").is_err());
    }
}
