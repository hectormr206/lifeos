//! Intent Parser (Fase X)
//!
//! Converts natural language (Spanish + English) into structured intents
//! that the agent runtime can dispatch to appropriate handlers.

use log::debug;
use serde::{Deserialize, Serialize};

/// A structured intent parsed from natural language.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Intent {
    pub action: IntentAction,
    pub entities: Vec<IntentEntity>,
    pub constraints: Vec<String>,
    pub raw_text: String,
}

/// Recognized intent actions mapped from verbs in Spanish and English.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum IntentAction {
    Schedule,
    Send,
    Open,
    Close,
    Install,
    Search,
    Create,
    Delete,
    Translate,
    Configure,
    Monitor,
    Remind,
    Other(String),
}

/// An entity extracted from the natural language input.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntentEntity {
    /// Display name or label
    pub name: String,
    /// Semantic type: "person", "app", "file", "url", "date", "time", "email"
    pub entity_type: String,
    /// Raw extracted value
    pub value: String,
}

// ---------------------------------------------------------------------------
// Verb → Action mappings (lowercase)
// ---------------------------------------------------------------------------

const SCHEDULE_VERBS: &[&str] = &["agenda", "programa", "schedule", "calendariza", "planifica"];
const SEND_VERBS: &[&str] = &["envia", "envía", "manda", "send", "mail"];
const OPEN_VERBS: &[&str] = &["abre", "open", "lanza", "launch", "ejecuta", "run"];
const CLOSE_VERBS: &[&str] = &["cierra", "close", "termina", "kill", "stop", "para"];
const INSTALL_VERBS: &[&str] = &["instala", "install", "descarga", "download"];
const SEARCH_VERBS: &[&str] = &["busca", "search", "encuentra", "find", "grep"];
const CREATE_VERBS: &[&str] = &["crea", "create", "nuevo", "new", "genera", "generate"];
const DELETE_VERBS: &[&str] = &["borra", "elimina", "delete", "remove", "rm"];
const TRANSLATE_VERBS: &[&str] = &["traduce", "translate"];
const CONFIGURE_VERBS: &[&str] = &["configura", "configure", "setup", "ajusta", "settings"];
const MONITOR_VERBS: &[&str] = &["monitorea", "monitor", "vigila", "watch", "observa"];
const REMIND_VERBS: &[&str] = &[
    "recuerda",
    "recuerdame",
    "remind",
    "reminder",
    "avisa",
    "alerta",
];

// ---------------------------------------------------------------------------
// Regex helpers (compiled once via lazy_static-style approach)
// ---------------------------------------------------------------------------

fn match_email(text: &str) -> Vec<IntentEntity> {
    let mut entities = Vec::new();
    // Simple email regex
    for word in text.split_whitespace() {
        let clean = word.trim_matches(|c: char| {
            !c.is_alphanumeric() && c != '@' && c != '.' && c != '_' && c != '-'
        });
        if clean.contains('@') && clean.contains('.') && clean.len() > 5 {
            entities.push(IntentEntity {
                name: clean.to_string(),
                entity_type: "email".into(),
                value: clean.to_string(),
            });
        }
    }
    entities
}

fn match_urls(text: &str) -> Vec<IntentEntity> {
    let mut entities = Vec::new();
    for word in text.split_whitespace() {
        let lower = word.to_lowercase();
        if lower.starts_with("http://")
            || lower.starts_with("https://")
            || lower.starts_with("www.")
        {
            entities.push(IntentEntity {
                name: word.to_string(),
                entity_type: "url".into(),
                value: word.to_string(),
            });
        }
    }
    entities
}

fn match_file_paths(text: &str) -> Vec<IntentEntity> {
    let mut entities = Vec::new();
    for word in text.split_whitespace() {
        if (word.starts_with('/') || word.starts_with("~/") || word.starts_with("./"))
            && word.len() > 2
        {
            entities.push(IntentEntity {
                name: word.to_string(),
                entity_type: "file".into(),
                value: word.to_string(),
            });
        }
    }
    entities
}

