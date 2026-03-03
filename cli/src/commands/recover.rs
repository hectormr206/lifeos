use crate::system;
use colored::Colorize;

pub async fn execute() -> anyhow::Result<()> {
    println!("{}", "🔧 Running system recovery checks...".blue().bold());
    println!();

    // Perform recovery
    match system::perform_recovery().await {
        Ok(report) => {
            println!("{}", "Health Checks:".bold());
            for check in &report.checks {
                let icon = if check.passed {
                    "✓".green()
                } else {
                    "✗".red()
                };
                let status = if check.passed {
                    "OK".green()
                } else {
                    "FAILED".red()
                };
                println!(
                    "  {} {}: {} - {}",
                    icon,
                    check.name.bold(),
                    status,
                    check.message
                );
            }

            println!();

            // Summary
            let passed = report.checks.iter().filter(|c| c.passed).count();
            let total = report.checks.len();

            if passed == total {
                println!(
                    "{}",
                    format!("✅ All {} checks passed", total).green().bold()
                );
            } else {
                println!(
                    "{}",
                    format!("⚠️  {}/{} checks passed", passed, total)
                        .yellow()
                        .bold()
                );
            }

            if !report.repairs.is_empty() {
                println!();
                println!("{}", "Repairs performed:".bold());
                for repair in &report.repairs {
                    println!("  • {}", repair);
                }
            }

            if report.needs_reboot {
                println!();
                println!("{}", "🔄 System reboot required".yellow().bold());
            }

            // Overall health
            println!();
            let health = system::check_health();
            match health {
                system::HealthStatus::Healthy => {
                    println!("{}", "✅ System is healthy".green().bold());
                }
                system::HealthStatus::Degraded(msg) => {
                    println!(
                        "{}",
                        format!("⚠️  System is degraded: {}", msg).yellow().bold()
                    );
                }
                system::HealthStatus::Unhealthy(msg) => {
                    println!(
                        "{}",
                        format!("❌ System is unhealthy: {}", msg).red().bold()
                    );
                }
            }
        }
        Err(e) => {
            anyhow::bail!("Recovery check failed: {}", e);
        }
    }

    Ok(())
}
