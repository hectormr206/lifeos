//! Open Food Facts barcode lookup (BI.3.1 follow-up).
//!
//! Pure HTTP client for the public Open Food Facts API. Resolves a
//! barcode to nutrition data WITHOUT touching the local `food_db` —
//! the caller decides whether to persist the result via the regular
//! `add_food` path. Keeping the lookup separate from `memory_plane`
//! enforces clean layering: storage ≠ network.
//!
//! # Usage
//!
//! ```ignore
//! let r = food_lookup::lookup_off("7501020100094").await?;
//! if r.found {
//!     // Optionally call mem.add_food(...) to persist with source="openfoodfacts"
//! }
//! ```
//!
//! # Why a separate module
//!
//! - `memory_plane` is local-only storage. Network fetches don't belong there.
//! - `food_lookup` is opt-in: the user has to invoke the tool/endpoint
//!   explicitly, so the daemon never makes background OFF calls.
//! - The parser (`parse_off_response`) is a pure function and is
//!   unit-tested without any HTTP at all, using a captured sample
//!   payload.
//!
//! # Privacy note
//!
//! The OFF API call sends the barcode in clear over HTTPS to a
//! third-party server. This is no different from any other
//! barcode-lookup app, but it IS one of the very few network calls
//! the daemon makes for personal data. The system prompt instructs
//! the LLM to mention this when proposing the lookup so the user
//! can opt out.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

const OFF_API_BASE: &str = "https://world.openfoodfacts.org/api/v0/product";
const OFF_USER_AGENT: &str = "lifeosd/0.3 (food_lookup; +https://hectormr.com)";

/// Result of an Open Food Facts lookup. `found = false` means the
/// API responded successfully but the barcode is not in their
/// database. Network errors propagate as `Err(...)`.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct OffLookupResult {
    pub found: bool,
    pub barcode: String,
    pub name: Option<String>,
    pub brand: Option<String>,
    pub category: Option<String>,
    pub kcal_per_100g: Option<f64>,
    pub protein_g_per_100g: Option<f64>,
    pub carbs_g_per_100g: Option<f64>,
    pub fat_g_per_100g: Option<f64>,
    pub fiber_g_per_100g: Option<f64>,
    pub serving_size_g: Option<f64>,
}

/// Look up `barcode` against the public Open Food Facts API. The
/// barcode must be a valid EAN-13 / UPC / similar — the function
/// does not validate the format because OFF is permissive.
///
/// Errors only on network / HTTP / parse failures. A successful
/// "not found" response from OFF is returned as
/// `OffLookupResult { found: false, .. }` so the caller can
/// distinguish "the barcode does not exist" from "we could not
/// reach the server".
pub async fn lookup_off(barcode: &str) -> Result<OffLookupResult> {
    let barcode = barcode.trim();
    if barcode.is_empty() {
        anyhow::bail!("barcode is required");
    }
    let url = format!("{}/{}.json", OFF_API_BASE, barcode);

    let client = reqwest::Client::builder()
        .user_agent(OFF_USER_AGENT)
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .context("failed to build OFF http client")?;

    let resp = client
        .get(&url)
        .send()
        .await
        .with_context(|| format!("GET {}", url))?;
    let status = resp.status();
    if !status.is_success() {
        anyhow::bail!("OFF API returned {}", status);
    }
    let json: serde_json::Value = resp.json().await.context("OFF response was not JSON")?;
    Ok(parse_off_response(barcode, &json))
}