fn match_times(text: &str) -> Vec<IntentEntity> {
    let mut entities = Vec::new();
    let words: Vec<&str> = text.split_whitespace().collect();
    for (i, word) in words.iter().enumerate() {
        let lower = word.to_lowercase();
        // HH:MM patterns
        if lower.contains(':') {
            let parts: Vec<&str> = lower.split(':').collect();
            if parts.len() == 2 {
                if let (Ok(h), Ok(m)) = (parts[0].parse::<u32>(), parts[1].parse::<u32>()) {
                    if h < 24 && m < 60 {
                        entities.push(IntentEntity {
                            name: format!("{}:{:02}", h, m),
                            entity_type: "time".into(),
                            value: lower.clone(),
                        });
                    }
                }
            }
        }
        // "a las X" (Spanish)
        if lower == "las" && i > 0 && words[i - 1].to_lowercase() == "a" {
            if let Some(next) = words.get(i + 1) {
                if let Ok(h) = next.parse::<u32>() {
                    if h < 24 {
                        entities.push(IntentEntity {
                            name: format!("{}:00", h),
                            entity_type: "time".into(),
                            value: format!("a las {}", next),
                        });
                    }
                }
            }
        }
        // "at X" (English)
        if lower == "at" {
            if let Some(next) = words.get(i + 1) {
                if let Ok(h) = next.parse::<u32>() {
                    if h < 24 {
                        entities.push(IntentEntity {
                            name: format!("{}:00", h),
                            entity_type: "time".into(),
                            value: format!("at {}", next),
                        });
                    }
                }
            }
        }
    }
    entities
}

fn match_dates(text: &str) -> Vec<IntentEntity> {
    let mut entities = Vec::new();
    let lower = text.to_lowercase();

    // Named day shortcuts (Spanish + English)
    let day_keywords = [
        ("hoy", "today"),
        ("manana", "tomorrow"),
        ("mañana", "tomorrow"),
        ("tomorrow", "tomorrow"),
        ("today", "today"),
        ("lunes", "monday"),
        ("martes", "tuesday"),
        ("miercoles", "wednesday"),
        ("miércoles", "wednesday"),
        ("jueves", "thursday"),
        ("viernes", "friday"),
        ("sabado", "saturday"),
        ("sábado", "saturday"),
        ("domingo", "sunday"),
        ("monday", "monday"),
        ("tuesday", "tuesday"),
        ("wednesday", "wednesday"),
        ("thursday", "thursday"),
        ("friday", "friday"),
        ("saturday", "saturday"),
        ("sunday", "sunday"),
    ];

    for (keyword, canonical) in &day_keywords {
        if lower.contains(keyword) {
            entities.push(IntentEntity {
                name: canonical.to_string(),
                entity_type: "date".into(),
                value: keyword.to_string(),
            });
        }
    }

    // dd/mm/yyyy or dd-mm-yyyy patterns
    for word in text.split_whitespace() {
        let clean = word.trim_matches(|c: char| !c.is_ascii_digit() && c != '/' && c != '-');
        let parts: Vec<&str> = if clean.contains('/') {
            clean.split('/').collect()
        } else if clean.contains('-') && clean.len() <= 10 {
            clean.split('-').collect()
        } else {
            vec![]
        };
        if parts.len() == 3 {
            if let (Ok(a), Ok(b), Ok(c)) = (
                parts[0].parse::<u32>(),
                parts[1].parse::<u32>(),
                parts[2].parse::<u32>(),
            ) {
                // Accept dd/mm/yyyy or yyyy-mm-dd
                if (a <= 31 && b <= 12 && c >= 2000) || (a >= 2000 && b <= 12 && c <= 31) {
                    entities.push(IntentEntity {
                        name: clean.to_string(),
                        entity_type: "date".into(),
                        value: clean.to_string(),
                    });
                }
            }
        }
    }

    entities
}

