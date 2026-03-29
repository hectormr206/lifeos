//! Time Context — IANA timezone detection, storage, and UTC conversion.
//!
//! Provides timezone-aware time handling for the entire daemon:
//! - Auto-detects system IANA timezone (e.g., "America/Mexico_City")
//! - Persists user timezone preference to `/var/lib/lifeos/timezone`
//! - Converts between local and UTC for calendar events and memory queries
//!
//! Used by: calendar (AM.4/AM.6), memory_plane (AM.5), API settings endpoint (AM.3).

use anyhow::Result;
use chrono::{DateTime, FixedOffset, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Utc};
use log::{info, warn};

const TIMEZONE_FILE: &str = "/var/lib/lifeos/timezone";

/// Get the user's IANA timezone string (e.g., "America/Mexico_City").
///
/// Resolution order:
/// 1. System timezone via `iana_time_zone::get_timezone()`
/// 2. Saved config file at `/var/lib/lifeos/timezone`
/// 3. Fallback to `"UTC"`
pub fn get_user_timezone() -> String {
    // 1. Try system timezone
    if let Ok(tz) = iana_time_zone::get_timezone() {
        if !tz.is_empty() {
            return tz;
        }
    }

    // 2. Try saved config file
    let config_path = std::path::Path::new(TIMEZONE_FILE);
    if let Ok(tz) = std::fs::read_to_string(config_path) {
        let tz = tz.trim().to_string();
        if !tz.is_empty() {
            return tz;
        }
    }

    // 3. Fallback
    "UTC".to_string()
}

/// Save the user's timezone preference to persistent storage.
pub fn save_user_timezone(tz: &str) -> Result<()> {
    // Validate the timezone string before saving
    if !is_valid_iana_timezone(tz) {
        anyhow::bail!("Invalid IANA timezone: {}", tz);
    }

    let path = std::path::Path::new(TIMEZONE_FILE);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, tz)?;
    info!("Timezone saved: {}", tz);
    Ok(())
}

/// Check if a string is a valid IANA timezone by attempting to parse it.
pub fn is_valid_iana_timezone(tz: &str) -> bool {
    let tz = tz.trim();
    if tz.is_empty() {
        return false;
    }
    // "UTC" is always valid
    if tz == "UTC" {
        return true;
    }
    // IANA timezones follow "Region/City" or "Region/Sub/City" pattern
    let parts: Vec<&str> = tz.split('/').collect();
    if parts.len() < 2 || parts.len() > 3 {
        return false;
    }
    // Each part should be non-empty and contain only alphanumeric, underscore, or hyphen
    parts.iter().all(|p| {
        !p.is_empty()
            && p.chars()
                .all(|c| c.is_alphanumeric() || c == '_' || c == '-')
    })
}

/// Parse a local date+time string in the user's timezone and convert to UTC RFC3339.
///
/// Accepts formats like:
/// - "2026-03-28T15:00:00" (ISO without offset)
/// - "2026-03-28 15:00"
/// - Already RFC3339 with offset — returned as-is converted to UTC
pub fn local_to_utc(datetime_str: &str, iana_tz: &str) -> Result<DateTime<Utc>> {
    let trimmed = datetime_str.trim();

    // If it already parses as RFC3339 (has offset info), just convert
    if let Ok(dt) = DateTime::parse_from_rfc3339(trimmed) {
        return Ok(dt.with_timezone(&Utc));
    }

    // Try parsing as naive datetime
    let naive = if let Ok(ndt) = NaiveDateTime::parse_from_str(trimmed, "%Y-%m-%dT%H:%M:%S") {
        ndt
    } else if let Ok(ndt) = NaiveDateTime::parse_from_str(trimmed, "%Y-%m-%dT%H:%M") {
        ndt
    } else if let Ok(ndt) = NaiveDateTime::parse_from_str(trimmed, "%Y-%m-%d %H:%M:%S") {
        ndt
    } else if let Ok(ndt) = NaiveDateTime::parse_from_str(trimmed, "%Y-%m-%d %H:%M") {
        ndt
    } else {
        anyhow::bail!(
            "Cannot parse datetime '{}'. Expected format: YYYY-MM-DDTHH:MM:SS or YYYY-MM-DD HH:MM",
            trimmed
        );
    };

    // Get UTC offset for this IANA timezone
    let offset = resolve_tz_offset(iana_tz)?;
    let local_dt = offset.from_local_datetime(&naive).single().ok_or_else(|| {
        anyhow::anyhow!("Ambiguous or invalid local time for timezone {}", iana_tz)
    })?;

    Ok(local_dt.with_timezone(&Utc))
}

