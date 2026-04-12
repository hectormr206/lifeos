//! Small string helpers shared across the daemon.
//!
//! Historically modules open-coded `&s[..max]` for "first N bytes",
//! which panics on UTF-8 inputs the moment `max` lands inside a
//! multi-byte character. In production (Hector's screen OCR capturing
//! '24°c') that pattern brought down the tokio worker driving the
//! screen capture pipeline. Prefer these helpers anywhere user
//! content is truncated for display or storage.

/// Return a prefix of `s` up to `max` **bytes**, but never split a
/// UTF-8 character. If `max` lands mid-character, walks backward to
/// the nearest char boundary. Safe for any input.
pub fn truncate_bytes_safe(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// Return a prefix of `s` with at most `max` **characters** (not
/// bytes). Useful when the caller wants a user-visible length limit
/// rather than a byte budget.
pub fn truncate_chars(s: &str, max_chars: usize) -> &str {
    match s.char_indices().nth(max_chars) {
        Some((byte_idx, _)) => &s[..byte_idx],
        None => s,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncate_bytes_safe_backs_off_from_midchar() {
        let s = "24°c"; // '°' is 2 bytes
        // max=3 would land inside '°' (bytes 2..4); expect truncation to "24"
        assert_eq!(truncate_bytes_safe(s, 3), "24");
    }

    #[test]
    fn truncate_bytes_safe_short_input_returns_full() {
        assert_eq!(truncate_bytes_safe("hi", 100), "hi");
    }

    #[test]
    fn truncate_chars_counts_characters_not_bytes() {
        let s = "héllo"; // 'é' is 2 bytes but 1 char
        assert_eq!(truncate_chars(s, 3), "hél");
    }

    #[test]
    fn truncate_chars_full_on_short_input() {
        assert_eq!(truncate_chars("hi", 10), "hi");
    }

    #[test]
    fn truncate_bytes_safe_empty() {
        assert_eq!(truncate_bytes_safe("", 10), "");
    }
}