/// Well-known application names to detect.
const KNOWN_APPS: &[&str] = &[
    "firefox",
    "chromium",
    "terminal",
    "code",
    "vscode",
    "nautilus",
    "files",
    "spotify",
    "discord",
    "telegram",
    "slack",
    "gimp",
    "blender",
    "steam",
    "libreoffice",
    "thunderbird",
    "vlc",
    "obs",
    "flatpak",
];

fn match_apps(text: &str) -> Vec<IntentEntity> {
    let lower = text.to_lowercase();
    let mut entities = Vec::new();
    for app in KNOWN_APPS {
        if lower.contains(app) {
            entities.push(IntentEntity {
                name: app.to_string(),
                entity_type: "app".into(),
                value: app.to_string(),
            });
        }
    }
    entities
}

// ---------------------------------------------------------------------------
// Core parse function
// ---------------------------------------------------------------------------

/// Map the first verb-like word in the text to an IntentAction.
fn detect_action(text: &str) -> IntentAction {
    let lower = text.to_lowercase();
    let first_word = lower.split_whitespace().next().unwrap_or("");

    // Check first word, then fall back to scanning the whole text for a verb
    let candidates = [first_word];

    for candidate in &candidates {
        if SCHEDULE_VERBS.contains(candidate) {
            return IntentAction::Schedule;
        }
        if SEND_VERBS.contains(candidate) {
            return IntentAction::Send;
        }
        if OPEN_VERBS.contains(candidate) {
            return IntentAction::Open;
        }
        if CLOSE_VERBS.contains(candidate) {
            return IntentAction::Close;
        }
        if INSTALL_VERBS.contains(candidate) {
            return IntentAction::Install;
        }
        if SEARCH_VERBS.contains(candidate) {
            return IntentAction::Search;
        }
        if CREATE_VERBS.contains(candidate) {
            return IntentAction::Create;
        }
        if DELETE_VERBS.contains(candidate) {
            return IntentAction::Delete;
        }
        if TRANSLATE_VERBS.contains(candidate) {
            return IntentAction::Translate;
        }
        if CONFIGURE_VERBS.contains(candidate) {
            return IntentAction::Configure;
        }
        if MONITOR_VERBS.contains(candidate) {
            return IntentAction::Monitor;
        }
        if REMIND_VERBS.contains(candidate) {
            return IntentAction::Remind;
        }
    }

    // Fallback: scan full text for verb keywords
    for word in lower.split_whitespace() {
        if SCHEDULE_VERBS.contains(&word) {
            return IntentAction::Schedule;
        }
        if SEND_VERBS.contains(&word) {
            return IntentAction::Send;
        }
        if OPEN_VERBS.contains(&word) {
            return IntentAction::Open;
        }
        if CLOSE_VERBS.contains(&word) {
            return IntentAction::Close;
        }
        if INSTALL_VERBS.contains(&word) {
            return IntentAction::Install;
        }
        if SEARCH_VERBS.contains(&word) {
            return IntentAction::Search;
        }
        if CREATE_VERBS.contains(&word) {
            return IntentAction::Create;
        }
        if DELETE_VERBS.contains(&word) {
            return IntentAction::Delete;
        }
        if TRANSLATE_VERBS.contains(&word) {
            return IntentAction::Translate;
        }
        if CONFIGURE_VERBS.contains(&word) {
            return IntentAction::Configure;
        }
        if MONITOR_VERBS.contains(&word) {
            return IntentAction::Monitor;
        }
        if REMIND_VERBS.contains(&word) {
            return IntentAction::Remind;
        }
    }

    IntentAction::Other(first_word.to_string())
}

