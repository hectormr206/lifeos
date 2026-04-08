//! lifeos-food-importer — Standalone CSV → food_db importer.
//!
//! Reads a normalized CSV file and POSTs each row to the local
//! LifeOS daemon's `/api/v1/vida-plena/food` endpoint. Designed to
//! bootstrap `food_db` with public-domain catalogs (USDA FoodData
//! Central, Open Food Facts MX, SMAE) without bundling the data
//! inside the daemon binary.
//!
//! # Usage
//!
//! ```bash
//! lifeos-food-importer \
//!     --csv ./usda-foundation-foods-normalized.csv \
//!     --daemon-url http://127.0.0.1:8081 \
//!     --token "$LIFEOS_BOOTSTRAP_TOKEN" \
//!     --source usda
//! ```
//!
//! The `--source` flag is forced into the API source field of every
//! row, overriding whatever the CSV says. This way the same importer
//! can be re-used for different upstream catalogs by changing the
//! flag at invocation time. The CSV's own `source` column is treated
//! as advisory metadata.
//!
//! # CSV format
//!
//! Required columns (in any order, header row required):
//! - `name`            (string, required, non-empty)
//!
//! Optional columns:
//! - `brand`           (string)
//! - `category`        (string)
//! - `kcal_per_100g`   (float)
//! - `protein_g_per_100g`  (float)
//! - `carbs_g_per_100g`    (float)
//! - `fat_g_per_100g`      (float)
//! - `fiber_g_per_100g`    (float)
//! - `serving_size_g`  (float)
//! - `barcode`         (string)
//! - `tags`            (string, comma-separated)
//!
//! Empty cells are treated as `None`. Unknown columns are ignored
//! silently so the same CSV can be consumed by future importer
//! versions without breaking.
//!
//! # Why a separate binary?
//!
//! The importer is a one-shot ETL tool, not part of the daemon's
//! runtime path. Keeping it as a separate binary inside the daemon
//! crate means:
//!   * Zero runtime cost on `lifeosd` startup.
//!   * Same Cargo.toml + lockfile, so no version drift between the
//!     API client model and the daemon's actual handlers.
//!   * Can be shipped (or omitted) independently from the daemon
//!     image.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

/// What we POST to the daemon. Mirrors `AddFoodPayload` in
/// `daemon/src/api/vida_plena.rs` — keep the field names in sync.
#[derive(Debug, Serialize)]
struct AddFoodPayload {
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    brand: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    category: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    kcal_per_100g: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    protein_g_per_100g: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    carbs_g_per_100g: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    fat_g_per_100g: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    fiber_g_per_100g: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    serving_size_g: Option<f64>,
    source: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    barcode: Option<String>,
    tags: Vec<String>,
}

#[derive(Debug)]
struct CliArgs {
    csv_path: PathBuf,
    daemon_url: String,
    token: String,
    source: String,
    dry_run: bool,
    skip_existing: bool,
    limit: Option<usize>,
}

fn print_usage() {
    eprintln!(
        "Usage: lifeos-food-importer --csv <PATH> --daemon-url <URL> --token <TOKEN> --source <SOURCE> [options]\n\
         \n\
         Required:\n\
         --csv <PATH>          Normalized CSV file to import\n\
         --daemon-url <URL>    Base URL of the daemon (e.g. http://127.0.0.1:8081)\n\
         --token <TOKEN>       Bootstrap token (or use $LIFEOS_BOOTSTRAP_TOKEN)\n\
         --source <SOURCE>     One of: usda | openfoodfacts | smae | user\n\
         \n\
         Options:\n\
         --dry-run             Parse + validate but do not POST\n\
         --skip-existing       Skip rows whose name+brand already exist (search via API)\n\
         --limit <N>           Stop after N rows\n\
         --help                Show this message\n"
    );
}