/// Convert a UTC datetime to a local datetime string in the given IANA timezone.
/// Used by calendar event display and memory search result formatting.
pub fn utc_to_local(utc_dt: &DateTime<Utc>, iana_tz: &str) -> Result<String> {
    let offset = resolve_tz_offset(iana_tz)?;
    let local = utc_dt.with_timezone(&offset);
    Ok(local.format("%Y-%m-%d %H:%M:%S").to_string())
}

/// Build UTC range for a date + time range in a given timezone.
/// Used by memory time-range queries (AM.5).
///
/// Returns (from_utc_rfc3339, to_utc_rfc3339).
pub fn date_time_range_to_utc(
    date: &str,
    time_from: &str,
    time_to: &str,
    iana_tz: &str,
) -> Result<(String, String)> {
    let naive_date = NaiveDate::parse_from_str(date, "%Y-%m-%d")
        .map_err(|e| anyhow::anyhow!("Invalid date '{}': {}", date, e))?;

    let from_time = NaiveTime::parse_from_str(time_from, "%H:%M")
        .or_else(|_| NaiveTime::parse_from_str(time_from, "%H:%M:%S"))
        .map_err(|e| anyhow::anyhow!("Invalid time_from '{}': {}", time_from, e))?;

    let to_time = NaiveTime::parse_from_str(time_to, "%H:%M")
        .or_else(|_| NaiveTime::parse_from_str(time_to, "%H:%M:%S"))
        .map_err(|e| anyhow::anyhow!("Invalid time_to '{}': {}", time_to, e))?;

    let from_naive = NaiveDateTime::new(naive_date, from_time);
    let to_naive = NaiveDateTime::new(naive_date, to_time);

    let offset = resolve_tz_offset(iana_tz)?;

    let from_utc = offset
        .from_local_datetime(&from_naive)
        .single()
        .ok_or_else(|| anyhow::anyhow!("Ambiguous from time"))?
        .with_timezone(&Utc);

    let to_utc = offset
        .from_local_datetime(&to_naive)
        .single()
        .ok_or_else(|| anyhow::anyhow!("Ambiguous to time"))?
        .with_timezone(&Utc);

    Ok((from_utc.to_rfc3339(), to_utc.to_rfc3339()))
}

/// Resolve the UTC offset for an IANA timezone.
///
/// Uses the system `date` command with `TZ` env var to get the current offset
/// for the given timezone. Falls back to the system's local offset.
fn resolve_tz_offset(iana_tz: &str) -> Result<FixedOffset> {
    if iana_tz == "UTC" {
        return Ok(FixedOffset::east_opt(0).unwrap());
    }

    // Check that zoneinfo exists for this timezone
    let zoneinfo_path = format!("/usr/share/zoneinfo/{}", iana_tz);
    if !std::path::Path::new(&zoneinfo_path).exists() {
        warn!(
            "Zoneinfo file not found for '{}', falling back to system offset",
            iana_tz
        );
        let local_now = chrono::Local::now();
        let offset_secs = local_now.offset().local_minus_utc();
        return FixedOffset::east_opt(offset_secs)
            .ok_or_else(|| anyhow::anyhow!("Invalid offset seconds: {}", offset_secs));
    }

    // Use TZ env to compute offset via `date +%z`
    let output = std::process::Command::new("date")
        .arg("+%z")
        .env("TZ", iana_tz)
        .output();

    match output {
        Ok(out) if out.status.success() => {
            let offset_str = String::from_utf8_lossy(&out.stdout).trim().to_string();
            parse_tz_offset(&offset_str)
        }
        _ => {
            let local_now = chrono::Local::now();
            let offset_secs = local_now.offset().local_minus_utc();
            FixedOffset::east_opt(offset_secs)
                .ok_or_else(|| anyhow::anyhow!("Invalid offset seconds: {}", offset_secs))
        }
    }
}

/// Parse a timezone offset string like "+0530" or "-0600" into a FixedOffset.
fn parse_tz_offset(s: &str) -> Result<FixedOffset> {
    let s = s.trim();
    if s.len() < 5 {
        anyhow::bail!("Invalid offset format: '{}'", s);
    }

    let sign = match s.as_bytes()[0] {
        b'+' => 1,
        b'-' => -1,
        _ => anyhow::bail!("Invalid offset sign in '{}'", s),
    };

    let hours: i32 = s[1..3]
        .parse()
        .map_err(|_| anyhow::anyhow!("Invalid offset hours in '{}'", s))?;
    let minutes: i32 = s[3..5]
        .parse()
        .map_err(|_| anyhow::anyhow!("Invalid offset minutes in '{}'", s))?;

    let total_seconds = sign * (hours * 3600 + minutes * 60);
    FixedOffset::east_opt(total_seconds)
        .ok_or_else(|| anyhow::anyhow!("Offset out of range: {} seconds", total_seconds))
}