/// Parse a natural-language string into a structured [`Intent`].
///
/// Uses rule-based extraction for entities (dates, times, emails, URLs,
/// file paths, app names) and verb-to-action mapping for both Spanish
/// and English.
pub fn parse(text: &str) -> Intent {
    let trimmed = text.trim();
    debug!("intent_parser: parsing '{}'", trimmed);

    let action = detect_action(trimmed);

    let mut entities = Vec::new();
    entities.extend(match_email(trimmed));
    entities.extend(match_urls(trimmed));
    entities.extend(match_file_paths(trimmed));
    entities.extend(match_times(trimmed));
    entities.extend(match_dates(trimmed));
    entities.extend(match_apps(trimmed));

    Intent {
        action,
        entities,
        constraints: Vec::new(),
        raw_text: trimmed.to_string(),
    }
}

/// Split compound sentences into multiple intents.
///
/// Recognizes Spanish conjunctions ("y", "luego", "despues", "después")
/// and English ones ("and", "then", "after that") as sentence boundaries.
pub fn resolve_multi_step(intents_text: &str) -> Vec<Intent> {
    let separators = [
        " y ",
        " luego ",
        " despues ",
        " después ",
        " and ",
        " then ",
        " after that ",
    ];

    let mut parts: Vec<String> = vec![intents_text.to_string()];

    for sep in &separators {
        let mut new_parts = Vec::new();
        for part in &parts {
            let lower = part.to_lowercase();
            if let Some(pos) = lower.find(sep) {
                let left = &part[..pos];
                let right = &part[pos + sep.len()..];
                if !left.trim().is_empty() {
                    new_parts.push(left.trim().to_string());
                }
                if !right.trim().is_empty() {
                    new_parts.push(right.trim().to_string());
                }
            } else {
                new_parts.push(part.clone());
            }
        }
        parts = new_parts;
    }

    parts.iter().map(|p| parse(p)).collect()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_schedule_spanish() {
        let intent = parse("agenda reunion mañana a las 10");
        assert_eq!(intent.action, IntentAction::Schedule);
        assert!(intent.entities.iter().any(|e| e.entity_type == "date"));
        assert!(intent.entities.iter().any(|e| e.entity_type == "time"));
    }

    #[test]
    fn test_parse_send_email() {
        let intent = parse("envia email a user@example.com");
        assert_eq!(intent.action, IntentAction::Send);
        assert!(intent.entities.iter().any(|e| e.entity_type == "email"));
    }

    #[test]
    fn test_parse_open_app() {
        let intent = parse("abre firefox");
        assert_eq!(intent.action, IntentAction::Open);
        assert!(intent
            .entities
            .iter()
            .any(|e| e.entity_type == "app" && e.value == "firefox"));
    }

    #[test]
    fn test_parse_install() {
        let intent = parse("install discord");
        assert_eq!(intent.action, IntentAction::Install);
        assert!(intent
            .entities
            .iter()
            .any(|e| e.entity_type == "app" && e.value == "discord"));
    }

    #[test]
    fn test_parse_url() {
        let intent = parse("abre https://github.com");
        assert_eq!(intent.action, IntentAction::Open);
        assert!(intent.entities.iter().any(|e| e.entity_type == "url"));
    }

    #[test]
    fn test_parse_file_path() {
        let intent = parse("abre /etc/lifeos/config.toml");
        assert!(intent.entities.iter().any(|e| e.entity_type == "file"));
    }

    #[test]
    fn test_resolve_multi_step() {
        let intents = resolve_multi_step("agenda reunion y envia email a user@example.com");
        assert_eq!(intents.len(), 2);
        assert_eq!(intents[0].action, IntentAction::Schedule);
        assert_eq!(intents[1].action, IntentAction::Send);
    }

    #[test]
    fn test_resolve_multi_step_english() {
        let intents = resolve_multi_step("open firefox then search for rust docs");
        assert_eq!(intents.len(), 2);
        assert_eq!(intents[0].action, IntentAction::Open);
        assert_eq!(intents[1].action, IntentAction::Search);
    }

    #[test]
    fn test_unknown_action() {
        let intent = parse("hola mundo");
        assert!(matches!(intent.action, IntentAction::Other(_)));
    }
}
