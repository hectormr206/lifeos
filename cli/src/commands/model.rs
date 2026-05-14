use anyhow::Result;
use clap::{Args, Subcommand};
use colored::Colorize;
use serde::Serialize;
use std::path::{Path, PathBuf};

// ── Model size ────────────────────────────────────────────────────────────────

/// The model variant to download.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, clap::ValueEnum)]
pub enum ModelSize {
    #[default]
    #[value(name = "4b")]
    FourB,
    #[value(name = "9b")]
    NineB,
}

// ── Args ──────────────────────────────────────────────────────────────────────

#[derive(Args, Default)]
pub struct ModelDownloadArgs {
    /// Model size to download: 4b (default) | 9b
    #[arg(long, value_enum, default_value = "4b")]
    pub size: ModelSize,

    /// Override destination directory (default: /var/lib/lifeos/models/)
    #[arg(long)]
    pub dest: Option<PathBuf>,

    /// Suppress progress bar (machine-readable output)
    #[arg(long)]
    pub no_progress: bool,

    /// Emit structured JSON to stdout
    #[arg(long)]
    pub json: bool,

    /// Re-download even if the file already exists
    #[arg(long)]
    pub force: bool,
}

#[derive(Args)]
pub struct ModelListArgs {
    /// Emit structured JSON to stdout
    #[arg(long)]
    pub json: bool,
}

// ── Subcommands ───────────────────────────────────────────────────────────────

#[derive(Subcommand)]
pub enum ModelCommands {
    /// Download a model to the local models directory
    Download(ModelDownloadArgs),
    /// List models present in the local models directory
    List(ModelListArgs),
}

// ── Decision type ─────────────────────────────────────────────────────────────

/// Result of checking whether a download is needed.
#[derive(Debug, PartialEq, Eq)]
pub enum DownloadAction {
    /// File is already present and --force was not set
    Skip,
    /// Proceed with downloading
    Download,
}

// ── Pure helpers ──────────────────────────────────────────────────────────────

/// Return (filename, url) for a given model size.
///
/// This is a pure function — no I/O, trivially testable.
pub fn resolve_model_url(size: ModelSize) -> (&'static str, &'static str) {
    match size {
        ModelSize::FourB => (
            "Qwen3.5-4B-Q4_K_M.gguf",
            "https://huggingface.co/Qwen/Qwen3.5-4B-Instruct-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf",
        ),
        ModelSize::NineB => (
            "Qwen3.5-9B-Q4_K_M.gguf",
            "https://huggingface.co/Qwen/Qwen3.5-9B-Instruct-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf",
        ),
    }
}

/// Decide whether to download based on filesystem state and --force flag.
///
/// Pure function — accepts booleans, returns a decision. No I/O.
pub fn decide_download(file_exists: bool, force: bool) -> DownloadAction {
    if file_exists && !force {
        DownloadAction::Skip
    } else {
        DownloadAction::Download
    }
}

/// Compute the `.partial` temp path for atomic writes.
pub fn partial_path(dest: &Path, filename: &str) -> PathBuf {
    dest.join(format!("{}.partial", filename))
}

/// Default models directory.
pub const DEFAULT_MODELS_DIR: &str = "/var/lib/lifeos/models";

// ── Known model catalog (for `list`) ─────────────────────────────────────────

struct KnownModel {
    filename: &'static str,
}

const KNOWN_MODELS: &[KnownModel] = &[
    KnownModel {
        filename: "Qwen3.5-4B-Q4_K_M.gguf",
    },
    KnownModel {
        filename: "Qwen3.5-9B-Q4_K_M.gguf",
    },
];

fn is_known_model(filename: &str) -> bool {
    KNOWN_MODELS.iter().any(|m| m.filename == filename)
}

// ── JSON output ───────────────────────────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct DownloadReport {
    pub action: String,
    pub filename: String,
    pub dest: String,
    pub success: bool,
    pub message: String,
}

#[derive(Debug, Serialize)]
pub struct ModelEntry {
    pub filename: String,
    pub size_bytes: u64,
    pub canonical: bool,
}

// ── Dispatcher ────────────────────────────────────────────────────────────────

pub async fn execute(cmd: ModelCommands) -> Result<()> {
    match cmd {
        ModelCommands::Download(args) => execute_download(args).await,
        ModelCommands::List(args) => execute_list(args),
    }
}

// ── `life model download` ─────────────────────────────────────────────────────