/// Pure parser. Public so unit tests can hit it without touching
/// the network.
pub fn parse_off_response(barcode: &str, json: &serde_json::Value) -> OffLookupResult {
    let status = json.get("status").and_then(|s| s.as_i64()).unwrap_or(0);
    if status != 1 {
        return OffLookupResult {
            found: false,
            barcode: barcode.to_string(),
            ..Default::default()
        };
    }
    let product = match json.get("product") {
        Some(p) => p,
        None => {
            return OffLookupResult {
                found: false,
                barcode: barcode.to_string(),
                ..Default::default()
            };
        }
    };
    let nutr = product.get("nutriments");

    let opt_str = |key: &str| -> Option<String> {
        product
            .get(key)
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    };
    let opt_nutr = |key: &str| -> Option<f64> {
        nutr.and_then(|n| n.get(key))
            .and_then(|v| v.as_f64())
            .filter(|v| v.is_finite() && *v >= 0.0)
    };

    // Energy: prefer kcal directly; fall back to kJ converted (1 kcal = 4.184 kJ).
    let kcal =
        opt_nutr("energy-kcal_100g").or_else(|| opt_nutr("energy_100g").map(|kj| kj / 4.184));

    OffLookupResult {
        found: true,
        barcode: barcode.to_string(),
        name: opt_str("product_name").or_else(|| opt_str("generic_name")),
        brand: opt_str("brands"),
        category: opt_str("categories")
            .map(|c| {
                // Categories are comma-separated; take the first
                // (most specific) one for the local catalog.
                c.split(',')
                    .next()
                    .map(|s| s.trim().to_string())
                    .unwrap_or(c)
            })
            .filter(|c| !c.is_empty()),
        kcal_per_100g: kcal,
        protein_g_per_100g: opt_nutr("proteins_100g"),
        carbs_g_per_100g: opt_nutr("carbohydrates_100g"),
        fat_g_per_100g: opt_nutr("fat_100g"),
        fiber_g_per_100g: opt_nutr("fiber_100g"),
        serving_size_g: parse_serving_size_g(product.get("serving_size").and_then(|v| v.as_str())),
    }
}

