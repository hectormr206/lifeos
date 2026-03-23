//! Privacy filter — Classifies data sensitivity and sanitizes content
//! before it leaves the local machine via external LLM APIs.

use log::debug;

use serde::{Deserialize, Serialize};

/// How strict is the user about data leaving the machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PrivacyLevel {
    /// Everything stays local. No external API calls ever.
    Paranoid,
    /// Default. Sanitize everything. Only trusted providers for medium-sensitivity data.
    Careful,
    /// Sanitize critical data. Allow all providers for non-sensitive tasks.
    Balanced,
    /// Everything goes to the fastest/cheapest provider available.
    Open,
}

impl Default for PrivacyLevel {
    fn default() -> Self {
        Self::Careful
    }
}

/// How sensitive is a specific piece of data.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SensitivityLevel {
    /// Public info, open source code, generic questions
    Low,
    /// System config, non-personal logs, generic documents
    Medium,
    /// Personal conversations, email content, work documents
    High,
    /// Passwords, API keys, financial data, medical info, intimate memories
    Critical,
}

/// Result of running the privacy filter on content.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilterResult {
    pub sanitized_text: String,
    pub sensitivity: SensitivityLevel,
    pub redactions: Vec<Redaction>,
    pub original_length: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Redaction {
    pub pattern_type: String,
    pub count: u32,
}

/// The privacy filter.
pub struct PrivacyFilter {
    pub level: PrivacyLevel,
}

impl PrivacyFilter {
    pub fn new(level: PrivacyLevel) -> Self {
        Self { level }
    }

    /// Classify the sensitivity of text content.
    pub fn classify(&self, text: &str) -> SensitivityLevel {
        // Critical patterns — never send externally
        if has_critical_patterns(text) {
            return SensitivityLevel::Critical;
        }

        // High sensitivity patterns
        if has_high_sensitivity_patterns(text) {
            return SensitivityLevel::High;
        }

        // Medium sensitivity
        if has_medium_sensitivity_patterns(text) {
            return SensitivityLevel::Medium;
        }

        SensitivityLevel::Low
    }

    /// Sanitize text by redacting sensitive patterns.
    /// Returns the cleaned text and metadata about what was redacted.
    pub fn sanitize(&self, text: &str) -> FilterResult {
        let original_length = text.len();
        let mut sanitized = text.to_string();
        let mut redactions = Vec::new();

        // Redact API keys / tokens (long hex/base64 strings)
        let api_key_count = redact_pattern(
            &mut sanitized,
            &[
                // Generic API key patterns
                r"(?i)(api[_-]?key|token|secret|password|passwd|pwd)\s*[=:]\s*\S+",
                // Bearer tokens
                r"Bearer\s+[A-Za-z0-9_\-\.]+",
                // Long hex strings (32+ chars, likely tokens)
                r"\b[0-9a-fA-F]{32,}\b",
            ],
        );
        if api_key_count > 0 {
            redactions.push(Redaction {
                pattern_type: "api_key_or_token".into(),
                count: api_key_count,
            });
        }

        // Redact email addresses
        let email_count = redact_pattern(
            &mut sanitized,
            &[r"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"],
        );
        if email_count > 0 {
            redactions.push(Redaction {
                pattern_type: "email".into(),
                count: email_count,
            });
        }

        // Redact credit card numbers
        let cc_count = redact_pattern(
            &mut sanitized,
            &[r"\b\d{4}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{4}\b"],
        );
        if cc_count > 0 {
            redactions.push(Redaction {
                pattern_type: "credit_card".into(),
                count: cc_count,
            });
        }

        // Redact phone numbers (international format)
        let phone_count = redact_pattern(
            &mut sanitized,
            &[r"\+?\d{1,3}[\s\-]?\(?\d{2,4}\)?[\s\-]?\d{3,4}[\s\-]?\d{3,4}"],
        );
        if phone_count > 0 {
            redactions.push(Redaction {
                pattern_type: "phone_number".into(),
                count: phone_count,
            });
        }

        // Redact IP addresses (private ranges especially)
        let ip_count = redact_pattern(
            &mut sanitized,
            &[r"\b(?:192\.168|10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b"],
        );
        if ip_count > 0 {
            redactions.push(Redaction {
                pattern_type: "private_ip".into(),
                count: ip_count,
            });
        }

        let sensitivity = self.classify(&sanitized);

        debug!(
            "Privacy filter: {} -> {:?}, {} redactions, {} chars",
            original_length,
            sensitivity,
            redactions.iter().map(|r| r.count).sum::<u32>(),
            sanitized.len()
        );

        FilterResult {
            sanitized_text: sanitized,
            sensitivity,
            redactions,
            original_length,
        }
    }

    /// Check if content is safe to send to a given provider tier.
    pub fn is_safe_for_tier(
        &self,
        sensitivity: SensitivityLevel,
        tier: crate::llm_router::ProviderTier,
    ) -> bool {
        use crate::llm_router::ProviderTier;

        match self.level {
            PrivacyLevel::Paranoid => tier == ProviderTier::Local,
            PrivacyLevel::Careful => match sensitivity {
                SensitivityLevel::Critical => tier == ProviderTier::Local,
                SensitivityLevel::High => {
                    matches!(tier, ProviderTier::Local | ProviderTier::Premium)
                }
                SensitivityLevel::Medium => tier != ProviderTier::Cheap,
                SensitivityLevel::Low => true,
            },
            PrivacyLevel::Balanced => match sensitivity {
                SensitivityLevel::Critical => tier == ProviderTier::Local,
                SensitivityLevel::High => {
                    matches!(tier, ProviderTier::Local | ProviderTier::Premium)
                }
                _ => true,
            },
            PrivacyLevel::Open => true,
        }
    }
}

