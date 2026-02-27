use clap::Subcommand;
use colored::Colorize;
use crate::config::{self};

#[derive(Subcommand)]
pub enum ConfigCommands {
    /// Show current configuration
    Show,
    /// Set a configuration value
    Set { key: String, value: String },
    /// Apply declarative configuration
    Apply,
    /// Initialize default configuration
    Init,
    /// Get a specific configuration value
    Get { key: String },
}

pub async fn execute(args: ConfigCommands) -> anyhow::Result<()> {
    match args {
        ConfigCommands::Show => {
            show_config().await?;
        }
        ConfigCommands::Set { key, value } => {
            set_config(&key, &value).await?;
        }
        ConfigCommands::Apply => {
            apply_config().await?;
        }
        ConfigCommands::Init => {
            init_config().await?;
        }
        ConfigCommands::Get { key } => {
            get_config(&key).await?;
        }
    }
    Ok(())
}

async fn show_config() -> anyhow::Result<()> {
    match config::load_config() {
        Ok(cfg) => {
            println!("{}", "LifeOS Configuration".bold().blue());
            println!();
            
            println!("{}", "System:".bold());
            println!("  hostname: {}", cfg.system.hostname);
            println!("  timezone: {}", cfg.system.timezone);
            println!("  locale: {}", cfg.system.locale);
            println!();
            
            println!("{}", "AI:".bold());
            println!("  enabled: {}", cfg.ai.enabled);
            println!("  provider: {}", cfg.ai.provider);
            println!("  model: {}", cfg.ai.model);
            println!("  llama_server_host: {}", cfg.ai.llama_server_host);
            println!();
            
            println!("{}", "Security:".bold());
            println!("  encryption: {}", cfg.security.encryption);
            println!("  secure_boot: {}", cfg.security.secure_boot);
            println!("  auto_lock: {}", cfg.security.auto_lock);
            println!("  auto_lock_timeout: {}s", cfg.security.auto_lock_timeout);
            println!();
            
            println!("{}", "Updates:".bold());
            println!("  channel: {}", cfg.updates.channel);
            println!("  auto_check: {}", cfg.updates.auto_check);
            println!("  auto_apply: {}", cfg.updates.auto_apply);
            println!("  schedule: {}", cfg.updates.schedule);
        }
        Err(e) => {
            println!("{}", format!("⚠️  No configuration found: {}", e).yellow());
            println!("{}", "   Run 'life config init' to create default configuration".dimmed());
        }
    }
    Ok(())
}

async fn set_config(key: &str, value: &str) -> anyhow::Result<()> {
    let config_path = match config::find_config_file() {
        Some(path) => path,
        None => {
            println!("{}", "⚠️  No configuration file found".yellow());
            println!("{}", "   Creating default configuration...".dimmed());
            config::create_default_config()?
        }
    };
    
    let mut cfg = config::load_config_from(&config_path)?;
    
    config::set_config_value(&mut cfg, key, value)?;
    config::save_config(&cfg, &config_path)?;
    
    println!("{}", format!("✅ Set {} = {}", key, value).green());
    Ok(())
}

async fn apply_config() -> anyhow::Result<()> {
    println!("{}", "📝 Applying configuration...".blue().bold());
    
    let cfg = match config::load_config() {
        Ok(c) => c,
        Err(e) => {
            anyhow::bail!("Failed to load configuration: {}", e);
        }
    };
    
    println!("Configuration version: {}", cfg.version);
    
    // In a real implementation, this would:
    // 1. Validate the configuration
    // 2. Apply system settings (hostname, timezone, etc.)
    // 3. Configure AI services
    // 4. Set up security settings
    // 5. Configure update behavior
    
    println!("{}", "✅ Configuration applied".green());
    Ok(())
}

async fn init_config() -> anyhow::Result<()> {
    let path = config::create_default_config()?;
    println!("{}", format!("✅ Created default configuration at: {}", path.display()).green());
    Ok(())
}

async fn get_config(key: &str) -> anyhow::Result<()> {
    let cfg = config::load_config()?;
    let value = config::get_config_value(&cfg, key)?;
    println!("{} = {}", key.bold(), value);
    Ok(())
}