/// Parse OFF's free-form `serving_size` string into grams. Returns
/// `None` for volumes (ml/cl/l) since converting to grams requires
/// density. Returns `None` for anything else we don't recognize so
/// the caller doesn't get garbage data.
///
/// Examples:
///   "40 g"     → Some(40.0)
///   "1 kg"     → Some(1000.0)
///   "240 ml"   → None    (volume, density unknown)
///   "2 pieces" → None
pub fn parse_serving_size_g(input: Option<&str>) -> Option<f64> {
    let s = input?.trim().to_lowercase();
    if s.is_empty() {
        return None;
    }
    // Reject negative outright. Anything that starts with "-" is
    // garbage data we refuse rather than parse as positive.
    if s.starts_with('-') {
        return None;
    }
    // Split into "<number><maybe space><unit>"; tolerate prefixes
    // like "approx. 40 g" by scanning to the first DIGIT (not '.',
    // because "approx." would otherwise eat the dot and produce 0).
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.peek() {
        if c.is_ascii_digit() {
            break;
        }
        chars.next();
    }
    let mut num_str = String::new();
    while let Some(c) = chars.peek() {
        if c.is_ascii_digit() || *c == '.' {
            num_str.push(*c);
            chars.next();
        } else {
            break;
        }
    }
    let value: f64 = num_str.parse().ok()?;
    if !value.is_finite() || value <= 0.0 {
        return None;
    }
    let unit: String = chars.collect::<String>().trim().to_string();
    match unit.as_str() {
        "g" | "gr" | "gram" | "grams" | "gramo" | "gramos" => Some(value),
        "kg" | "kilogram" | "kilograms" | "kilogramo" | "kilogramos" => Some(value * 1000.0),
        "mg" | "milligram" | "milligrams" => Some(value / 1000.0),
        // Volumes need density to convert; refuse rather than guess.
        "ml" | "cl" | "l" | "litro" | "litros" | "liter" | "liters" => None,
        // Counts (pieces, units, slices) — also refuse.
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_serving_size_grams() {
        assert_eq!(parse_serving_size_g(Some("40 g")), Some(40.0));
        assert_eq!(parse_serving_size_g(Some("250g")), Some(250.0));
        assert_eq!(parse_serving_size_g(Some("1 kg")), Some(1000.0));
        assert_eq!(parse_serving_size_g(Some("0.5 kg")), Some(500.0));
        assert_eq!(parse_serving_size_g(Some("500 mg")), Some(0.5));
    }

    #[test]
    fn parse_serving_size_volumes_return_none() {
        assert_eq!(parse_serving_size_g(Some("240 ml")), None);
        assert_eq!(parse_serving_size_g(Some("1 l")), None);
        assert_eq!(parse_serving_size_g(Some("33 cl")), None);
    }

    #[test]
    fn parse_serving_size_counts_return_none() {
        assert_eq!(parse_serving_size_g(Some("2 pieces")), None);
        assert_eq!(parse_serving_size_g(Some("1 unit")), None);
        assert_eq!(parse_serving_size_g(Some("3 slices")), None);
    }

    #[test]
    fn parse_serving_size_handles_garbage() {
        assert_eq!(parse_serving_size_g(None), None);
        assert_eq!(parse_serving_size_g(Some("")), None);
        assert_eq!(parse_serving_size_g(Some("garbage")), None);
        assert_eq!(parse_serving_size_g(Some("0 g")), None); // zero rejected
        assert_eq!(parse_serving_size_g(Some("-5 g")), None); // negative rejected
    }

    #[test]
    fn parse_serving_size_tolerates_prefix() {
        assert_eq!(parse_serving_size_g(Some("approx. 40 g")), Some(40.0));
        assert_eq!(parse_serving_size_g(Some("about 100g")), Some(100.0));
    }

    #[test]
    fn parse_off_response_status_zero_is_not_found() {
        let body = json!({
            "status": 0,
            "status_verbose": "product not found"
        });
        let r = parse_off_response("9999999999999", &body);
        assert!(!r.found);
        assert_eq!(r.barcode, "9999999999999");
        assert!(r.name.is_none());
    }

    #[test]
    fn parse_off_response_full_product() {
        let body = json!({
            "status": 1,
            "product": {
                "product_name": "Avena Quaker",
                "brands": "Quaker",
                "categories": "Cereales, Avena, Desayuno",
                "serving_size": "40 g",
                "nutriments": {
                    "energy-kcal_100g": 380.0,
                    "proteins_100g": 13.0,
                    "carbohydrates_100g": 67.0,
                    "fat_100g": 7.0,
                    "fiber_100g": 10.0
                }
            }
        });
        let r = parse_off_response("7501234567890", &body);
        assert!(r.found);
        assert_eq!(r.name.as_deref(), Some("Avena Quaker"));
        assert_eq!(r.brand.as_deref(), Some("Quaker"));
        // Categories: takes the FIRST one as the local-catalog category.
        assert_eq!(r.category.as_deref(), Some("Cereales"));
        assert_eq!(r.kcal_per_100g, Some(380.0));
        assert_eq!(r.protein_g_per_100g, Some(13.0));
        assert_eq!(r.carbs_g_per_100g, Some(67.0));
        assert_eq!(r.fat_g_per_100g, Some(7.0));
        assert_eq!(r.fiber_g_per_100g, Some(10.0));
        assert_eq!(r.serving_size_g, Some(40.0));
    }

    #[test]
    fn parse_off_response_falls_back_to_kj_when_no_kcal() {
        // 1589 kJ ≈ 379.78 kcal
        let body = json!({
            "status": 1,
            "product": {
                "product_name": "Test",
                "nutriments": {
                    "energy_100g": 1589.0
                }
            }
        });
        let r = parse_off_response("123", &body);
        assert!(r.found);
        let kcal = r.kcal_per_100g.unwrap();
        assert!((kcal - 379.78).abs() < 0.5, "expected ~380, got {}", kcal);
    }

    #[test]
    fn parse_off_response_drops_negative_or_nan_macros() {
        let body = json!({
            "status": 1,
            "product": {
                "product_name": "Bad data",
                "nutriments": {
                    "proteins_100g": -5.0,
                    "carbohydrates_100g": "not a number",
                    "fat_100g": 7.0
                }
            }
        });
        let r = parse_off_response("123", &body);
        assert!(r.found);
        assert!(r.protein_g_per_100g.is_none());
        assert!(r.carbs_g_per_100g.is_none());
        assert_eq!(r.fat_g_per_100g, Some(7.0));
    }

    #[test]
    fn parse_off_response_falls_back_to_generic_name() {
        let body = json!({
            "status": 1,
            "product": {
                "generic_name": "Cereal de avena",
                "brands": "Generic"
            }
        });
        let r = parse_off_response("123", &body);
        assert!(r.found);
        assert_eq!(r.name.as_deref(), Some("Cereal de avena"));
    }

    #[test]
    fn parse_off_response_status_one_but_no_product() {
        let body = json!({ "status": 1 });
        let r = parse_off_response("123", &body);
        assert!(!r.found);
    }

    #[test]
    fn parse_off_response_skips_empty_strings() {
        let body = json!({
            "status": 1,
            "product": {
                "product_name": "",
                "brands": "   ",
                "categories": "",
            }
        });
        let r = parse_off_response("123", &body);
        assert!(r.found);
        assert!(r.name.is_none());
        assert!(r.brand.is_none());
        assert!(r.category.is_none());
    }
}
