use clap::Subcommand;
use colored::Colorize;
use std::path::{Path, PathBuf};

#[derive(Subcommand)]
pub enum SoulCommands {
    /// Initialize user Soul Plane directory and base profile
    Init {
        /// Overwrite existing base profile
        #[arg(long)]
        force: bool,
    },
    /// Resolve merged Soul configuration (global -> user -> workplace)
    Merge {
        /// Workplace profile name (e.g. work, gaming, dev)
        #[arg(long, default_value = "base")]
        workplace: String,
        /// Print merged result as JSON instead of TOML
        #[arg(long)]
        json: bool,
        /// Optional output file path
        #[arg(long)]
        output: Option<String>,
    },
    /// Set user Soul value using dotted key syntax
    Set {
        key: String,
        value: String,
        /// Profile file name under ~/.config/lifeos/soul (default: base)
        #[arg(long, default_value = "base")]
        profile: String,
    },
    /// Show Soul profile contents
    Show {
        /// Profile file name (default: base)
        #[arg(long, default_value = "base")]
        profile: String,
        /// Read from global defaults instead of user profile
        #[arg(long)]
        global: bool,
    },
}

pub async fn execute(cmd: SoulCommands) -> anyhow::Result<()> {
    match cmd {
        SoulCommands::Init { force } => cmd_init(force),
        SoulCommands::Merge {
            workplace,
            json,
            output,
        } => cmd_merge(&workplace, json, output.as_deref()),
        SoulCommands::Set {
            key,
            value,
            profile,
        } => cmd_set(&profile, &key, &value),
        SoulCommands::Show { profile, global } => cmd_show(&profile, global),
    }
}

fn cmd_init(force: bool) -> anyhow::Result<()> {
    let dir = user_soul_dir()?;
    std::fs::create_dir_all(&dir)?;
    let base_file = profile_path(false, "base")?;

    if base_file.exists() && !force {
        println!("{}", "Soul base profile already exists".yellow().bold());
        println!("  path: {}", base_file.display().to_string().cyan());
        println!("  use --force to overwrite");
        return Ok(());
    }

    let template = r#"[identity]
name = "LifeOS User"
persona = "calm-pragmatic"

[assistant]
verbosity = "balanced"
autonomy = "guarded"

[preferences]
language = "es-MX"
"#;

    std::fs::write(&base_file, template)?;
    println!("{}", "Soul Plane initialized".green().bold());
    println!("  dir: {}", dir.display().to_string().cyan());
    println!("  base: {}", base_file.display().to_string().cyan());
    Ok(())
}

fn cmd_merge(workplace: &str, as_json: bool, output: Option<&str>) -> anyhow::Result<()> {
    let merged = resolve_merged_soul(workplace)?;
    let rendered = if as_json {
        serde_json::to_string_pretty(&toml_to_json_value(&merged))?
    } else {
        toml::to_string_pretty(&merged)?
    };

    if let Some(path) = output {
        std::fs::write(path, &rendered)?;
        println!("{}", "Merged Soul configuration exported".green().bold());
        println!("  file: {}", path.cyan());
    } else {
        println!("{}", "Merged Soul configuration".bold().blue());
        println!("{}", rendered);
    }
    Ok(())
}

fn cmd_set(profile: &str, key: &str, value: &str) -> anyhow::Result<()> {
    let path = profile_path(false, profile)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let mut root = load_toml_or_empty(&path)?;
    set_dotted_value(&mut root, key, parse_toml_literal(value))?;
    std::fs::write(&path, toml::to_string_pretty(&root)?)?;

    println!("{}", "Soul value updated".green().bold());
    println!("  profile: {}", profile.cyan());
    println!("  key: {}", key.cyan());
    Ok(())
}

fn cmd_show(profile: &str, global: bool) -> anyhow::Result<()> {
    let path = profile_path(global, profile)?;
    if !path.exists() {
        anyhow::bail!("Profile not found: {}", path.display());
    }
    let content = std::fs::read_to_string(&path)?;
    println!(
        "{}",
        if global {
            "Global Soul profile".bold().blue()
        } else {
            "User Soul profile".bold().blue()
        }
    );
    println!("  file: {}", path.display().to_string().cyan());
    println!();
    println!("{}", content);
    Ok(())
}

fn resolve_merged_soul(workplace: &str) -> anyhow::Result<toml::Value> {
    let mut merged = toml::Value::Table(toml::map::Map::new());
    let base = "base";
    let scopes = [true, false];

    for global in scopes {
        let path = profile_path(global, base)?;
        deep_merge(&mut merged, load_toml_or_empty(&path)?);
    }

    let workplace = workplace.trim();
    if !workplace.is_empty() && workplace != "base" {
        for global in scopes {
            let path = profile_path(global, workplace)?;
            deep_merge(&mut merged, load_toml_or_empty(&path)?);
        }
    }

    Ok(merged)
}

