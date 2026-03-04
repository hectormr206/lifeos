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
    let client = daemon_client::authenticated_client();
    let base = daemon_client::daemon_url();

    let create_profile = client
        .post(format!("{}/api/v1/context/profile", base))
        .json(&serde_json::json!({
            "name": context,
            "description": description,
            "priority": 3,
        }))
        .send()
        .await;

    let create_profile = match create_profile {
        Ok(resp) => resp,
        Err(_) => {
            println!(
                "{}",
                "Cannot connect to lifeosd. Is the daemon running?".red()
            );
            println!("  Try: {}", "sudo systemctl start lifeosd".cyan());
            return Ok(());
        }
    };

    if !create_profile.status().is_success() {
        let status = create_profile.status();
        let body = create_profile.text().await.unwrap_or_default();
        anyhow::bail!(
            "Failed to prepare '{}' preset profile ({}): {}",
            context,
            status,
            body
        );
    }

    for rule in rules {
        let response = client
            .post(format!("{}/api/v1/context/profile/{}/rule", base, context))
            .json(&serde_json::json!({
                "rule_type": rule.rule_type,
                "value": rule.value,
            }))
            .send()
            .await?;
        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            anyhow::bail!(
                "Failed to apply '{}' rule for preset '{}': {} ({})",
                rule.rule_type,
                context,
                status,
                body
            );
        }
    }

    let set_context = client
        .post(format!("{}/api/v1/context/set", base))
        .json(&serde_json::json!({ "context": context }))
        .send()
        .await?;

    if !set_context.status().is_success() {
        let status = set_context.status();
        let body = set_context.text().await.unwrap_or_default();
        anyhow::bail!(
            "Failed to activate '{}' preset context: {} ({})",
            context,
            status,
            body
        );
    }

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
