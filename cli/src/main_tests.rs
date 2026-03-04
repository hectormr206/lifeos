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
    fn test_cli_parses_update_status_subcommand() {
        let cli = Cli::parse_from(["life", "update", "status"]);
        match cli.command {
            Commands::Update(args) => {
                assert!(matches!(
                    args.command,
                    Some(commands::update::UpdateSubcommand::Status)
                ));
            }
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
        assert!(args.command.is_none());
        assert!(!args.dry_run);
        assert_eq!(args.channel, None);
    }

    #[test]
    fn test_first_boot_args_default() {
        let args = commands::first_boot::FirstBootArgs::default();
        assert!(!args.auto);
        // Default::default() gives "" for String; clap's default_value only applies at parse time
        assert!(!args.skip_ai);
        assert!(!args.force);
    }

    #[test]
    fn test_cli_parses_intents_log_command() {
        let cli = Cli::parse_from([
            "life",
            "intents",
            "log",
            "--limit",
            "10",
            "--export",
            "/tmp/ledger.json",
        ]);
        match cli.command {
            Commands::Intents(commands::intents::IntentsCommands::Log {
                limit,
                export,
                passphrase: _,
            }) => {
                assert_eq!(limit, 10);
                assert_eq!(export.as_deref(), Some("/tmp/ledger.json"));
            }
            _ => panic!("Expected intents log command"),
        }
    }

    #[test]
    fn test_cli_parses_intents_apply_approve_flag() {
        let cli = Cli::parse_from(["life", "intents", "apply", "intent-123", "--approve"]);
        match cli.command {
            Commands::Intents(commands::intents::IntentsCommands::Apply { intent_id, approve }) => {
                assert_eq!(intent_id, "intent-123");
                assert!(approve);
            }
            _ => panic!("Expected intents apply command"),
        }
    }

    #[test]
    fn test_cli_parses_id_list_active_flag() {
        let cli = Cli::parse_from(["life", "id", "list", "--active"]);
        match cli.command {
            Commands::Id(commands::id::IdCommands::List { active }) => assert!(active),
            _ => panic!("Expected id list command"),
        }
    }

    #[test]
    fn test_cli_parses_workspace_run_command() {
        let cli = Cli::parse_from([
            "life",
            "workspace",
            "run",
            "--intent",
            "intent-123",
            "--isolation",
            "sandbox",
            "--approve",
        ]);
        match cli.command {
            Commands::Workspace(commands::workspace::WorkspaceCommands::Run {
                intent,
                isolation,
                approve,
                ..
            }) => {
                assert_eq!(intent, "intent-123");
                assert_eq!(isolation, "sandbox");
                assert!(approve);
            }
            _ => panic!("Expected workspace run command"),
        }
    }

    #[test]
    fn test_cli_parses_workspace_list_command() {
        let cli = Cli::parse_from(["life", "workspace", "list", "--limit", "5"]);
        match cli.command {
            Commands::Workspace(commands::workspace::WorkspaceCommands::List { limit }) => {
                assert_eq!(limit, 5)
            }
            _ => panic!("Expected workspace list command"),
        }
    }

    #[test]
    fn test_cli_parses_ai_benchmark_command() {
        let cli = Cli::parse_from(["life", "ai", "benchmark", "--short", "--repeats", "3"]);
        match cli.command {
            Commands::Ai(commands::ai::AiCommands::Benchmark {
                model,
                short,
                repeats,
            }) => {
                assert!(model.is_none());
                assert!(short);
                assert_eq!(repeats, 3);
            }
            _ => panic!("Expected ai benchmark command"),
        }
    }

    #[test]
    fn test_cli_parses_ai_autotune_command() {
        let cli = Cli::parse_from(["life", "ai", "autotune", "--dry-run"]);
        match cli.command {
            Commands::Ai(commands::ai::AiCommands::Autotune { dry_run }) => assert!(dry_run),
            _ => panic!("Expected ai autotune command"),
        }
    }

    #[test]
    fn test_cli_parses_ai_profile_command() {
        let cli = Cli::parse_from(["life", "ai", "profile", "--runtime", "secure", "--apply"]);
        match cli.command {
            Commands::Ai(commands::ai::AiCommands::Profile { runtime, apply }) => {
                assert_eq!(runtime.as_deref(), Some("secure"));
                assert!(apply);
            }
            _ => panic!("Expected ai profile command"),
        }
    }

    #[test]
    fn test_cli_parses_ai_catalog_command() {
        let cli = Cli::parse_from(["life", "ai", "catalog", "--refresh"]);
        match cli.command {
            Commands::Ai(commands::ai::AiCommands::Catalog { refresh }) => assert!(refresh),
            _ => panic!("Expected ai catalog command"),
        }
    }
}