fn profile_path(global: bool, profile: &str) -> anyhow::Result<PathBuf> {
    let file = format!("{}.toml", profile.trim());
    if global {
        Ok(PathBuf::from("/etc/lifeos/soul.defaults").join(file))
    } else {
        Ok(user_soul_dir()?.join(file))
    }
}

fn user_soul_dir() -> anyhow::Result<PathBuf> {
    dirs::config_dir()
        .map(|p| p.join("lifeos").join("soul"))
        .ok_or_else(|| anyhow::anyhow!("Could not determine config directory"))
}

fn load_toml_or_empty(path: &Path) -> anyhow::Result<toml::Value> {
    if !path.exists() {
        return Ok(toml::Value::Table(toml::map::Map::new()));
    }
    let content = std::fs::read_to_string(path)?;
    let parsed = toml::from_str::<toml::Value>(&content)
        .map_err(|e| anyhow::anyhow!("Invalid TOML at {}: {}", path.display(), e))?;
    Ok(parsed)
}

fn deep_merge(dst: &mut toml::Value, src: toml::Value) {
    match (dst, src) {
        (toml::Value::Table(dst_table), toml::Value::Table(src_table)) => {
            for (key, src_value) in src_table {
                match dst_table.get_mut(&key) {
                    Some(dst_value) => deep_merge(dst_value, src_value),
                    None => {
                        dst_table.insert(key, src_value);
                    }
                }
            }
        }
        (dst_slot, src_value) => *dst_slot = src_value,
    }
}

fn parse_toml_literal(raw: &str) -> toml::Value {
    let trimmed = raw.trim();
    if trimmed.eq_ignore_ascii_case("true") {
        return toml::Value::Boolean(true);
    }
    if trimmed.eq_ignore_ascii_case("false") {
        return toml::Value::Boolean(false);
    }
    if let Ok(v) = trimmed.parse::<i64>() {
        return toml::Value::Integer(v);
    }
    if let Ok(v) = trimmed.parse::<f64>() {
        return toml::Value::Float(v);
    }
    toml::Value::String(trimmed.to_string())
}

fn set_dotted_value(root: &mut toml::Value, key: &str, value: toml::Value) -> anyhow::Result<()> {
    let mut parts = key.split('.').peekable();
    if parts.peek().is_none() {
        anyhow::bail!("Key cannot be empty");
    }

    let mut current = root;
    while let Some(part) = parts.next() {
        let is_last = parts.peek().is_none();
        if is_last {
            match current {
                toml::Value::Table(map) => {
                    map.insert(part.to_string(), value);
                    return Ok(());
                }
                _ => anyhow::bail!("Cannot set key under non-table value"),
            }
        }

        match current {
            toml::Value::Table(map) => {
                if !map.contains_key(part) {
                    map.insert(part.to_string(), toml::Value::Table(toml::map::Map::new()));
                }
                current = map
                    .get_mut(part)
                    .ok_or_else(|| anyhow::anyhow!("Failed to traverse key"))?;
            }
            _ => anyhow::bail!("Cannot traverse non-table value at '{}'", part),
        }
    }

    Ok(())
}

fn toml_to_json_value(value: &toml::Value) -> serde_json::Value {
    match value {
        toml::Value::String(v) => serde_json::Value::String(v.clone()),
        toml::Value::Integer(v) => serde_json::Value::Number((*v).into()),
        toml::Value::Float(v) => serde_json::Number::from_f64(*v)
            .map(serde_json::Value::Number)
            .unwrap_or(serde_json::Value::Null),
        toml::Value::Boolean(v) => serde_json::Value::Bool(*v),
        toml::Value::Datetime(v) => serde_json::Value::String(v.to_string()),
        toml::Value::Array(items) => {
            serde_json::Value::Array(items.iter().map(toml_to_json_value).collect())
        }
        toml::Value::Table(map) => {
            let mut out = serde_json::Map::new();
            for (k, v) in map {
                out.insert(k.clone(), toml_to_json_value(v));
            }
            serde_json::Value::Object(out)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deep_merge_overrides_with_user_values() {
        let mut base = toml::from_str::<toml::Value>(
            r#"
[assistant]
verbosity = "low"
[preferences]
language = "en-US"
"#,
        )
        .unwrap();
        let user = toml::from_str::<toml::Value>(
            r#"
[assistant]
verbosity = "high"
[preferences]
theme = "solarized"
"#,
        )
        .unwrap();

        deep_merge(&mut base, user);
        assert_eq!(base["assistant"]["verbosity"].as_str().unwrap(), "high");
        assert_eq!(base["preferences"]["language"].as_str().unwrap(), "en-US");
        assert_eq!(base["preferences"]["theme"].as_str().unwrap(), "solarized");
    }

    #[test]
    fn set_dotted_value_builds_nested_tables() {
        let mut root = toml::Value::Table(toml::map::Map::new());
        set_dotted_value(
            &mut root,
            "assistant.voice.enabled",
            toml::Value::Boolean(true),
        )
        .unwrap();
        assert!(root["assistant"]["voice"]["enabled"].as_bool().unwrap());
    }
}
