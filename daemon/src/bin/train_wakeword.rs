//! Standalone tool to generate a rustpotter `.rpw` wake word model from WAV samples.
//!
//! Usage:
//!   lifeos-train-wakeword --name axi --output /path/to/axi.rpw sample1.wav sample2.wav ...
//!
//! This binary is used during the image build (Containerfile) to generate
//! a pre-trained wake word model from TTS-synthesized samples, so wake word
//! detection works out-of-the-box on first boot.

use rustpotter::{WakewordRef, WakewordRefBuildFromFiles, WakewordSave};
use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().collect();

    let mut name = "axi".to_string();
    let mut output = "/var/lib/lifeos/models/rustpotter/axi.rpw".to_string();
    let mut samples: Vec<String> = Vec::new();

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--name" => {
                i += 1;
                name = args[i].clone();
            }
            "--output" | "-o" => {
                i += 1;
                output = args[i].clone();
            }
            "--help" | "-h" => {
                eprintln!(
                    "Usage: {} [--name NAME] [--output PATH] sample1.wav sample2.wav ...",
                    args[0]
                );
                std::process::exit(0);
            }
            arg => {
                if arg.starts_with('-') {
                    eprintln!("Unknown flag: {arg}");
                    std::process::exit(1);
                }
                samples.push(arg.to_string());
            }
        }
        i += 1;
    }

    if samples.len() < 3 {
        eprintln!(
            "Error: need at least 3 WAV samples, got {}. Provide WAV file paths as arguments.",
            samples.len()
        );
        std::process::exit(1);
    }

    // Verify all files exist
    for sample in &samples {
        if !Path::new(sample).exists() {
            eprintln!("Error: sample file not found: {sample}");
            std::process::exit(1);
        }
    }

    // Create parent directory
    if let Some(parent) = Path::new(&output).parent() {
        std::fs::create_dir_all(parent).ok();
    }

    eprintln!(
        "Building wake word model '{}' from {} samples...",
        name,
        samples.len()
    );

    let wakeword_ref = WakewordRef::new_from_sample_files(
        name.clone(),
        None, // default threshold
        None, // default avg_threshold
        samples,
        16, // mfcc_size — standard
    )
    .unwrap_or_else(|e| {
        eprintln!("Failed to build wake word model: {e}");
        std::process::exit(1);
    });

    wakeword_ref.save_to_file(&output).unwrap_or_else(|e| {
        eprintln!("Failed to save model to {output}: {e}");
        std::process::exit(1);
    });

    // Hearing audit round-2 C-NEW-5: the image-build bakes the rpw
    // file at umask default (observed 0o644 on user hosts). The model
    // encodes MFCC statistics of the enrollment voice — biometric PII.
    // Chmod 0o600 so only the lifeos user can read.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(md) = std::fs::metadata(&output) {
            let mut perms = md.permissions();
            perms.set_mode(0o600);
            let _ = std::fs::set_permissions(&output, perms);
        }
    }

    eprintln!("Wake word model saved to: {output}");
    eprintln!("Model name: {name}");
}
