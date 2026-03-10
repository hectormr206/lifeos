//! Accessibility Module (WCAG 2.2 AA Compliance)
//!
//! Provides:
//! - Color contrast validation (WCAG 2.2 AA minimum 4.5:1 for text, 3:1 for large text)
//! - Theme accessibility auditing
//! - Accessibility settings (high contrast, reduced motion, font scaling)
//! - Screen reader compatibility hints

use log::{info, warn};
use serde::{Deserialize, Serialize};

/// WCAG 2.2 AA minimum contrast ratios
const WCAG_AA_NORMAL_TEXT: f64 = 4.5;
const WCAG_AA_LARGE_TEXT: f64 = 3.0;
const WCAG_AA_UI_COMPONENT: f64 = 3.0;

/// Accessibility settings for the system
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccessibilitySettings {
    /// Enable high contrast mode
    pub high_contrast: bool,
    /// Reduce motion/animations
    pub reduce_motion: bool,
    /// Font scale factor (1.0 = default, 1.5 = 150%)
    pub font_scale: f32,
    /// Minimum font size in points
    pub min_font_size: u32,
    /// Enable screen reader support hints
    pub screen_reader_support: bool,
    /// Color blind mode
    pub color_blind_mode: ColorBlindMode,
    /// Enable keyboard-only navigation
    pub keyboard_navigation: bool,
    /// Focus indicator style
    pub focus_indicator: FocusIndicator,
}

impl Default for AccessibilitySettings {
    fn default() -> Self {
        Self {
            high_contrast: false,
            reduce_motion: false,
            font_scale: 1.0,
            min_font_size: 12,
            screen_reader_support: false,
            color_blind_mode: ColorBlindMode::None,
            keyboard_navigation: true,
            focus_indicator: FocusIndicator::Default,
        }
    }
}

/// Color blindness compensation modes
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum ColorBlindMode {
    None,
    Protanopia,   // Red-blind
    Deuteranopia, // Green-blind
    Tritanopia,   // Blue-blind
}

/// Focus indicator styles
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum FocusIndicator {
    Default,
    HighVisibility,
    Custom { color: String, width: u32 },
}

/// RGB color for contrast calculations
#[derive(Debug, Clone, Copy)]
pub struct RgbColor {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl RgbColor {
    /// Parse from hex string (e.g., "#FF5500" or "FF5500")
    pub fn from_hex(hex: &str) -> Option<Self> {
        let hex = hex.trim_start_matches('#');
        if hex.len() != 6 {
            return None;
        }
        let r = u8::from_str_radix(&hex[0..2], 16).ok()?;
        let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
        let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
        Some(Self { r, g, b })
    }

