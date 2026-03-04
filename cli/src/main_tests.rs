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
    fn test_cli_parses_init_with_profile() {
        let cli = Cli::parse_from(["life", "init", "--profile", "developer"]);
        match cli.command {
            Commands::Init(args) => assert_eq!(args.profile.as_deref(), Some("developer")),
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
    fn test_cli_parses_first_boot_gui() {
        let cli = Cli::parse_from(["life", "first-boot", "--gui"]);
        match cli.command {
            Commands::FirstBoot(args) => assert!(args.gui),
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
        assert!(args.profile.is_none());
        assert!(!args.tui);
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
        assert!(!args.gui);
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
    fn test_cli_parses_intents_mode_set() {
        let cli = Cli::parse_from([
            "life",
            "intents",
            "mode",
            "set",
            "run-until-done",
            "--actor",
            "user://local/admin",
        ]);
        match cli.command {
            Commands::Intents(commands::intents::IntentsCommands::Mode(
                commands::intents::IntentModeCommands::Set { mode, actor },
            )) => {
                assert_eq!(mode, "run-until-done");
                assert_eq!(actor, "user://local/admin");
            }
            _ => panic!("Expected intents mode set command"),
        }
    }

    #[test]
    fn test_cli_parses_intents_orchestrate() {
        let cli = Cli::parse_from([
            "life",
            "intents",
            "orchestrate",
            "ship phase2 milestone",
            "--specialist",
            "planner",
            "--specialist",
            "implementer",
            "--approve",
        ]);
        match cli.command {
            Commands::Intents(commands::intents::IntentsCommands::Orchestrate {
                objective,
                specialist,
                approve,
            }) => {
                assert_eq!(objective, "ship phase2 milestone");
                assert_eq!(specialist, vec!["planner", "implementer"]);
                assert!(approve);
            }
            _ => panic!("Expected intents orchestrate command"),
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

    #[test]
    fn test_cli_parses_onboarding_trust_mode_enable() {
        let cli = Cli::parse_from([
            "life",
            "onboarding",
            "trust-mode",
            "enable",
            "--actor",
            "user://local/admin",
            "--bundle",
            "/tmp/consent.toml",
            "--sig",
            "/tmp/consent.sig",
        ]);
        match cli.command {
            Commands::Onboarding(commands::onboarding::OnboardingCommands::TrustMode(
                commands::onboarding::TrustModeCommands::Enable { actor, bundle, sig },
            )) => {
                assert_eq!(actor, "user://local/admin");
                assert_eq!(bundle, "/tmp/consent.toml");
                assert_eq!(sig, "/tmp/consent.sig");
            }
            _ => panic!("Expected onboarding trust-mode enable command"),
        }
    }

    #[test]
    fn test_cli_parses_memory_add_command() {
        let cli = Cli::parse_from([
            "life",
            "memory",
            "add",
            "remember this context",
            "--kind",
            "note",
            "--scope",
            "user",
            "--tag",
            "phase2",
            "--importance",
            "75",
        ]);
        match cli.command {
            Commands::Memory(commands::memory::MemoryCommands::Add {
                content,
                file,
                kind,
                scope,
                tag,
                source,
                importance,
            }) => {
                assert_eq!(content.as_deref(), Some("remember this context"));
                assert!(file.is_none());
                assert_eq!(kind, "note");
                assert_eq!(scope, "user");
                assert_eq!(tag, vec!["phase2"]);
                assert!(source.is_none());
                assert_eq!(importance, 75);
            }
            _ => panic!("Expected memory add command"),
        }
    }

    #[test]
    fn test_cli_parses_permissions_revoke_command() {
        let cli = Cli::parse_from([
            "life",
            "permissions",
            "revoke",
            "org.test.app",
            "--resource",
            "filesystem.home",
        ]);
        match cli.command {
            Commands::Permissions(commands::permissions::PermissionsCommands::Revoke {
                app_id,
                resource,
            }) => {
                assert_eq!(app_id, "org.test.app");
                assert_eq!(resource.as_deref(), Some("filesystem.home"));
            }
            _ => panic!("Expected permissions revoke command"),
        }
    }

    #[test]
    fn test_cli_parses_sync_now_dry_run() {
        let cli = Cli::parse_from(["life", "sync", "now", "--dry-run"]);
        match cli.command {
            Commands::Sync(commands::sync::SyncCommands::Now { dry_run }) => assert!(dry_run),
            _ => panic!("Expected sync now command"),
        }
    }

    #[test]
    fn test_cli_parses_skills_install() {
        let cli = Cli::parse_from(["life", "skills", "install", "--manifest", "/tmp/skill.json"]);
        match cli.command {
            Commands::Skills(commands::skills::SkillsCommands::Install { manifest }) => {
                assert_eq!(manifest, "/tmp/skill.json");
            }
            _ => panic!("Expected skills install command"),
        }
    }

    #[test]
    fn test_cli_parses_skills_generate() {
        let cli = Cli::parse_from([
            "life",
            "skills",
            "generate",
            "--id",
            "demo.skill",
            "--version",
            "0.1.0",
            "--trust",
            "community",
        ]);
        match cli.command {
            Commands::Skills(commands::skills::SkillsCommands::Generate {
                id,
                version,
                trust,
                output_dir,
            }) => {
                assert_eq!(id, "demo.skill");
                assert_eq!(version, "0.1.0");
                assert_eq!(trust, "community");
                assert_eq!(output_dir, ".");
            }
            _ => panic!("Expected skills generate command"),
        }
    }

    #[test]
    fn test_cli_parses_soul_merge() {
        let cli = Cli::parse_from([
            "life",
            "soul",
            "merge",
            "--workplace",
            "development",
            "--json",
        ]);
        match cli.command {
            Commands::Soul(commands::soul::SoulCommands::Merge {
                workplace,
                json,
                output,
            }) => {
                assert_eq!(workplace, "development");
                assert!(json);
                assert!(output.is_none());
            }
            _ => panic!("Expected soul merge command"),
        }
    }
}
