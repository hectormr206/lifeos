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

        // Redact SSNs (###-##-#### with optional dashes)
        let ssn_count = redact_ssns(&mut sanitized);
        if ssn_count > 0 {
            redactions.push(Redaction {
                pattern_type: "ssn".into(),
                count: ssn_count,
            });
        }

        // Redact 16 consecutive digits starting with 4/5/3/6 (credit cards without separators)
        let cc_nosep_count = redact_credit_cards_no_separator(&mut sanitized);
        if cc_nosep_count > 0 {
            redactions.push(Redaction {
                pattern_type: "credit_card".into(),
                count: cc_nosep_count,
            });
        }

        // Redact base64 tokens (32+ base64 chars that look like tokens)
        let b64_count = redact_base64_tokens(&mut sanitized);
        if b64_count > 0 {
            redactions.push(Redaction {
                pattern_type: "base64_token".into(),
                count: b64_count,
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

/// Replace all matches of sensitive patterns with [REDACTED].
/// Returns the count of replacements made.
/// Uses manual string scanning to avoid the `regex` crate dependency.
fn redact_pattern(text: &mut String, patterns: &[&str]) -> u32 {
    let mut count = 0u32;

    for pattern in patterns {
        if pattern.starts_with("(?i)") {
            // Case-insensitive keyword match for key=value / key: value lines
            let keyword = pattern
                .trim_start_matches("(?i)")
                .split("\\s")
                .next()
                .unwrap_or("")
                .replace(['(', ')'], "")
                .replace("[_-]?", "")
                .to_lowercase();
            if !keyword.is_empty() && text.to_lowercase().contains(&keyword) {
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
            // Redact Bearer tokens — search from an advancing offset to avoid infinite loop
            let mut search_from = 0;
            while let Some(rel_pos) = text[search_from..].find("Bearer ") {
                let pos = search_from + rel_pos;
                let after = pos + 7;
                // Skip already-redacted tokens
                if text[after..].starts_with("[REDACTED]") {
                    search_from = after + 10;
                    continue;
                }
                let end = text[after..]
                    .find(|c: char| c.is_whitespace())
                    .map(|p| after + p)
                    .unwrap_or(text.len());
                text.replace_range(pos..end, "Bearer [REDACTED]");
                count += 1;
                search_from = pos + 17; // len("Bearer [REDACTED]")
            }
        } else if pattern.contains("@") {
            // Email redaction: find word@word.tld patterns
            count += redact_emails(text);
        } else if pattern.contains("\\d{4}") && pattern.contains("\\d{4}") {
            // Credit card redaction: find 4-4-4-4 digit groups
            count += redact_credit_cards(text);
        } else if pattern.contains("\\+?\\d") {
            // Phone number redaction
            count += redact_phone_numbers(text);
        } else if pattern.contains("192\\.168") {
            // Private IP redaction
            count += redact_private_ips(text);
        }
    }
    count
}

/// Redact email addresses (word@domain.tld)
fn redact_emails(text: &mut String) -> u32 {
    let mut count = 0u32;
    let chars: Vec<char> = text.chars().collect();
    let mut result = String::with_capacity(text.len());
    let mut i = 0;

    while i < chars.len() {
        if chars[i] == '@' && i > 0 {
            // Find start of local part
            let mut start = i;
            while start > 0
                && (chars[start - 1].is_alphanumeric() || "._%+-".contains(chars[start - 1]))
            {
                start -= 1;
            }
            // Find end of domain
            let mut end = i + 1;
            while end < chars.len() && (chars[end].is_alphanumeric() || ".-".contains(chars[end])) {
                end += 1;
            }
            // Must have local part, @, and domain with dot
            let domain = &text[text.char_indices().nth(i + 1).map(|x| x.0).unwrap_or(i)
                ..text
                    .char_indices()
                    .nth(end)
                    .map(|x| x.0)
                    .unwrap_or(text.len())];
            if start < i && domain.contains('.') {
                // Replace everything from start to end
                let before_len = result.len() - (i - start);
                result.truncate(before_len);
                result.push_str("[EMAIL_REDACTED]");
                count += 1;
                i = end;
                continue;
            }
        }
        result.push(chars[i]);
        i += 1;
    }

    if count > 0 {
        *text = result;
    }
    count
}

/// Redact credit card numbers (groups of 4 digits separated by spaces or dashes)
fn redact_credit_cards(text: &mut String) -> u32 {
    let mut count = 0u32;
    let mut result = String::with_capacity(text.len());
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;

    while i < chars.len() {
        if chars[i].is_ascii_digit() {
            // Try to match 4-4-4-4 pattern
            let start = i;
            let mut groups = 0;
            let mut j = i;
            while groups < 4 && j < chars.len() {
                let mut digits = 0;
                while j < chars.len() && chars[j].is_ascii_digit() {
                    digits += 1;
                    j += 1;
                }
                if digits == 4 {
                    groups += 1;
                    if groups < 4 && j < chars.len() && (chars[j] == ' ' || chars[j] == '-') {
                        j += 1; // skip separator
                    }
                } else {
                    break;
                }
            }
            if groups == 4 {
                result.push_str("[CC_REDACTED]");
                count += 1;
                i = j;
                continue;
            }
            // Not a CC, emit the chars normally
            result.push(chars[start]);
            i = start + 1;
            continue;
        }
        result.push(chars[i]);
        i += 1;
    }

    if count > 0 {
        *text = result;
    }
    count
}

/// Redact phone numbers (sequences of 7+ digits with optional + prefix, spaces, dashes, parens)
fn redact_phone_numbers(text: &mut String) -> u32 {
    let mut count = 0u32;
    let mut result = String::with_capacity(text.len());
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;

    while i < chars.len() {
        if chars[i] == '+'
            || (chars[i].is_ascii_digit() && (i == 0 || !chars[i - 1].is_alphanumeric()))
        {
            let start = i;
            let mut j = i;
            let mut digit_count = 0;
            if chars[j] == '+' {
                j += 1;
            }
            while j < chars.len()
                && (chars[j].is_ascii_digit()
                    || chars[j] == ' '
                    || chars[j] == '-'
                    || chars[j] == '('
                    || chars[j] == ')')
            {
                if chars[j].is_ascii_digit() {
                    digit_count += 1;
                }
                j += 1;
            }
            // Phone numbers have 7-15 digits
            if (7..=15).contains(&digit_count) {
                // Don't match if preceded/followed by alphanumeric (might be hex or other data)
                let preceded_ok = start == 0 || !chars[start - 1].is_alphanumeric();
                let followed_ok = j >= chars.len() || !chars[j].is_alphanumeric();
                if preceded_ok && followed_ok {
                    result.push_str("[PHONE_REDACTED]");
                    count += 1;
                    i = j;
                    continue;
                }
            }
            result.push(chars[start]);
            i = start + 1;
            continue;
        }
        result.push(chars[i]);
        i += 1;
    }

    if count > 0 {
        *text = result;
    }
    count
}

/// Redact private IP addresses (192.168.x.x, 10.x.x.x, 172.16-31.x.x)
fn redact_private_ips(text: &mut String) -> u32 {
    let mut count = 0u32;
    let prefixes = ["192.168.", "10."];

    for prefix in &prefixes {
        while let Some(pos) = text.find(prefix) {
            let preceded_ok = pos == 0 || !text.as_bytes()[pos - 1].is_ascii_digit();
            if !preceded_ok {
                break;
            }
            let mut end = pos + prefix.len();
            let bytes = text.as_bytes();
            // Consume remaining octets (up to 2 more groups of digits.digits)
            let mut octets = 0;
            while end < bytes.len() && octets < 2 {
                let digit_start = end;
                while end < bytes.len() && bytes[end].is_ascii_digit() {
                    end += 1;
                }
                if end == digit_start {
                    break;
                }
                octets += 1;
                if octets < 2 && end < bytes.len() && bytes[end] == b'.' {
                    end += 1;
                }
            }
            if octets >= 1 {
                text.replace_range(pos..end, "[IP_REDACTED]");
                count += 1;
            } else {
                break;
            }
        }
    }

    // 172.16-31.x.x
    let mut search_from = 0;
    while let Some(pos) = text[search_from..].find("172.") {
        let abs_pos = search_from + pos;
        let preceded_ok = abs_pos == 0 || !text.as_bytes()[abs_pos - 1].is_ascii_digit();
        if !preceded_ok {
            search_from = abs_pos + 4;
            continue;
        }
        // Check second octet is 16-31
        let rest = &text[abs_pos + 4..];
        let dot_pos = rest.find('.');
        if let Some(dp) = dot_pos {
            if let Ok(second) = rest[..dp].parse::<u8>() {
                if (16..=31).contains(&second) {
                    // Find end of IP
                    let mut end = abs_pos + 4 + dp + 1;
                    let bytes = text.as_bytes();
                    let mut octets = 0;
                    while end < bytes.len() && octets < 2 {
                        let digit_start = end;
                        while end < bytes.len() && bytes[end].is_ascii_digit() {
                            end += 1;
                        }
                        if end == digit_start {
                            break;
                        }
                        octets += 1;
                        if octets < 2 && end < bytes.len() && bytes[end] == b'.' {
                            end += 1;
                        }
                    }
                    if octets >= 1 {
                        text.replace_range(abs_pos..end, "[IP_REDACTED]");
                        count += 1;
                        continue;
                    }
                }
            }
        }
        search_from = abs_pos + 4;
    }

    count
}

/// Redact SSNs: ###-##-#### with optional dashes
fn redact_ssns(text: &mut String) -> u32 {
    let mut count = 0u32;
    let mut result = String::with_capacity(text.len());
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;

    while i < chars.len() {
        if chars[i].is_ascii_digit() {
            let start = i;
            // Check not preceded by alphanumeric
            if start > 0 && chars[start - 1].is_alphanumeric() {
                result.push(chars[i]);
                i += 1;
                continue;
            }
            // Try to match ###-##-#### or ######### (9 digits)
            let mut digits = Vec::new();
            let mut j = i;
            while j < chars.len() && (chars[j].is_ascii_digit() || chars[j] == '-') {
                if chars[j].is_ascii_digit() {
                    digits.push(chars[j]);
                }
                j += 1;
                // Stop if we have enough digits
                if digits.len() == 9 {
                    break;
                }
            }
            if digits.len() == 9 {
                // Check not followed by digit
                let followed_ok = j >= chars.len() || !chars[j].is_ascii_digit();
                if followed_ok {
                    // Verify it looks like SSN: first 3 digits not 000 or 666 or 9xx
                    let area: u16 = (digits[0] as u16 - b'0' as u16) * 100
                        + (digits[1] as u16 - b'0' as u16) * 10
                        + (digits[2] as u16 - b'0' as u16);
                    let group: u16 =
                        (digits[3] as u16 - b'0' as u16) * 10 + (digits[4] as u16 - b'0' as u16);
                    if area != 0 && area != 666 && area < 900 && group != 0 {
                        result.push_str("[SSN_REDACTED]");
                        count += 1;
                        i = j;
                        continue;
                    }
                }
            }
            result.push(chars[start]);
            i = start + 1;
            continue;
        }
        result.push(chars[i]);
        i += 1;
    }

    if count > 0 {
        *text = result;
    }
    count
}

/// Redact 16 consecutive digits starting with 4, 5, 3, or 6 (credit cards without separators)
fn redact_credit_cards_no_separator(text: &mut String) -> u32 {
    let mut count = 0u32;
    let mut result = String::with_capacity(text.len());
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;

    while i < chars.len() {
        if chars[i].is_ascii_digit()
            && (i == 0 || !chars[i - 1].is_ascii_digit())
            && "3456".contains(chars[i])
        {
            // Count consecutive digits
            let start = i;
            let mut j = i;
            while j < chars.len() && chars[j].is_ascii_digit() {
                j += 1;
            }
            let digit_count = j - start;
            if digit_count == 16 && (j >= chars.len() || !chars[j].is_ascii_digit()) {
                result.push_str("[CC_REDACTED]");
                count += 1;
                i = j;
                continue;
            }
            // Not a match, emit first char and continue
            result.push(chars[start]);
            i = start + 1;
            continue;
        }
        result.push(chars[i]);
        i += 1;
    }

    if count > 0 {
        *text = result;
    }
    count
}

/// Redact base64 tokens: sequences of 32+ base64 chars (A-Z, a-z, 0-9, +, /, =)
/// that are bounded by non-base64 characters.
fn redact_base64_tokens(text: &mut String) -> u32 {
    let mut count = 0u32;
    let mut result = String::with_capacity(text.len());
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;

    let is_base64_char =
        |c: char| c.is_ascii_alphanumeric() || c == '+' || c == '/' || c == '=' || c == '_' || c == '-';

    while i < chars.len() {
        if is_base64_char(chars[i]) && (i == 0 || chars[i - 1].is_whitespace() || chars[i - 1] == '"' || chars[i - 1] == '\'' || chars[i - 1] == ':' || chars[i - 1] == '=') {
            let start = i;
            while i < chars.len() && is_base64_char(chars[i]) {
                i += 1;
            }
            let token_len = i - start;
            if token_len >= 32 {
                result.push_str("[BASE64_REDACTED]");
                count += 1;
            } else {
                // Not long enough, keep original
                for c in &chars[start..i] {
                    result.push(*c);
                }
            }
            continue;
        }
        result.push(chars[i]);
        i += 1;
    }

    if count > 0 {
        *text = result;
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
    fn test_sanitize_email() {
        let filter = PrivacyFilter::new(PrivacyLevel::Careful);
        let result = filter.sanitize("contact me at user@example.com please");
        assert!(result.sanitized_text.contains("[EMAIL_REDACTED]"));
        assert!(!result.sanitized_text.contains("user@example.com"));
    }

    #[test]
    fn test_sanitize_credit_card() {
        let filter = PrivacyFilter::new(PrivacyLevel::Careful);
        let result = filter.sanitize("my card is 4111 1111 1111 1111 ok");
        assert!(result.sanitized_text.contains("[CC_REDACTED]"));
        assert!(!result.sanitized_text.contains("4111"));
    }

    #[test]
    fn test_sanitize_phone() {
        let filter = PrivacyFilter::new(PrivacyLevel::Careful);
        let result = filter.sanitize("call me at +52 55 1234 5678");
        assert!(result.sanitized_text.contains("[PHONE_REDACTED]"));
        assert!(!result.sanitized_text.contains("1234"));
    }

    #[test]
    fn test_sanitize_private_ip() {
        let filter = PrivacyFilter::new(PrivacyLevel::Careful);
        let result = filter.sanitize("server at 192.168.1.100 internal");
        assert!(result.sanitized_text.contains("[IP_REDACTED]"));
        assert!(!result.sanitized_text.contains("192.168"));
    }

    #[test]
    fn test_paranoid_only_local() {
        let filter = PrivacyFilter::new(PrivacyLevel::Paranoid);
        assert!(filter.is_safe_for_tier(
            SensitivityLevel::Low,
            crate::llm_router::ProviderTier::Local
        ));
        assert!(
            !filter.is_safe_for_tier(SensitivityLevel::Low, crate::llm_router::ProviderTier::Free)
        );
    }

    #[test]
    fn test_sanitize_ssn_with_dashes() {
        let filter = PrivacyFilter::new(PrivacyLevel::Careful);
        let result = filter.sanitize("my ssn is 123-45-6789 ok");
        assert!(result.sanitized_text.contains("[SSN_REDACTED]"));
        assert!(!result.sanitized_text.contains("123-45-6789"));
    }

    #[test]
    fn test_sanitize_ssn_without_dashes() {
        let filter = PrivacyFilter::new(PrivacyLevel::Careful);
        let result = filter.sanitize("ssn 123456789 here");
        assert!(result.sanitized_text.contains("[SSN_REDACTED]"));
        assert!(!result.sanitized_text.contains("123456789"));
    }

    #[test]
    fn test_sanitize_cc_no_separator() {
        let filter = PrivacyFilter::new(PrivacyLevel::Careful);
        let result = filter.sanitize("card 4111111111111111 done");
        assert!(result.sanitized_text.contains("[CC_REDACTED]"));
        assert!(!result.sanitized_text.contains("4111111111111111"));
    }

    #[test]
    fn test_sanitize_base64_token() {
        let filter = PrivacyFilter::new(PrivacyLevel::Careful);
        let result = filter.sanitize("key: ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123456789+/== end");
        assert!(result.sanitized_text.contains("[BASE64_REDACTED]"));
    }

    #[test]
    fn test_sanitize_short_base64_not_redacted() {
        let filter = PrivacyFilter::new(PrivacyLevel::Careful);
        let result = filter.sanitize("short token ABC123 here");
        assert!(!result.sanitized_text.contains("[BASE64_REDACTED]"));
    }
}