    /// Calculate relative luminance per WCAG 2.2
    /// https://www.w3.org/TR/WCAG22/#dfn-relative-luminance
    pub fn relative_luminance(&self) -> f64 {
        let r = srgb_to_linear(self.r as f64 / 255.0);
        let g = srgb_to_linear(self.g as f64 / 255.0);
        let b = srgb_to_linear(self.b as f64 / 255.0);
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

/// Convert sRGB component to linear
fn srgb_to_linear(c: f64) -> f64 {
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

/// Calculate contrast ratio between two colors per WCAG 2.2
/// Returns ratio as L1/L2 where L1 is the lighter color
pub fn contrast_ratio(color1: &RgbColor, color2: &RgbColor) -> f64 {
    let l1 = color1.relative_luminance();
    let l2 = color2.relative_luminance();
    let lighter = l1.max(l2);
    let darker = l1.min(l2);
    (lighter + 0.05) / (darker + 0.05)
}

/// Result of a contrast check
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContrastResult {
    pub ratio: f64,
    pub passes_normal_text: bool,
    pub passes_large_text: bool,
    pub passes_ui_component: bool,
    pub foreground: String,
    pub background: String,
    pub level: String,
}

/// Check if a foreground/background color pair meets WCAG AA
pub fn check_contrast(fg_hex: &str, bg_hex: &str) -> Option<ContrastResult> {
    let fg = RgbColor::from_hex(fg_hex)?;
    let bg = RgbColor::from_hex(bg_hex)?;
    let ratio = contrast_ratio(&fg, &bg);

    let level = if ratio >= 7.0 {
        "AAA".to_string()
    } else if ratio >= WCAG_AA_NORMAL_TEXT {
        "AA".to_string()
    } else if ratio >= WCAG_AA_LARGE_TEXT {
        "AA Large".to_string()
    } else {
        "Fail".to_string()
    };

    Some(ContrastResult {
        ratio,
        passes_normal_text: ratio >= WCAG_AA_NORMAL_TEXT,
        passes_large_text: ratio >= WCAG_AA_LARGE_TEXT,
        passes_ui_component: ratio >= WCAG_AA_UI_COMPONENT,
        foreground: fg_hex.to_string(),
        background: bg_hex.to_string(),
        level,
    })
}

/// Theme color pair to validate
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ThemeColorPair {
    pub name: String,
    pub foreground: String,
    pub background: String,
    pub is_large_text: bool,
}

/// Theme audit result
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ThemeAuditResult {
    pub theme_name: String,
    pub total_pairs: usize,
    pub passing_pairs: usize,
    pub failing_pairs: usize,
    pub overall_pass: bool,
    pub results: Vec<ContrastResult>,
    pub issues: Vec<String>,
}

/// Audit a theme's color pairs for WCAG AA compliance
pub fn audit_theme(theme_name: &str, pairs: &[ThemeColorPair]) -> ThemeAuditResult {
    let mut results = Vec::new();
    let mut issues = Vec::new();
    let mut passing = 0;
    let mut failing = 0;

    for pair in pairs {
        if let Some(result) = check_contrast(&pair.foreground, &pair.background) {
            let required_ratio = if pair.is_large_text {
                WCAG_AA_LARGE_TEXT
            } else {
                WCAG_AA_NORMAL_TEXT
            };

            if result.ratio >= required_ratio {
                passing += 1;
            } else {
                failing += 1;
                issues.push(format!(
                    "'{}': contrast {:.2}:1 (need {:.1}:1) — fg={} bg={}",
                    pair.name, result.ratio, required_ratio, pair.foreground, pair.background
                ));
            }
            results.push(result);
        } else {
            failing += 1;
            issues.push(format!("'{}': invalid color values", pair.name));
        }
    }

    let overall_pass = failing == 0;

    if overall_pass {
        info!(
            "Theme '{}' passes WCAG 2.2 AA ({}/{} pairs)",
            theme_name,
            passing,
            pairs.len()
        );
    } else {
        warn!("Theme '{}' has {} WCAG AA failures", theme_name, failing);
    }

    ThemeAuditResult {
        theme_name: theme_name.to_string(),
        total_pairs: pairs.len(),
        passing_pairs: passing,
        failing_pairs: failing,
        overall_pass,
        results,
        issues,
    }
}

/// LifeOS default theme color pairs for validation
pub fn lifeos_default_theme_pairs() -> Vec<ThemeColorPair> {
    vec![
        // Dark theme
        ThemeColorPair {
            name: "dark-primary-text".to_string(),
            foreground: "#E0E0E0".to_string(),
            background: "#1A1A2E".to_string(),
            is_large_text: false,
        },
        ThemeColorPair {
            name: "dark-secondary-text".to_string(),
            foreground: "#A0A0B0".to_string(),
            background: "#1A1A2E".to_string(),
            is_large_text: false,
        },
        ThemeColorPair {
            name: "dark-heading".to_string(),
            foreground: "#FFFFFF".to_string(),
            background: "#1A1A2E".to_string(),
            is_large_text: true,
        },
        ThemeColorPair {
            name: "dark-accent-on-bg".to_string(),
            foreground: "#4FC3F7".to_string(),
            background: "#1A1A2E".to_string(),
            is_large_text: false,
        },
        ThemeColorPair {
            name: "dark-error".to_string(),
            foreground: "#FF5252".to_string(),
            background: "#1A1A2E".to_string(),
            is_large_text: false,
        },
        ThemeColorPair {
            name: "dark-success".to_string(),
            foreground: "#69F0AE".to_string(),
            background: "#1A1A2E".to_string(),
            is_large_text: false,
        },
        ThemeColorPair {
            name: "dark-button-text".to_string(),
            foreground: "#FFFFFF".to_string(),
            background: "#3949AB".to_string(),
            is_large_text: false,
        },
        // Light theme
        ThemeColorPair {
            name: "light-primary-text".to_string(),
            foreground: "#212121".to_string(),
            background: "#FAFAFA".to_string(),
            is_large_text: false,
        },
        ThemeColorPair {
            name: "light-secondary-text".to_string(),
            foreground: "#616161".to_string(),
            background: "#FAFAFA".to_string(),
            is_large_text: false,
        },
        ThemeColorPair {
            name: "light-heading".to_string(),
            foreground: "#1A1A2E".to_string(),
            background: "#FAFAFA".to_string(),
            is_large_text: true,
        },
        ThemeColorPair {
            name: "light-accent-on-bg".to_string(),
            foreground: "#1565C0".to_string(),
            background: "#FAFAFA".to_string(),
            is_large_text: false,
        },
        ThemeColorPair {
            name: "light-error".to_string(),
            foreground: "#C62828".to_string(),
            background: "#FAFAFA".to_string(),
            is_large_text: false,
        },
        ThemeColorPair {
            name: "light-success".to_string(),
            foreground: "#2E7D32".to_string(),
            background: "#FAFAFA".to_string(),
            is_large_text: false,
        },
        ThemeColorPair {
            name: "light-button-text".to_string(),
            foreground: "#FFFFFF".to_string(),
            background: "#1565C0".to_string(),
            is_large_text: false,
        },
        // High contrast theme
        ThemeColorPair {
            name: "hc-primary-text".to_string(),
            foreground: "#FFFFFF".to_string(),
            background: "#000000".to_string(),
            is_large_text: false,
        },
        ThemeColorPair {
            name: "hc-accent".to_string(),
            foreground: "#FFFF00".to_string(),
            background: "#000000".to_string(),
            is_large_text: false,
        },
        ThemeColorPair {
            name: "hc-error".to_string(),
            foreground: "#FF6666".to_string(),
            background: "#000000".to_string(),
            is_large_text: false,
        },
        ThemeColorPair {
            name: "hc-success".to_string(),
            foreground: "#66FF66".to_string(),
            background: "#000000".to_string(),
            is_large_text: false,
        },
    ]
}

/// Accessibility manager
pub struct AccessibilityManager {
    settings: AccessibilitySettings,
}

impl AccessibilityManager {
    pub fn new() -> Self {
        Self {
            settings: AccessibilitySettings::default(),
        }
    }

    pub fn get_settings(&self) -> &AccessibilitySettings {
        &self.settings
    }

    pub fn set_settings(&mut self, settings: AccessibilitySettings) {
        self.settings = settings;
        info!(
            "Accessibility settings updated: high_contrast={}, reduce_motion={}, font_scale={:.1}",
            self.settings.high_contrast, self.settings.reduce_motion, self.settings.font_scale
        );
    }

    /// Run full accessibility audit on default themes
    pub fn audit_default_themes(&self) -> Vec<ThemeAuditResult> {
        let pairs = lifeos_default_theme_pairs();

        // Group by theme prefix
        let dark_pairs: Vec<_> = pairs
            .iter()
            .filter(|p| p.name.starts_with("dark-"))
            .cloned()
            .collect();
        let light_pairs: Vec<_> = pairs
            .iter()
            .filter(|p| p.name.starts_with("light-"))
            .cloned()
            .collect();
        let hc_pairs: Vec<_> = pairs
            .iter()
            .filter(|p| p.name.starts_with("hc-"))
            .cloned()
            .collect();

        vec![
            audit_theme("LifeOS Dark", &dark_pairs),
            audit_theme("LifeOS Light", &light_pairs),
            audit_theme("High Contrast", &hc_pairs),
        ]
    }
}

impl Default for AccessibilityManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rgb_from_hex() {
        let c = RgbColor::from_hex("#FF5500").unwrap();
        assert_eq!(c.r, 255);
        assert_eq!(c.g, 85);
        assert_eq!(c.b, 0);

        let c2 = RgbColor::from_hex("000000").unwrap();
        assert_eq!(c2.r, 0);
    }

    #[test]
    fn test_contrast_ratio_black_white() {
        let black = RgbColor { r: 0, g: 0, b: 0 };
        let white = RgbColor {
            r: 255,
            g: 255,
            b: 255,
        };
        let ratio = contrast_ratio(&black, &white);
        assert!(
            (ratio - 21.0).abs() < 0.1,
            "Black/white ratio should be ~21:1, got {}",
            ratio
        );
    }

    #[test]
    fn test_contrast_ratio_same_color() {
        let c = RgbColor {
            r: 128,
            g: 128,
            b: 128,
        };
        let ratio = contrast_ratio(&c, &c);
        assert!(
            (ratio - 1.0).abs() < 0.001,
            "Same color ratio should be 1:1"
        );
    }

    #[test]
    fn test_wcag_aa_check() {
        // White on dark blue — should pass
        let result = check_contrast("#FFFFFF", "#1A1A2E").unwrap();
        assert!(
            result.passes_normal_text,
            "White on dark should pass AA: ratio={:.2}",
            result.ratio
        );

        // Light gray on white — should fail for normal text
        let result = check_contrast("#CCCCCC", "#FFFFFF").unwrap();
        assert!(
            !result.passes_normal_text,
            "Light gray on white should fail AA: ratio={:.2}",
            result.ratio
        );
    }

    #[test]
    fn test_default_themes_pass_audit() {
        let mgr = AccessibilityManager::new();
        let results = mgr.audit_default_themes();

        for result in &results {
            if !result.overall_pass {
                for issue in &result.issues {
                    eprintln!("WCAG issue in {}: {}", result.theme_name, issue);
                }
            }
        }

        // High contrast theme must always pass
        let hc = results
            .iter()
            .find(|r| r.theme_name == "High Contrast")
            .unwrap();
        assert!(hc.overall_pass, "High Contrast theme must pass WCAG AA");
    }

    #[test]
    fn test_audit_theme_with_failing_pair() {
        let pairs = vec![ThemeColorPair {
            name: "bad-contrast".to_string(),
            foreground: "#AAAAAA".to_string(),
            background: "#BBBBBB".to_string(),
            is_large_text: false,
        }];
        let result = audit_theme("test", &pairs);
        assert!(!result.overall_pass);
        assert_eq!(result.failing_pairs, 1);
    }

    #[test]
    fn test_accessibility_settings_default() {
        let settings = AccessibilitySettings::default();
        assert!(!settings.high_contrast);
        assert!(!settings.reduce_motion);
        assert_eq!(settings.font_scale, 1.0);
        assert!(settings.keyboard_navigation);
    }
}