fn parse_args() -> Result<CliArgs> {
    let mut csv_path: Option<PathBuf> = None;
    let mut daemon_url: Option<String> = None;
    let mut token: Option<String> = env::var("LIFEOS_BOOTSTRAP_TOKEN").ok();
    let mut source: Option<String> = None;
    let mut dry_run = false;
    let mut skip_existing = false;
    let mut limit: Option<usize> = None;

    let args: Vec<String> = env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--help" | "-h" => {
                print_usage();
                std::process::exit(0);
            }
            "--csv" => {
                i += 1;
                csv_path = Some(PathBuf::from(args.get(i).context("--csv requires a path")?));
            }
            "--daemon-url" => {
                i += 1;
                daemon_url = Some(
                    args.get(i)
                        .context("--daemon-url requires a value")?
                        .clone(),
                );
            }
            "--token" => {
                i += 1;
                token = Some(args.get(i).context("--token requires a value")?.clone());
            }
            "--source" => {
                i += 1;
                source = Some(args.get(i).context("--source requires a value")?.clone());
            }
            "--dry-run" => dry_run = true,
            "--skip-existing" => skip_existing = true,
            "--limit" => {
                i += 1;
                limit = Some(
                    args.get(i)
                        .context("--limit requires a number")?
                        .parse()
                        .context("--limit must be a positive integer")?,
                );
            }
            other => anyhow::bail!("unknown argument: {}", other),
        }
        i += 1;
    }

    let source = source.context("--source is required")?;
    if !matches!(source.as_str(), "usda" | "openfoodfacts" | "smae" | "user") {
        anyhow::bail!(
            "--source must be one of: usda, openfoodfacts, smae, user (got '{}')",
            source
        );
    }

    Ok(CliArgs {
        csv_path: csv_path.context("--csv is required")?,
        daemon_url: daemon_url.context("--daemon-url is required")?,
        token: token.context("--token is required (or set LIFEOS_BOOTSTRAP_TOKEN)")?,
        source,
        dry_run,
        skip_existing,
        limit,
    })
}

#[derive(Debug, Default)]
struct ImportStats {
    rows_read: usize,
    rows_skipped_invalid: usize,
    rows_skipped_existing: usize,
    rows_posted_ok: usize,
    rows_posted_failed: usize,
}

#[derive(Debug, Deserialize)]
struct SearchResponse {
    #[serde(default)]
    foods: Vec<SearchHit>,
}

#[derive(Debug, Deserialize)]
struct SearchHit {
    name: String,
    #[serde(default)]
    brand: Option<String>,
}

/// Convert a single CSV record (header → cell) into the payload that
/// the daemon expects. Returns `None` for rows that fail validation
/// so the importer can skip + count them rather than abort the run.
fn record_to_payload(
    record: &HashMap<String, String>,
    forced_source: &str,
) -> Option<AddFoodPayload> {
    let name = record
        .get("name")
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())?;

    let opt_str = |key: &str| -> Option<String> {
        record
            .get(key)
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    };
    let opt_f64 = |key: &str| -> Option<f64> {
        record
            .get(key)
            .and_then(|s| s.trim().parse::<f64>().ok())
            .filter(|v| v.is_finite() && *v >= 0.0)
    };

    let tags: Vec<String> = opt_str("tags")
        .map(|s| {
            s.split(',')
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty())
                .collect()
        })
        .unwrap_or_default();

    Some(AddFoodPayload {
        name,
        brand: opt_str("brand"),
        category: opt_str("category"),
        kcal_per_100g: opt_f64("kcal_per_100g"),
        protein_g_per_100g: opt_f64("protein_g_per_100g"),
        carbs_g_per_100g: opt_f64("carbs_g_per_100g"),
        fat_g_per_100g: opt_f64("fat_g_per_100g"),
        fiber_g_per_100g: opt_f64("fiber_g_per_100g"),
        serving_size_g: opt_f64("serving_size_g"),
        source: forced_source.to_string(),
        barcode: opt_str("barcode"),
        tags,
    })
}

