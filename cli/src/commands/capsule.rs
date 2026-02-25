use clap::Subcommand;

#[derive(Subcommand)]
pub enum CapsuleCommands {
    /// Export system state
    Export,
    /// Restore from export
    Restore { path: String },
}

pub async fn execute(args: CapsuleCommands) -> anyhow::Result<()> {
    match args {
        CapsuleCommands::Export => {
            println!("Exporting system state...");
            // TODO: Implement export with age encryption
        }
        CapsuleCommands::Restore { path } => {
            println!("Restoring from: {}", path);
            // TODO: Implement restore
        }
    }
    Ok(())
}