// ---------------------------------------------------------------------------
// Pattern detection helpers
// ---------------------------------------------------------------------------

fn has_critical_patterns(text: &str) -> bool {
    let lower = text.to_lowercase();
    let critical_keywords = [
        "password",
        "passwd",
        "contraseña",
        "secret_key",
        "private_key",
        "api_key",
        "access_token",
        "bearer ",
        "ssh-rsa ",
        "-----begin",
        "credit card",
        "tarjeta de credito",
        "social security",
        "ssn ",
    ];
    critical_keywords.iter().any(|kw| lower.contains(kw))
}

fn has_high_sensitivity_patterns(text: &str) -> bool {
    let lower = text.to_lowercase();
    let high_keywords = [
        "medical",
        "diagnosis",
        "prescription",
        "salary",
        "bank account",
        "cuenta bancaria",
        "enfermedad",
        "tratamiento",
        "relationship",
        "pareja",
        "personal life",
        "vida personal",
        "intimate",
        "confidential",
    ];
    high_keywords.iter().any(|kw| lower.contains(kw))
}

fn has_medium_sensitivity_patterns(text: &str) -> bool {
    let lower = text.to_lowercase();
    let medium_keywords = [
        "config",
        "hostname",
        "username",
        "ip address",
        "localhost",
        "internal",
        "employee",
        "empleado",
        "meeting notes",
        "notas de reunion",
    ];
    medium_keywords.iter().any(|kw| lower.contains(kw))
}

/// Replace all matches of the given regex-like patterns with [REDACTED].
/// Returns the count of replacements made.
///
/// NOTE: We use simple string matching for now to avoid adding the `regex`
/// crate. For production, consider switching to `regex` for more robust
/// pattern matching.
fn redact_pattern(text: &mut String, patterns: &[&str]) -> u32 {
    let mut count = 0u32;

    for pattern in patterns {
        // For simple keyword-based patterns, do substring replacement
        // This is a simplified approach — a full regex would be more robust
        if pattern.starts_with("(?i)") {
            // Case-insensitive keyword match
            let keyword = pattern
                .trim_start_matches("(?i)")
                .split("\\s")
                .next()
                .unwrap_or("")
                .replace(['(', ')'], "")
                .replace("[_-]?", "")
                .to_lowercase();
            if !keyword.is_empty() && text.to_lowercase().contains(&keyword) {
                // Find lines containing the keyword and redact the value part
                let lines: Vec<String> = text
                    .lines()
                    .map(|line| {
                        if line.to_lowercase().contains(&keyword) {
                            if let Some(eq_pos) = line.find('=').or_else(|| line.find(':')) {
                                count += 1;
                                format!("{}=[REDACTED]", &line[..eq_pos])
                            } else {
                                line.to_string()
                            }
                        } else {
                            line.to_string()
                        }
                    })
                    .collect();
                *text = lines.join("\n");
            }
        } else if pattern.contains("Bearer") {
            if let Some(pos) = text.find("Bearer ") {
                let end = text[pos + 7..]
                    .find(|c: char| c.is_whitespace())
                    .map(|p| pos + 7 + p)
                    .unwrap_or(text.len());
                text.replace_range(pos..end, "Bearer [REDACTED]");
                count += 1;
            }
        }
    }
    count
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_classify_low() {
        let filter = PrivacyFilter::new(PrivacyLevel::Careful);
        assert_eq!(
            filter.classify("How do I implement a queue in Rust?"),
            SensitivityLevel::Low
        );
    }

    #[test]
    fn test_classify_critical() {
        let filter = PrivacyFilter::new(PrivacyLevel::Careful);
        assert_eq!(
            filter.classify("my password is hunter2"),
            SensitivityLevel::Critical
        );
    }

    #[test]
    fn test_classify_high() {
        let filter = PrivacyFilter::new(PrivacyLevel::Careful);
        assert_eq!(
            filter.classify("my salary is $50000 and my bank account is 12345"),
            SensitivityLevel::High
        );
    }

    #[test]
    fn test_sanitize_bearer_token() {
        let filter = PrivacyFilter::new(PrivacyLevel::Careful);
        let result = filter.sanitize("Authorization: Bearer sk-abc123xyz");
        assert!(result.sanitized_text.contains("[REDACTED]"));
        assert!(!result.sanitized_text.contains("sk-abc123xyz"));
    }

    #[test]
    fn test_paranoid_only_local() {
        let filter = PrivacyFilter::new(PrivacyLevel::Paranoid);
        assert!(filter.is_safe_for_tier(
            SensitivityLevel::Low,
            crate::llm_router::ProviderTier::Local
        ));
        assert!(!filter.is_safe_for_tier(
            SensitivityLevel::Low,
            crate::llm_router::ProviderTier::Free
        ));
    }
}