async fn maybe_skip_existing(
    client: &reqwest::Client,
    daemon_url: &str,
    token: &str,
    payload: &AddFoodPayload,
) -> Result<bool> {
    let url = format!("{}/api/v1/vida-plena/food/search", daemon_url);
    let resp = client
        .get(&url)
        .header("x-bootstrap-token", token)
        .query(&[("q", payload.name.as_str()), ("limit", "20")])
        .send()
        .await
        .with_context(|| format!("GET {}", url))?;
    if !resp.status().is_success() {
        // Treat lookup failure as "not skip" — let the POST decide.
        return Ok(false);
    }
    let body: SearchResponse = resp
        .json()
        .await
        .unwrap_or(SearchResponse { foods: Vec::new() });
    let already_present = body.foods.iter().any(|hit| {
        hit.name.eq_ignore_ascii_case(&payload.name)
            && hit.brand.as_deref().map(str::to_ascii_lowercase)
                == payload.brand.as_deref().map(str::to_ascii_lowercase)
    });
    Ok(already_present)
}

async fn post_food(
    client: &reqwest::Client,
    daemon_url: &str,
    token: &str,
    payload: &AddFoodPayload,
) -> Result<()> {
    let url = format!("{}/api/v1/vida-plena/food", daemon_url);
    let resp = client
        .post(&url)
        .header("x-bootstrap-token", token)
        .json(payload)
        .send()
        .await
        .with_context(|| format!("POST {}", url))?;
    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("POST failed ({}): {}", status, body);
    }
    Ok(())
}

async fn run(args: CliArgs) -> Result<ImportStats> {
    let mut stats = ImportStats::default();

    let client = reqwest::Client::builder()
        .user_agent("lifeos-food-importer/0.1")
        .build()
        .context("failed to build HTTP client")?;

    let mut reader = csv::ReaderBuilder::new()
        .has_headers(true)
        .flexible(true)
        .from_path(&args.csv_path)
        .with_context(|| format!("opening CSV {}", args.csv_path.display()))?;

    let headers: Vec<String> = reader
        .headers()
        .context("reading CSV header")?
        .iter()
        .map(|h| h.trim().to_string())
        .collect();

    if !headers.iter().any(|h| h == "name") {
        anyhow::bail!("CSV must have a 'name' column. Found: {:?}", headers);
    }

    println!(
        "Importing {} (source={}, dry_run={}, skip_existing={})",
        args.csv_path.display(),
        args.source,
        args.dry_run,
        args.skip_existing
    );

    for (row_idx, row) in reader.records().enumerate() {
        if let Some(limit) = args.limit {
            if stats.rows_read >= limit {
                break;
            }
        }
        stats.rows_read += 1;

        let row = match row {
            Ok(r) => r,
            Err(e) => {
                eprintln!("[row {}] CSV parse error: {}", row_idx + 2, e);
                stats.rows_skipped_invalid += 1;
                continue;
            }
        };

        let mut record = HashMap::new();
        for (i, cell) in row.iter().enumerate() {
            if let Some(h) = headers.get(i) {
                record.insert(h.clone(), cell.to_string());
            }
        }

        let payload = match record_to_payload(&record, &args.source) {
            Some(p) => p,
            None => {
                eprintln!("[row {}] missing required 'name' column", row_idx + 2);
                stats.rows_skipped_invalid += 1;
                continue;
            }
        };

        if args.skip_existing
            && maybe_skip_existing(&client, &args.daemon_url, &args.token, &payload)
                .await
                .unwrap_or(false)
        {
            stats.rows_skipped_existing += 1;
            continue;
        }

        if args.dry_run {
            stats.rows_posted_ok += 1;
            continue;
        }

        match post_food(&client, &args.daemon_url, &args.token, &payload).await {
            Ok(()) => {
                stats.rows_posted_ok += 1;
                if stats.rows_posted_ok % 50 == 0 {
                    println!("  ...{} rows posted", stats.rows_posted_ok);
                }
            }
            Err(e) => {
                eprintln!("[row {}] POST failed: {}", row_idx + 2, e);
                stats.rows_posted_failed += 1;
            }
        }
    }

    Ok(stats)
}

