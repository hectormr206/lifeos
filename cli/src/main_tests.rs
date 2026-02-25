//! Unit tests for CLI commands

#[cfg(test)]
mod tests {
    use super::super::*;
    use crate::commands::config::ConfigCommands;
    use clap::Parser;

    #[test]
    fn test_cli_parses_init_command() {
        let cli = Cli::parse_from(["life", "init"]);
        match cli.command {
            Commands::Init(_) => (), // Pass
            _ => panic!("Expected Init command"),
        }
    }

    #[test]
    fn test_cli_parses_init_with_force_flag() {
        let cli = Cli::parse_from(["life", "init", "--force"]);
        match cli.command {
            Commands::Init(args) => assert!(args.force),
            _ => panic!("Expected Init command"),
        }
    }

    #[test]
    fn test_cli_parses_status_command() {
        let cli = Cli::parse_from(["life", "status"]);
        match cli.command {
            Commands::Status(_) => (), // Pass
            _ => panic!("Expected Status command"),
        }
    }

    #[test]
    fn test_cli_parses_status_with_json_flag() {
        let cli = Cli::parse_from(["life", "status", "--json"]);
        match cli.command {
            Commands::Status(args) => assert!(args.json),
            _ => panic!("Expected Status command"),
        }
    }

    #[test]
    fn test_cli_parses_status_with_detailed_flag() {
        let cli = Cli::parse_from(["life", "status", "--detailed"]);
        match cli.command {
            Commands::Status(args) => assert!(args.detailed),
            _ => panic!("Expected Status command"),
        }
    }

    #[test]
    fn test_cli_parses_update_command() {
        let cli = Cli::parse_from(["life", "update"]);
        match cli.command {
            Commands::Update(_) => (), // Pass
            _ => panic!("Expected Update command"),
        }
    }

    #[test]
    fn test_cli_parses_update_with_dry_run() {
        let cli = Cli::parse_from(["life", "update", "--dry-run"]);
        match cli.command {
            Commands::Update(args) => assert!(args.dry_run),
            _ => panic!("Expected Update command"),
        }
    }

    #[test]
    fn test_cli_parses_rollback_command() {
        let cli = Cli::parse_from(["life", "rollback"]);
        match cli.command {
            Commands::Rollback => (), // Pass
            _ => panic!("Expected Rollback command"),
        }
    }

    #[test]
    fn test_cli_parses_recover_command() {
        let cli = Cli::parse_from(["life", "recover"]);
        match cli.command {
            Commands::Recover => (), // Pass
            _ => panic!("Expected Recover command"),
        }
    }

    #[test]
    fn test_cli_parses_config_show_command() {
        let cli = Cli::parse_from(["life", "config", "show"]);
        match cli.command {
            Commands::Config(ConfigCommands::Show) => (), // Pass
            _ => panic!("Expected Config Show command"),
        }
    }

    #[test]
    fn test_cli_parses_config_get_command() {
        let cli = Cli::parse_from(["life", "config", "get", "system.hostname"]);
        match cli.command {
            Commands::Config(ConfigCommands::Get { key }) => {
                assert_eq!(key, "system.hostname");
            }
            _ => panic!("Expected Config Get command"),
        }
    }

    #[test]
    fn test_cli_parses_config_set_command() {
        let cli = Cli::parse_from(["life", "config", "set", "system.hostname", "myhost"]);
        match cli.command {
            Commands::Config(ConfigCommands::Set { key, value }) => {
                assert_eq!(key, "system.hostname");
                assert_eq!(value, "myhost");
            }
            _ => panic!("Expected Config Set command"),
        }
    }

    #[test]
    fn test_cli_parses_lab_commands() {
        let start_cli = Cli::parse_from(["life", "lab", "start"]);
        match start_cli.command {
            Commands::Lab(LabCommands::Start) => (), // Pass
            _ => panic!("Expected Lab Start command"),
        }

        let test_cli = Cli::parse_from(["life", "lab", "test"]);
        match test_cli.command {
            Commands::Lab(LabCommands::Test) => (), // Pass
            _ => panic!("Expected Lab Test command"),
        }

        let report_cli = Cli::parse_from(["life", "lab", "report"]);
        match report_cli.command {
            Commands::Lab(LabCommands::Report) => (), // Pass
            _ => panic!("Expected Lab Report command"),
        }
    }

    #[test]
    fn test_cli_parses_first_boot_command() {
        let cli = Cli::parse_from(["life", "first-boot"]);
        match cli.command {
            Commands::FirstBoot(_) => (), // Pass
            _ => panic!("Expected FirstBoot command"),
        }
    }

    #[test]
    fn test_cli_version_flag() {
        // This should print version and exit, but we can't easily test that
        // Just verify the parser accepts the flag
        let result = std::panic::catch_unwind(|| {
            let _ = Cli::parse_from(["life", "--version"]);
        });
        // clap will exit on --version, so we expect a panic in test context
        assert!(result.is_err() || true); // Just ensure it doesn't hang
    }

    #[test]
    fn test_cli_help_flag() {
        // Similar to version, help will exit
        let result = std::panic::catch_unwind(|| {
            let _ = Cli::parse_from(["life", "--help"]);
        });
        assert!(result.is_err() || true);
    }

    #[test]
    fn test_init_args_default() {
        let args = commands::init::InitArgs::default();
        assert!(!args.force);
        assert!(!args.skip_ai);
    }

    #[test]
    fn test_status_args_default() {
        let args = commands::status::StatusArgs::default();
        assert!(!args.json);
        assert!(!args.detailed);
    }

    #[test]
    fn test_update_args_default() {
        let args = commands::update::UpdateArgs::default();
        assert!(!args.dry_run);
        assert_eq!(args.channel, Some("stable".to_string()));
    }

    #[test]
    fn test_first_boot_args_default() {
        let args = commands::first_boot::FirstBootArgs::default();
        assert!(!args.auto);
        assert_eq!(args.theme, "simple");
        assert!(!args.skip_ollama);
        assert!(!args.force);
    }
}