pub async fn execute_download(args: ModelDownloadArgs) -> Result<()> {
    let (filename, url) = resolve_model_url(args.size);
    let dest = args
        .dest
        .as_deref()
        .unwrap_or(Path::new(DEFAULT_MODELS_DIR));

    // Check dest dir exists and is accessible
    if !dest.exists() {
        let msg = format!(
            "destination directory '{}' does not exist.\n  \
             Create it and ensure the `lifeos` group has write access:\n  \
             sudo mkdir -p {}\n  \
             sudo chown root:lifeos {}\n  \
             sudo chmod 2775 {}",
            dest.display(),
            dest.display(),
            dest.display(),
            dest.display(),
        );
        if args.json {
            let report = DownloadReport {
                action: "error".into(),
                filename: filename.into(),
                dest: dest.display().to_string(),
                success: false,
                message: msg.clone(),
            };
            println!("{}", serde_json::to_string_pretty(&report)?);
        } else {
            eprintln!("{} {}", "error:".red().bold(), msg);
        }
        std::process::exit(2);
    }

    let target_path = dest.join(filename);
    let action = decide_download(target_path.exists(), args.force);

    match action {
        DownloadAction::Skip => {
            let msg = format!(
                "'{}' is already present — skipping (use --force to re-download)",
                filename
            );
            if args.json {
                let report = DownloadReport {
                    action: "skip".into(),
                    filename: filename.into(),
                    dest: dest.display().to_string(),
                    success: true,
                    message: msg,
                };
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                eprintln!("{} {}", "✓".green(), msg);
            }
            return Ok(());
        }
        DownloadAction::Download => {
            perform_download(filename, url, dest, &args).await?;
        }
    }

    Ok(())
}

/// Perform the actual streaming download with progress bar.
async fn perform_download(
    filename: &str,
    url: &str,
    dest: &Path,
    args: &ModelDownloadArgs,
) -> Result<()> {
    use futures::StreamExt;
    use sha2::{Digest, Sha256};
    use std::io::Write;

    let partial = partial_path(dest, filename);
    let target = dest.join(filename);

    if !args.json {
        eprintln!(
            "{} Downloading {} from HuggingFace...",
            "[1/2]".bold(),
            filename.cyan()
        );
        eprintln!("  URL: {}", url.dimmed());
    }

    let client = reqwest::Client::builder()
        .user_agent("lifeos-cli/model-download")
        .build()?;

    let resp = client
        .get(url)
        .send()
        .await
        .map_err(|e| anyhow::anyhow!("network error: {}", e))?;

    if !resp.status().is_success() {
        let status = resp.status();
        anyhow::bail!("server returned {}: {}", status, url);
    }

    let total_bytes = resp.content_length();

    // Progress bar (only when not --no-progress and not --json)
    let pb: Option<indicatif::ProgressBar> = if !args.no_progress && !args.json {
        let pb = if let Some(total) = total_bytes {
            let pb = indicatif::ProgressBar::new(total);
            pb.set_style(
                indicatif::ProgressStyle::with_template(
                    "{spinner:.green} [{elapsed_precise}] [{bar:40.cyan/blue}] {bytes}/{total_bytes} ({eta})",
                )
                .unwrap()
                .progress_chars("=>-"),
            );
            pb
        } else {
            let pb = indicatif::ProgressBar::new_spinner();
            pb.set_style(
                indicatif::ProgressStyle::with_template(
                    "{spinner:.green} [{elapsed_precise}] {bytes} downloaded",
                )
                .unwrap(),
            );
            pb
        };
        Some(pb)
    } else {
        None
    };

    // Stream to .partial file
    let mut file = std::fs::File::create(&partial)
        .map_err(|e| anyhow::anyhow!("cannot write to {}: {}", partial.display(), e))?;

    let mut stream = resp.bytes_stream();
    let mut hasher = Sha256::new();
    let mut downloaded: u64 = 0;

    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| anyhow::anyhow!("stream error: {}", e))?;
        file.write_all(&chunk)
            .map_err(|e| anyhow::anyhow!("write error: {}", e))?;
        hasher.update(&chunk);
        downloaded += chunk.len() as u64;
        if let Some(ref pb) = pb {
            pb.set_position(downloaded);
        }
    }

    if let Some(pb) = pb {
        pb.finish_with_message("done");
    }

    // Atomic rename
    std::fs::rename(&partial, &target).map_err(|e| anyhow::anyhow!("rename failed: {}", e))?;

    let sha256 = format!("{:x}", hasher.finalize());

    if args.json {
        let report = DownloadReport {
            action: "downloaded".into(),
            filename: filename.into(),
            dest: dest.display().to_string(),
            success: true,
            message: format!("sha256: {}", sha256),
        };
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        eprintln!(
            "{} {} written to {}",
            "[2/2]".bold(),
            filename.cyan(),
            target.display()
        );
        eprintln!("  sha256: {}", sha256.dimmed());
    }

    Ok(())
}

// ── `life model list` ─────────────────────────────────────────────────────────