#[tokio::main]
async fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("Error: {}", e);
            print_usage();
            return ExitCode::from(2);
        }
    };

    match run(args).await {
        Ok(stats) => {
            println!(
                "\nImport finished:\n  rows read     : {}\n  invalid       : {}\n  skipped       : {}\n  posted ok     : {}\n  posted failed : {}",
                stats.rows_read,
                stats.rows_skipped_invalid,
                stats.rows_skipped_existing,
                stats.rows_posted_ok,
                stats.rows_posted_failed,
            );
            if stats.rows_posted_failed > 0 {
                ExitCode::from(1)
            } else {
                ExitCode::SUCCESS
            }
        }
        Err(e) => {
            eprintln!("Fatal: {:#}", e);
            ExitCode::from(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn record_to_payload_minimal_row() {
        let r = rec(&[("name", "Avena")]);
        let p = record_to_payload(&r, "user").expect("should produce payload");
        assert_eq!(p.name, "Avena");
        assert_eq!(p.source, "user");
        assert!(p.brand.is_none());
        assert!(p.tags.is_empty());
        assert!(p.kcal_per_100g.is_none());
    }

    #[test]
    fn record_to_payload_full_row() {
        let r = rec(&[
            ("name", "Avena Quaker"),
            ("brand", "Quaker"),
            ("category", "grain"),
            ("kcal_per_100g", "380"),
            ("protein_g_per_100g", "13"),
            ("carbs_g_per_100g", "67.5"),
            ("fat_g_per_100g", "7"),
            ("fiber_g_per_100g", "10"),
            ("serving_size_g", "40"),
            ("barcode", "7501234567890"),
            ("tags", "desayuno, integral , "),
        ]);
        let p = record_to_payload(&r, "usda").expect("should produce payload");
        assert_eq!(p.brand.as_deref(), Some("Quaker"));
        assert_eq!(p.category.as_deref(), Some("grain"));
        assert_eq!(p.kcal_per_100g, Some(380.0));
        assert_eq!(p.carbs_g_per_100g, Some(67.5));
        assert_eq!(p.barcode.as_deref(), Some("7501234567890"));
        // tags split, trimmed, empty filtered.
        assert_eq!(p.tags, vec!["desayuno".to_string(), "integral".to_string()]);
        // forced source overrides any CSV column.
        assert_eq!(p.source, "usda");
    }

    #[test]
    fn record_to_payload_rejects_empty_name() {
        let r = rec(&[("name", "   ")]);
        assert!(record_to_payload(&r, "user").is_none());
        let r2 = rec(&[("brand", "Quaker")]);
        assert!(record_to_payload(&r2, "user").is_none());
    }

    #[test]
    fn record_to_payload_skips_non_finite_and_negative_macros() {
        // Negative kcal → dropped (None), not propagated.
        let r = rec(&[
            ("name", "X"),
            ("kcal_per_100g", "-5"),
            ("protein_g_per_100g", "NaN"),
            ("fat_g_per_100g", "abc"),
        ]);
        let p = record_to_payload(&r, "user").unwrap();
        assert!(p.kcal_per_100g.is_none());
        assert!(p.protein_g_per_100g.is_none());
        assert!(p.fat_g_per_100g.is_none());
    }

    #[test]
    fn record_to_payload_handles_empty_optional_cells() {
        let r = rec(&[
            ("name", "Manzana"),
            ("brand", ""),
            ("category", "  "),
            ("kcal_per_100g", ""),
        ]);
        let p = record_to_payload(&r, "user").unwrap();
        assert!(p.brand.is_none());
        assert!(p.category.is_none());
        assert!(p.kcal_per_100g.is_none());
    }

    #[test]
    fn record_to_payload_ignores_unknown_columns() {
        let r = rec(&[
            ("name", "Pan"),
            ("source", "smae"), // CSV's source column is ignored
            ("future_column_x", "whatever"),
            ("kcal_per_100g", "250"),
        ]);
        let p = record_to_payload(&r, "openfoodfacts").unwrap();
        assert_eq!(p.source, "openfoodfacts"); // forced wins
        assert_eq!(p.kcal_per_100g, Some(250.0));
    }
}
