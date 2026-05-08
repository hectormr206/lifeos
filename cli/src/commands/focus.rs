use colored::Colorize;

use crate::daemon_client;

struct PresetRule {
    rule_type: &'static str,
    value: &'static str,
}

pub async fn execute_focus() -> anyhow::Result<()> {
    apply_preset(
        "focus",
        "Flow",
        "Deep focus preset with low distraction and stricter privacy defaults.",
        &[
            PresetRule {
                rule_type: "mode",
                value: "pro",
            },
            PresetRule {
                rule_type: "notifications",
                value: "off",
            },
            PresetRule {
                rule_type: "capture",
                value: "off",
            },
            PresetRule {
                rule_type: "privacy",
                value: "strict",
            },
        ],
    )
    .await
}

pub async fn execute_meeting() -> anyhow::Result<()> {
    apply_preset(
        "meeting",
        "Meeting",
        "Meeting preset optimized for calls and screen sharing.",
        &[
            PresetRule {
                rule_type: "mode",
                value: "pro",
            },
            PresetRule {
                rule_type: "notifications",
                value: "off",
            },
            PresetRule {
                rule_type: "capture",
                value: "on",
            },
            PresetRule {
                rule_type: "privacy",
                value: "guarded",
            },
        ],
    )
    .await
}

async fn apply_preset(
    context: &str,
    display: &str,
    description: &str,
    rules: &[PresetRule],
) -> anyhow::Result<()> {
    let create_payload = serde_json::json!({
        "name": context,
        "description": description,
        "priority": 3,
    });
    let _: serde_json::Value = daemon_client::post_json("/api/v1/context/profile", &create_payload)
        .await
        .inspect_err(|e| {
            if e.to_string().contains("is lifeosd running") {
                println!(
                    "{}",
                    "Cannot connect to lifeosd. Is the daemon running?".red()
                );
                println!("  Try: {}", "sudo systemctl start lifeosd".cyan());
            }
        })?;

    for rule in rules {
        let rule_payload = serde_json::json!({
            "rule_type": rule.rule_type,
            "value": rule.value,
        });
        let path = format!("/api/v1/context/profile/{}/rule", context);
        let _: serde_json::Value = daemon_client::post_json(&path, &rule_payload).await?;
    }

    let set_payload = serde_json::json!({ "context": context });
    let _: serde_json::Value =
        daemon_client::post_json("/api/v1/context/set", &set_payload).await?;

    println!(
        "{} {}",
        "Context preset activated:".green().bold(),
        display.cyan().bold()
    );
    println!("  context: {}", context.cyan());
    println!("  description: {}", description);
    println!("  rules:");
    for rule in rules {
        println!("    - {}={}", rule.rule_type, rule.value.dimmed());
    }

    Ok(())
}