pub fn execute_list(args: ModelListArgs) -> Result<()> {
    let dir = Path::new(DEFAULT_MODELS_DIR);

    if !dir.exists() {
        if args.json {
            println!("[]");
        } else {
            eprintln!(
                "{} models directory '{}' does not exist — run `life model download` first",
                "⚠".yellow(),
                dir.display()
            );
        }
        return Ok(());
    }

    let mut entries: Vec<ModelEntry> = Vec::new();
    let read_dir = std::fs::read_dir(dir)?;

    for entry in read_dir.flatten() {
        let path = entry.path();
        if path.extension().map(|e| e == "gguf").unwrap_or(false) {
            let filename = entry.file_name().to_string_lossy().to_string();
            let size_bytes = entry.metadata().map(|m| m.len()).unwrap_or(0);
            let canonical = is_known_model(&filename);
            entries.push(ModelEntry {
                filename,
                size_bytes,
                canonical,
            });
        }
    }

    if args.json {
        println!("{}", serde_json::to_string_pretty(&entries)?);
        return Ok(());
    }

    if entries.is_empty() {
        eprintln!("{} no models found in {}", "⚠".yellow(), dir.display());
        return Ok(());
    }

    eprintln!("{}", "Models in /var/lib/lifeos/models/".bold());
    eprintln!("{}", "─".repeat(60).dimmed());
    for e in &entries {
        let kind = if e.canonical {
            "canonical".green()
        } else {
            "custom".yellow()
        };
        let size_mb = e.size_bytes / (1024 * 1024);
        eprintln!("  {} ({} MB)  [{}]", e.filename.cyan(), size_mb, kind);
    }

    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    // ── 1. test_resolve_model_url_4b ──────────────────────────────────────────

    #[test]
    fn test_resolve_model_url_4b() {
        let (filename, url) = resolve_model_url(ModelSize::FourB);
        assert_eq!(filename, "Qwen3.5-4B-Q4_K_M.gguf");
        assert_eq!(
            url,
            "https://huggingface.co/Qwen/Qwen3.5-4B-Instruct-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf"
        );
    }

    // ── 2. test_resolve_model_url_9b ──────────────────────────────────────────

    #[test]
    fn test_resolve_model_url_9b() {
        let (filename, url) = resolve_model_url(ModelSize::NineB);
        assert_eq!(filename, "Qwen3.5-9B-Q4_K_M.gguf");
        assert_eq!(
            url,
            "https://huggingface.co/Qwen/Qwen3.5-9B-Instruct-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf"
        );
    }

    // ── 3. test_filename_for_size_4b ──────────────────────────────────────────

    #[test]
    fn test_filename_for_size_4b() {
        let (filename, _url) = resolve_model_url(ModelSize::FourB);
        assert_eq!(filename, "Qwen3.5-4B-Q4_K_M.gguf");
    }

    // ── 4. test_already_present_skips_download ────────────────────────────────

    #[test]
    fn test_already_present_skips_download() {
        let tmp = TempDir::new().unwrap();
        let dest = tmp.path();
        let (filename, _url) = resolve_model_url(ModelSize::FourB);
        // Create the model file to simulate already-downloaded
        fs::write(dest.join(filename), b"fake gguf content").unwrap();

        let file_exists = dest.join(filename).exists();
        let action = decide_download(file_exists, false);
        assert_eq!(
            action,
            DownloadAction::Skip,
            "existing file without --force must be Skip"
        );
    }

    // ── 5. test_force_overrides_already_present ───────────────────────────────

    #[test]
    fn test_force_overrides_already_present() {
        let tmp = TempDir::new().unwrap();
        let dest = tmp.path();
        let (filename, _url) = resolve_model_url(ModelSize::FourB);
        // Create the model file to simulate already-downloaded
        fs::write(dest.join(filename), b"fake gguf content").unwrap();

        let file_exists = dest.join(filename).exists();
        let action = decide_download(file_exists, true);
        assert_eq!(
            action,
            DownloadAction::Download,
            "--force must produce Download even if file exists"
        );
    }

    // ── 6. test_download_decision_returns_action ──────────────────────────────

    #[test]
    fn test_download_decision_returns_action() {
        assert_eq!(
            decide_download(false, false),
            DownloadAction::Download,
            "missing file → Download"
        );
        assert_eq!(
            decide_download(false, true),
            DownloadAction::Download,
            "missing file + force → Download"
        );
        assert_eq!(
            decide_download(true, false),
            DownloadAction::Skip,
            "existing file → Skip"
        );
        assert_eq!(
            decide_download(true, true),
            DownloadAction::Download,
            "existing file + force → Download"
        );
    }

    // ── 7. test_partial_file_path_format ─────────────────────────────────────

    #[test]
    fn test_partial_file_path_format() {
        let dest = Path::new("/var/lib/lifeos/models");
        let (filename, _) = resolve_model_url(ModelSize::FourB);
        let partial = partial_path(dest, filename);
        assert_eq!(
            partial,
            PathBuf::from("/var/lib/lifeos/models/Qwen3.5-4B-Q4_K_M.gguf.partial")
        );
    }
}