// ---------------------------------------------------------------------------
// LLM prompt injection — time context blocks (AM.1 / AM.2)
// ---------------------------------------------------------------------------

/// Generate a time context block for LLM system prompts.
/// Call this FRESH for every LLM request (do not cache).
pub fn time_context() -> String {
    let now = chrono::Local::now();
    let tz_name = get_user_timezone();
    let offset = now.format("%:z").to_string(); // e.g., "-06:00"

    // Day of week in Spanish
    let day_name = match now.format("%u").to_string().as_str() {
        "1" => "lunes",
        "2" => "martes",
        "3" => "miercoles",
        "4" => "jueves",
        "5" => "viernes",
        "6" => "sabado",
        "7" => "domingo",
        _ => "desconocido",
    };

    format!(
        "[Contexto temporal — SIEMPRE usar esta hora, NUNCA inventar otra]\n\
         Fecha: {}\n\
         Hora: {}\n\
         Dia: {}\n\
         Zona horaria: {} (UTC{})\n\
         Timestamp UTC: {}",
        now.format("%Y-%m-%d"),
        now.format("%H:%M:%S"),
        day_name,
        tz_name,
        offset,
        Utc::now().format("%Y-%m-%dT%H:%M:%SZ"),
    )
}

/// Short time context for space-constrained prompts.
pub fn time_context_short() -> String {
    let now = chrono::Local::now();
    format!(
        "[Hora actual: {} {}]",
        now.format("%Y-%m-%d %H:%M"),
        now.format("%:z")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_user_timezone_returns_string() {
        let tz = get_user_timezone();
        assert!(!tz.is_empty());
    }

    #[test]
    fn test_is_valid_iana_timezone() {
        assert!(is_valid_iana_timezone("America/Mexico_City"));
        assert!(is_valid_iana_timezone("UTC"));
        assert!(is_valid_iana_timezone("Europe/London"));
        assert!(is_valid_iana_timezone("Asia/Kolkata"));
        assert!(!is_valid_iana_timezone(""));
        assert!(!is_valid_iana_timezone("NotATimezone"));
        assert!(!is_valid_iana_timezone("America/"));
    }

    #[test]
    fn test_local_to_utc_with_rfc3339() {
        let result = local_to_utc("2026-03-28T12:00:00+00:00", "UTC").unwrap();
        assert_eq!(result.format("%H:%M").to_string(), "12:00");
    }

    #[test]
    fn test_local_to_utc_naive_utc() {
        let result = local_to_utc("2026-03-28T15:00:00", "UTC").unwrap();
        assert_eq!(result.format("%H:%M").to_string(), "15:00");
    }

    #[test]
    fn test_utc_to_local_utc() {
        let dt = Utc::now();
        let local = utc_to_local(&dt, "UTC").unwrap();
        assert!(!local.is_empty());
    }

    #[test]
    fn test_date_time_range_to_utc() {
        let (from, to) = date_time_range_to_utc("2026-03-28", "09:00", "17:00", "UTC").unwrap();
        assert!(from.contains("2026-03-28"));
        assert!(from < to);
    }

    #[test]
    fn test_parse_tz_offset() {
        let offset = parse_tz_offset("+0530").unwrap();
        assert_eq!(offset.local_minus_utc(), 5 * 3600 + 30 * 60);

        let offset = parse_tz_offset("-0600").unwrap();
        assert_eq!(offset.local_minus_utc(), -(6 * 3600));
    }

    #[test]
    fn test_time_context_contains_required_fields() {
        let ctx = time_context();
        assert!(ctx.contains("Contexto temporal"));
        assert!(ctx.contains("Fecha:"));
        assert!(ctx.contains("Hora:"));
        assert!(ctx.contains("Dia:"));
        assert!(ctx.contains("Zona horaria:"));
        assert!(ctx.contains("Timestamp UTC:"));
    }

    #[test]
    fn test_time_context_short_format() {
        let ctx = time_context_short();
        assert!(ctx.starts_with("[Hora actual:"));
        assert!(ctx.ends_with(']'));
    }
}
