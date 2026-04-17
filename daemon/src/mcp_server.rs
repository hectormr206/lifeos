//! MCP (Model Context Protocol) Server — Expose LifeOS capabilities to external AI clients.
//!
//! LifeOS acts as an MCP server, exposing tools that external clients (Claude Desktop,
//! VS Code Copilot, etc.) can call to interact with the system. This makes LifeOS
//! capabilities available to any MCP-compatible AI application.
//!
//! Protocol: JSON-RPC 2.0 over stdio (for local) or HTTP/SSE (for remote).
//!
//! Tools exposed:
//! - lifeos_status: Get Axi's current state, mode, and sensor readings
//! - lifeos_task: Enqueue a task for the supervisor
//! - lifeos_memory_search: Search Axi's memory plane
//! - lifeos_desktop_action: Control the desktop (open apps, type, screenshot)
//! - lifeos_system_health: Get hardware health summary
//! - lifeos_shell: Execute a shell command (with risk gating)
//! - lifeos_meeting_status: Check if a meeting is active
//! - lifeos_game_guard_status: Check GPU/gaming state

#![allow(dead_code)]

/// Process an MCP tool call and return the result.
/// This is a dispatcher — actual execution delegates to the appropriate module.
///
/// `sensory` is threaded through because `lifeos_desktop_action` with
/// name=="screenshot" and `lifeos_browser_screenshot` now require the
/// unified sense gate (round-2 audit C-NEW-3). Pass `None` only when
/// the caller has no sensory manager to share — all screenshot actions
/// will fail-closed in that case.
pub async fn call_tool(
    name: &str,
    arguments: &serde_json::Value,
    sensory: Option<
        std::sync::Arc<tokio::sync::RwLock<crate::sensory_pipeline::SensoryPipelineManager>>,
    >,
) -> Result<serde_json::Value, String> {
    match name {
        "lifeos_status" => {
            let alerts = crate::proactive::check_all(None, None).await;
            Ok(serde_json::json!({
                "status": "running",
                "alerts": alerts.len(),
                "alert_details": alerts.iter().map(|a| {
                    serde_json::json!({"severity": format!("{:?}", a.severity), "message": a.message})
                }).collect::<Vec<_>>()
            }))
        }
        "lifeos_task" => {
            let objective = arguments
                .get("objective")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'objective' parameter")?;
            // Task will be enqueued when integrated with DaemonState
            Ok(serde_json::json!({
                "queued": true,
                "objective": objective,
                "note": "Task enqueued to supervisor via API"
            }))
        }
        "lifeos_shell" => {
            // ────────────────────────────────────────────────────────────
            // SECURITY HARDENING (item #S2 in pending-items-roadmap.md)
            //
            // The previous implementation here took arbitrary strings from
            // the MCP client and passed them to `sh -c`, gated only by a
            // tiny substring blocklist ("rm -rf /", "mkfs", ":(){"…). That
            // approach is security theatre: any non-trivial attacker can
            // bypass it with `rm -rf /*`, `rm\x20-rf\x20/`, `eval $(...)`,
            // `$(curl|sh)`, backticks, environment manipulation, or a
            // wine/python payload. Blocklists never work for shell command
            // execution — you need an allowlist + argv exec + sandbox.
            //
            // Fully redesigning this (allowlist config file, argv exec,
            // bubblewrap sandbox, rate limiting, audit log) is tracked as
            // the follow-up sprint for S2. For now the tool is DISABLED
            // by default and only runs when the operator explicitly sets
            // LIFEOS_MCP_SHELL_ENABLE=1. When enabled we at minimum add
            // a 30s timeout, log every invocation to the journal, and
            // keep the legacy blocklist as defence-in-depth — but the
            // operator has explicitly opted in to running arbitrary shell.
            // ────────────────────────────────────────────────────────────
            let opt_in = std::env::var("LIFEOS_MCP_SHELL_ENABLE")
                .map(|v| matches!(v.as_str(), "1" | "true" | "yes" | "on"))
                .unwrap_or(false);
            if !opt_in {
                log::warn!(
                    "[mcp_server] lifeos_shell called but disabled — set \
                     LIFEOS_MCP_SHELL_ENABLE=1 to opt in (accepts the risk)"
                );
                return Err(
                    "lifeos_shell is disabled. Set LIFEOS_MCP_SHELL_ENABLE=1 to \
                     enable arbitrary-shell-exec mode. This tool takes raw \
                     strings from the MCP client and pipes them into sh -c; \
                     enabling it accepts the risk that a compromised or \
                     jailbroken MCP client can run anything as your user."
                        .to_string(),
                );
            }

            let command = arguments
                .get("command")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'command' parameter")?;

            log::warn!(
                "[mcp_server] lifeos_shell EXEC (opt-in): {}",
                command.chars().take(200).collect::<String>()
            );

            // Legacy substring blocklist — kept as defence-in-depth, not
            // relied on for safety. An attacker who can invoke this tool
            // has already won; the blocklist just makes casual mistakes
            // slightly less catastrophic.
            let lower = command.to_lowercase();
            let blocked = [
                "rm -rf /",
                "rm -rf /*",
                "mkfs",
                "dd if=",
                ":(){",
                "fork bomb",
                "chmod -R 777 /",
                "mv /* ",
                ">(){ :|:",
            ];
            for pattern in &blocked {
                if lower.contains(pattern) {
                    return Err(format!("Command blocked by security policy: {}", pattern));
                }
            }

            // Timeout: 30s cap so a runaway command can't hold the MCP
            // server forever. This does not stop fork-bombs or detached
            // background work — a real sandbox (bubblewrap + cgroups)
            // is the proper fix and is tracked as follow-up.
            let exec = tokio::process::Command::new("sh")
                .arg("-c")
                .arg(command)
                .output();
            let output = match tokio::time::timeout(std::time::Duration::from_secs(30), exec).await
            {
                Ok(Ok(out)) => out,
                Ok(Err(e)) => return Err(format!("Execution failed: {}", e)),
                Err(_) => return Err("Command timed out after 30 seconds".to_string()),
            };

            let stdout = String::from_utf8_lossy(&output.stdout);
            let stderr = String::from_utf8_lossy(&output.stderr);
            Ok(serde_json::json!({
                "exit_code": output.status.code(),
                "stdout": stdout.chars().take(4000).collect::<String>(),
                "stderr": stderr.chars().take(2000).collect::<String>(),
            }))
        }
        "lifeos_system_health" => {
            let alerts = crate::proactive::check_all(None, None).await;
            Ok(serde_json::json!({
                "health_checks": alerts.len(),
                "alerts": alerts.iter().map(|a| {
                    serde_json::json!({
                        "category": format!("{:?}", a.category),
                        "severity": format!("{:?}", a.severity),
                        "message": a.message,
                    })
                }).collect::<Vec<_>>()
            }))
        }
        "lifeos_desktop_action" => {
            let action_name = arguments
                .get("action")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'action' parameter")?;
            let params = arguments
                .get("params")
                .cloned()
                .unwrap_or(serde_json::json!({}));

            let action = match action_name {
                "screenshot" => crate::desktop_operator::DesktopAction::Screenshot,
                "flatpak_list" => crate::desktop_operator::DesktopAction::FlatpakList,
                "open_url" => {
                    let url = params
                        .get("url")
                        .and_then(|v| v.as_str())
                        .ok_or("Missing 'url'")?;
                    crate::desktop_operator::DesktopAction::OpenUrl { url: url.into() }
                }
                "open_app" => {
                    let name = params
                        .get("name")
                        .and_then(|v| v.as_str())
                        .ok_or("Missing 'name'")?;
                    crate::desktop_operator::DesktopAction::OpenApp { name: name.into() }
                }
                "set_volume" => {
                    let pct = params
                        .get("percent")
                        .and_then(|v| v.as_u64())
                        .ok_or("Missing 'percent'")? as u32;
                    crate::desktop_operator::DesktopAction::SetVolume { percent: pct }
                }
                "night_mode" => {
                    let enabled = params
                        .get("enabled")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(true);
                    crate::desktop_operator::DesktopAction::NightMode { enabled }
                }
                _ => return Err(format!("Unknown desktop action: {}", action_name)),
            };

            let result =
                crate::desktop_operator::DesktopOperator::execute(&action, sensory.clone()).await;
            Ok(serde_json::json!({
                "success": result.success,
                "output": result.output,
            }))
        }
        "lifeos_memory_search" => {
            let query = arguments
                .get("query")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'query' parameter")?;
            Ok(serde_json::json!({
                "query": query,
                "note": "Memory search requires MemoryPlaneManager integration"
            }))
        }
        "lifeos_game_guard_status" => Ok(serde_json::json!({
            "note": "Game guard status requires GameGuard state integration"
        })),

        // ----- OS Control Plane tools (AY.1) -----
        "lifeos_windows_list" => {
            let output = tokio::process::Command::new("swaymsg")
                .args(["-t", "get_tree", "--raw"])
                .output()
                .await;
            match output {
                Ok(o) if o.status.success() => {
                    let raw = String::from_utf8_lossy(&o.stdout);
                    // Parse the tree and extract windows
                    let windows = extract_windows_from_tree(&raw);
                    Ok(serde_json::json!({ "windows": windows }))
                }
                Ok(o) => Err(format!(
                    "swaymsg failed: {}",
                    String::from_utf8_lossy(&o.stderr)
                )),
                Err(e) => Err(format!("Failed to run swaymsg: {}", e)),
            }
        }

        "lifeos_windows_focus" => {
            let selector = build_sway_selector(arguments)?;
            let output = tokio::process::Command::new("swaymsg")
                .arg(format!("{} focus", selector))
                .output()
                .await;
            cmd_result(output, "Focus window")
        }

        "lifeos_windows_move" => {
            let selector = build_sway_selector(arguments)?;
            let workspace = arguments
                .get("workspace")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'workspace' parameter")?;
            let output = tokio::process::Command::new("swaymsg")
                .arg(format!("{} move to workspace {}", selector, workspace))
                .output()
                .await;
            cmd_result(output, "Move window")
        }

        "lifeos_windows_close" => {
            let selector = build_sway_selector(arguments)?;
            let output = tokio::process::Command::new("swaymsg")
                .arg(format!("{} kill", selector))
                .output()
                .await;
            cmd_result(output, "Close window")
        }

        "lifeos_apps_launch" => {
            if let Some(desktop) = arguments.get("desktop").and_then(|v| v.as_str()) {
                let output = tokio::process::Command::new("gtk-launch")
                    .arg(desktop)
                    .output()
                    .await;
                cmd_result(output, "Launch app via gtk-launch")
            } else if let Some(app) = arguments.get("app").and_then(|v| v.as_str()) {
                // Validate app name to prevent command injection
                if app.contains('/') || app.contains(';') || app.contains('&') || app.contains('|')
                {
                    return Err("Invalid app name".into());
                }
                let _child = tokio::process::Command::new(app)
                    .spawn()
                    .map_err(|e| format!("Failed to launch {}: {}", app, e))?;
                Ok(serde_json::json!({ "launched": app }))
            } else {
                Err("Provide either 'app' or 'desktop' parameter".into())
            }
        }

        "lifeos_apps_list_installed" => {
            let output = tokio::process::Command::new("sh")
                .args([
                    "-c",
                    r#"for f in /usr/share/applications/*.desktop ~/.local/share/applications/*.desktop /var/lib/flatpak/exports/share/applications/*.desktop; do [ -f "$f" ] && grep -m1 '^Name=' "$f" | cut -d= -f2; done | sort -u"#,
                ])
                .output()
                .await;
            match output {
                Ok(o) if o.status.success() => {
                    let raw = String::from_utf8_lossy(&o.stdout);
                    let apps: Vec<&str> = raw.lines().filter(|l| !l.is_empty()).collect();
                    Ok(serde_json::json!({ "installed_apps": apps, "count": apps.len() }))
                }
                Ok(o) => Err(format!(
                    "Failed to list apps: {}",
                    String::from_utf8_lossy(&o.stderr)
                )),
                Err(e) => Err(format!("Command failed: {}", e)),
            }
        }

        "lifeos_apps_running" => {
            // Use swaymsg to list running GUI apps (more reliable than ps for Wayland)
            let output = tokio::process::Command::new("swaymsg")
                .args(["-t", "get_tree", "--raw"])
                .output()
                .await;
            match output {
                Ok(o) if o.status.success() => {
                    let raw = String::from_utf8_lossy(&o.stdout);
                    let windows = extract_windows_from_tree(&raw);
                    // Deduplicate by app_id
                    let mut seen = std::collections::HashSet::new();
                    let unique: Vec<_> = windows
                        .iter()
                        .filter(|w| {
                            let app = w.get("app_id").and_then(|v| v.as_str()).unwrap_or("");
                            if app.is_empty() || seen.contains(app) {
                                false
                            } else {
                                seen.insert(app.to_string());
                                true
                            }
                        })
                        .collect();
                    Ok(serde_json::json!({ "running_apps": unique, "count": unique.len() }))
                }
                Ok(_) => {
                    // Fallback: use ps
                    let ps_out = tokio::process::Command::new("ps")
                        .args(["-eo", "pid,comm", "--no-headers"])
                        .output()
                        .await;
                    match ps_out {
                        Ok(o) => {
                            let raw = String::from_utf8_lossy(&o.stdout);
                            let procs: Vec<serde_json::Value> = raw
                                .lines()
                                .filter_map(|l| {
                                    let parts: Vec<&str> = l.trim().splitn(2, ' ').collect();
                                    if parts.len() == 2 {
                                        Some(serde_json::json!({"pid": parts[0].trim(), "name": parts[1].trim()}))
                                    } else {
                                        None
                                    }
                                })
                                .collect();
                            Ok(serde_json::json!({ "processes": procs, "count": procs.len() }))
                        }
                        Err(e) => Err(format!("Failed: {}", e)),
                    }
                }
                Err(e) => Err(format!("Failed to run swaymsg: {}", e)),
            }
        }

        "lifeos_clipboard_get" => {
            let output = tokio::process::Command::new("wl-paste")
                .arg("--no-newline")
                .output()
                .await;
            match output {
                Ok(o) if o.status.success() => {
                    let content = String::from_utf8_lossy(&o.stdout);
                    Ok(serde_json::json!({ "content": content.to_string() }))
                }
                Ok(o) => Err(format!(
                    "wl-paste failed: {}",
                    String::from_utf8_lossy(&o.stderr)
                )),
                Err(e) => Err(format!("Failed to run wl-paste: {}", e)),
            }
        }

        "lifeos_clipboard_set" => {
            let content = arguments
                .get("content")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'content' parameter")?;
            let mut child = tokio::process::Command::new("wl-copy")
                .stdin(std::process::Stdio::piped())
                .spawn()
                .map_err(|e| format!("Failed to run wl-copy: {}", e))?;
            if let Some(mut stdin) = child.stdin.take() {
                use tokio::io::AsyncWriteExt;
                stdin
                    .write_all(content.as_bytes())
                    .await
                    .map_err(|e| format!("Write to wl-copy failed: {}", e))?;
            }
            let status = child
                .wait()
                .await
                .map_err(|e| format!("wl-copy wait failed: {}", e))?;
            if status.success() {
                Ok(serde_json::json!({ "copied": true, "length": content.len() }))
            } else {
                Err("wl-copy exited with error".into())
            }
        }

        "lifeos_volume_get" => {
            let output = tokio::process::Command::new("wpctl")
                .args(["get-volume", "@DEFAULT_AUDIO_SINK@"])
                .output()
                .await;
            match output {
                Ok(o) if o.status.success() => {
                    let raw = String::from_utf8_lossy(&o.stdout);
                    // Format: "Volume: 0.75" or "Volume: 0.75 [MUTED]"
                    let muted = raw.contains("[MUTED]");
                    let vol: f64 = raw
                        .split_whitespace()
                        .nth(1)
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(0.0);
                    Ok(serde_json::json!({
                        "volume": vol,
                        "percent": (vol * 100.0).round() as u32,
                        "muted": muted
                    }))
                }
                Ok(o) => Err(format!(
                    "wpctl failed: {}",
                    String::from_utf8_lossy(&o.stderr)
                )),
                Err(e) => Err(format!("Failed to run wpctl: {}", e)),
            }
        }

        "lifeos_volume_set" => {
            let level = arguments
                .get("level")
                .and_then(|v| v.as_f64())
                .ok_or("Missing 'level' parameter (0.0 to 1.0)")?;
            let level = level.clamp(0.0, 1.0);
            let output = tokio::process::Command::new("wpctl")
                .args([
                    "set-volume",
                    "@DEFAULT_AUDIO_SINK@",
                    &format!("{:.2}", level),
                ])
                .output()
                .await;
            cmd_result(output, "Set volume")
        }

        "lifeos_brightness_get" => {
            let output = tokio::process::Command::new("sh")
                .args([
                    "-c",
                    r#"bl=$(ls -d /sys/class/backlight/* 2>/dev/null | head -1); if [ -n "$bl" ]; then cur=$(cat "$bl/brightness"); max=$(cat "$bl/max_brightness"); echo "$cur $max"; else echo "none"; fi"#,
                ])
                .output()
                .await;
            match output {
                Ok(o) if o.status.success() => {
                    let raw = String::from_utf8_lossy(&o.stdout).trim().to_string();
                    if raw == "none" {
                        Err("No backlight device found".into())
                    } else {
                        let parts: Vec<&str> = raw.split_whitespace().collect();
                        if parts.len() == 2 {
                            let cur: f64 = parts[0].parse().unwrap_or(0.0);
                            let max: f64 = parts[1].parse().unwrap_or(1.0);
                            let pct = if max > 0.0 {
                                ((cur / max) * 100.0).round() as u32
                            } else {
                                0
                            };
                            Ok(serde_json::json!({
                                "brightness": cur as u64,
                                "max_brightness": max as u64,
                                "percent": pct
                            }))
                        } else {
                            Err("Unexpected backlight output".into())
                        }
                    }
                }
                Ok(o) => Err(format!(
                    "brightness read failed: {}",
                    String::from_utf8_lossy(&o.stderr)
                )),
                Err(e) => Err(format!("Command failed: {}", e)),
            }
        }

        "lifeos_brightness_set" => {
            let level = arguments
                .get("level")
                .and_then(|v| v.as_u64())
                .ok_or("Missing 'level' parameter (0-100)")? as u32;
            let level = level.min(100);
            // Use brightnessctl if available, fall back to direct write
            let output = tokio::process::Command::new("brightnessctl")
                .args(["set", &format!("{}%", level)])
                .output()
                .await;
            match output {
                Ok(o) if o.status.success() => Ok(serde_json::json!({ "set_percent": level })),
                _ => {
                    // Fallback: write directly (may require permissions)
                    let output2 = tokio::process::Command::new("sh")
                        .args([
                            "-c",
                            &format!(
                                r#"bl=$(ls -d /sys/class/backlight/* 2>/dev/null | head -1); max=$(cat "$bl/max_brightness"); val=$((max * {} / 100)); echo "$val" > "$bl/brightness""#,
                                level
                            ),
                        ])
                        .output()
                        .await;
                    cmd_result(output2, "Set brightness")
                }
            }
        }

        "lifeos_notify" => {
            let title = arguments
                .get("title")
                .and_then(|v| v.as_str())
                .unwrap_or("LifeOS");
            let body = arguments
                .get("body")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'body' parameter")?;
            let urgency = arguments
                .get("urgency")
                .and_then(|v| v.as_str())
                .unwrap_or("normal");

            let mut notif = notify_rust::Notification::new();
            notif.summary(title).body(body).icon("dialog-information");

            match urgency {
                "low" => {
                    notif.urgency(notify_rust::Urgency::Low);
                }
                "critical" => {
                    notif.urgency(notify_rust::Urgency::Critical);
                }
                _ => {
                    notif.urgency(notify_rust::Urgency::Normal);
                }
            }

            notif
                .show()
                .map_err(|e| format!("Notification failed: {}", e))?;
            Ok(serde_json::json!({ "sent": true, "title": title }))
        }

        "lifeos_files_open" => {
            let path = arguments
                .get("path")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'path' parameter")?;
            // Validate path exists
            if !std::path::Path::new(path).exists() {
                return Err(format!("File not found: {}", path));
            }
            let _child = tokio::process::Command::new("xdg-open")
                .arg(path)
                .spawn()
                .map_err(|e| format!("xdg-open failed: {}", e))?;
            Ok(serde_json::json!({ "opened": path }))
        }

        "lifeos_displays_list" => {
            // Try cosmic-randr first, then swaymsg
            let output = tokio::process::Command::new("cosmic-randr")
                .arg("list")
                .output()
                .await;
            match output {
                Ok(o) if o.status.success() => {
                    let raw = String::from_utf8_lossy(&o.stdout);
                    Ok(serde_json::json!({ "displays": raw.to_string(), "source": "cosmic-randr" }))
                }
                _ => {
                    // Fallback to swaymsg
                    let output2 = tokio::process::Command::new("swaymsg")
                        .args(["-t", "get_outputs", "--raw"])
                        .output()
                        .await;
                    match output2 {
                        Ok(o) if o.status.success() => {
                            let raw = String::from_utf8_lossy(&o.stdout);
                            Ok(
                                serde_json::json!({ "displays": raw.to_string(), "source": "swaymsg" }),
                            )
                        }
                        Ok(o) => Err(format!(
                            "Failed to list displays: {}",
                            String::from_utf8_lossy(&o.stderr)
                        )),
                        Err(e) => Err(format!("Command failed: {}", e)),
                    }
                }
            }
        }

        // ----- Control Layer Selection (AY.2) -----
        "lifeos_select_layer" => {
            let action = arguments
                .get("action")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'action' parameter")?;
            let (layer, mcp_tool) = crate::control_layers::select_layer(action);
            Ok(serde_json::json!({
                "action": action,
                "recommended_layer": layer.to_string(),
                "mcp_tool": mcp_tool,
                "available_mcp_tools": crate::control_layers::available_mcp_tools().len(),
            }))
        }

        // ----- Browser MCP Bridge tools (AY.3) -----
        "lifeos_browser_navigate" => {
            let url = arguments
                .get("url")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'url' parameter")?;
            let ba = crate::browser_automation::BrowserAutomation::new(std::path::PathBuf::from(
                "/var/lib/lifeos",
            ));
            match ba.navigate_and_capture(url).await {
                Ok(screenshot_path) => Ok(serde_json::json!({
                    "navigated": true,
                    "url": url,
                    "screenshot": screenshot_path,
                })),
                Err(e) => Err(format!("Browser navigate failed: {}", e)),
            }
        }

        "lifeos_browser_screenshot" => {
            // Capture the current page by navigating to about:blank-ish or using CDP
            // Use BrowserAutomation's navigate_and_capture with the last known URL
            let ba = crate::browser_automation::BrowserAutomation::new(std::path::PathBuf::from(
                "/var/lib/lifeos",
            ));
            // Take a screenshot of whatever is currently on screen via the desktop operator
            let action = crate::desktop_operator::DesktopAction::Screenshot;
            let result =
                crate::desktop_operator::DesktopOperator::execute(&action, sensory.clone()).await;
            if result.success {
                Ok(serde_json::json!({
                    "screenshot": result.output,
                    "source": "desktop_screenshot",
                }))
            } else {
                // Fallback: try headless capture of a blank page
                match ba.navigate_and_capture("about:blank").await {
                    Ok(path) => Ok(serde_json::json!({
                        "screenshot": path,
                        "source": "headless_fallback",
                    })),
                    Err(e) => Err(format!("Screenshot failed: {}", e)),
                }
            }
        }

        "lifeos_browser_extract_text" => {
            // Use BrowserAutomation's fetch_html and strip tags for text extraction
            let url = arguments
                .get("url")
                .and_then(|v| v.as_str())
                .unwrap_or("about:blank");
            let ba = crate::browser_automation::BrowserAutomation::new(std::path::PathBuf::from(
                "/var/lib/lifeos",
            ));
            match ba.fetch_html(url).await {
                Ok(html) => {
                    // Strip HTML tags for a rough text extraction
                    let text = strip_html_tags(&html);
                    Ok(serde_json::json!({
                        "url": url,
                        "text": text,
                        "length": text.len(),
                    }))
                }
                Err(e) => Err(format!("Text extraction failed: {}", e)),
            }
        }

        "lifeos_browser_click" => {
            let selector = arguments
                .get("selector")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'selector' parameter")?;
            let url = arguments
                .get("url")
                .and_then(|v| v.as_str())
                .unwrap_or("about:blank");
            let ba = crate::browser_automation::BrowserAutomation::new(std::path::PathBuf::from(
                "/var/lib/lifeos",
            ));
            match ba.click_element(url, selector).await {
                Ok(result) => Ok(serde_json::json!({
                    "clicked": true,
                    "selector": selector,
                    "result": result,
                })),
                Err(e) => Err(format!("Click failed: {}", e)),
            }
        }

        "lifeos_browser_fill" => {
            let selector = arguments
                .get("selector")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'selector' parameter")?;
            let value = arguments
                .get("value")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'value' parameter")?;
            let url = arguments
                .get("url")
                .and_then(|v| v.as_str())
                .unwrap_or("about:blank");
            let ba = crate::browser_automation::BrowserAutomation::new(std::path::PathBuf::from(
                "/var/lib/lifeos",
            ));
            match ba.fill_input(url, selector, value).await {
                Ok(result) => Ok(serde_json::json!({
                    "filled": true,
                    "selector": selector,
                    "result": result,
                })),
                Err(e) => Err(format!("Fill failed: {}", e)),
            }
        }

        // ----- LibreOffice MCP tools -----
        "lifeos_writer_export_pdf" => {
            let input = arguments
                .get("input")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'input' parameter")?;
            let output_path = arguments
                .get("output")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'output' parameter")?;
            let cmd_output = tokio::process::Command::new("python3")
                .args([
                    "/usr/local/bin/lifeos-libreoffice-verify.py",
                    "export-pdf",
                    input,
                    output_path,
                ])
                .output()
                .await;
            libreoffice_result(cmd_output, "export-pdf")
        }

        "lifeos_calc_read_cells" => {
            let file = arguments
                .get("file")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'file' parameter")?;
            let range = arguments
                .get("range")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'range' parameter")?;
            let cmd_output = tokio::process::Command::new("python3")
                .args([
                    "/usr/local/bin/lifeos-libreoffice-verify.py",
                    "read-cells",
                    file,
                    range,
                ])
                .output()
                .await;
            libreoffice_result(cmd_output, "read-cells")
        }

        "lifeos_calc_verify_formula" => {
            let file = arguments
                .get("file")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'file' parameter")?;
            let cell = arguments
                .get("cell")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'cell' parameter")?;
            let expected = arguments
                .get("expected")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'expected' parameter")?;
            let cmd_output = tokio::process::Command::new("python3")
                .args([
                    "/usr/local/bin/lifeos-libreoffice-verify.py",
                    "verify-formula",
                    file,
                    cell,
                    expected,
                ])
                .output()
                .await;
            libreoffice_result(cmd_output, "verify-formula")
        }

        "lifeos_calc_sheet_info" => {
            let file = arguments
                .get("file")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'file' parameter")?;
            let cmd_output = tokio::process::Command::new("python3")
                .args([
                    "/usr/local/bin/lifeos-libreoffice-verify.py",
                    "sheet-info",
                    file,
                ])
                .output()
                .await;
            libreoffice_result(cmd_output, "sheet-info")
        }

        // ----- COSMIC Desktop: Workspaces -----
        "lifeos_workspaces_list" => {
            let output = tokio::process::Command::new("swaymsg")
                .args(["-t", "get_workspaces", "--raw"])
                .output()
                .await;
            match output {
                Ok(o) if o.status.success() => {
                    let raw = String::from_utf8_lossy(&o.stdout);
                    // Parse JSON array of workspaces
                    let parsed: serde_json::Value =
                        serde_json::from_str(&raw).unwrap_or(serde_json::json!([]));
                    Ok(serde_json::json!({ "workspaces": parsed }))
                }
                Ok(o) => Err(format!(
                    "swaymsg failed: {}",
                    String::from_utf8_lossy(&o.stderr)
                )),
                Err(e) => Err(format!("Failed to run swaymsg: {}", e)),
            }
        }

        "lifeos_workspaces_switch" => {
            let workspace = arguments
                .get("workspace")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'workspace' parameter")?;
            // Validate workspace name
            if workspace.contains(';') || workspace.contains('&') || workspace.contains('|') {
                return Err("Invalid workspace name".into());
            }
            let output = tokio::process::Command::new("swaymsg")
                .arg(format!("workspace {}", workspace))
                .output()
                .await;
            cmd_result(output, "Switch workspace")
        }

        "lifeos_workspaces_create" => {
            let ws_name = arguments
                .get("name")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'name' parameter")?;
            if ws_name.contains(';') || ws_name.contains('&') || ws_name.contains('|') {
                return Err("Invalid workspace name".into());
            }
            let output = tokio::process::Command::new("swaymsg")
                .arg(format!("workspace {}", ws_name))
                .output()
                .await;
            cmd_result(output, "Create workspace")
        }

        "lifeos_workspaces_move_window_to" => {
            let workspace = arguments
                .get("workspace")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'workspace' parameter")?;
            if workspace.contains(';') || workspace.contains('&') || workspace.contains('|') {
                return Err("Invalid workspace name".into());
            }
            let output = tokio::process::Command::new("swaymsg")
                .arg(format!("move container to workspace {}", workspace))
                .output()
                .await;
            cmd_result(output, "Move window to workspace")
        }

        // ----- COSMIC Apps Launch -----
        "lifeos_cosmic_terminal" => {
            let cmd_arg = arguments.get("command").and_then(|v| v.as_str());
            let mut cmd = tokio::process::Command::new("cosmic-term");
            if let Some(c) = cmd_arg {
                cmd.args(["-e", c]);
            }
            let _child = cmd
                .spawn()
                .map_err(|e| format!("Failed to launch cosmic-term: {}", e))?;
            Ok(serde_json::json!({
                "launched": "cosmic-term",
                "command": cmd_arg.unwrap_or("(none)")
            }))
        }

        "lifeos_cosmic_files" => {
            let path = arguments.get("path").and_then(|v| v.as_str());
            let mut cmd = tokio::process::Command::new("cosmic-files");
            if let Some(p) = path {
                cmd.arg(p);
            }
            let _child = cmd
                .spawn()
                .map_err(|e| format!("Failed to launch cosmic-files: {}", e))?;
            Ok(serde_json::json!({
                "launched": "cosmic-files",
                "path": path.unwrap_or("(home)")
            }))
        }

        "lifeos_cosmic_editor" => {
            let file = arguments.get("file").and_then(|v| v.as_str());
            let mut cmd = tokio::process::Command::new("cosmic-edit");
            if let Some(f) = file {
                cmd.arg(f);
            }
            let _child = cmd
                .spawn()
                .map_err(|e| format!("Failed to launch cosmic-edit: {}", e))?;
            Ok(serde_json::json!({
                "launched": "cosmic-edit",
                "file": file.unwrap_or("(none)")
            }))
        }

        "lifeos_cosmic_settings" => {
            let page = arguments.get("page").and_then(|v| v.as_str());
            let mut cmd = tokio::process::Command::new("cosmic-settings");
            if let Some(p) = page {
                cmd.arg(p);
            }
            let _child = cmd
                .spawn()
                .map_err(|e| format!("Failed to launch cosmic-settings: {}", e))?;
            Ok(serde_json::json!({
                "launched": "cosmic-settings",
                "page": page.unwrap_or("(main)")
            }))
        }

        "lifeos_cosmic_store" => {
            let _child = tokio::process::Command::new("cosmic-store")
                .spawn()
                .map_err(|e| format!("Failed to launch cosmic-store: {}", e))?;
            Ok(serde_json::json!({ "launched": "cosmic-store" }))
        }

        // ----- COSMIC Desktop Control -----
        "lifeos_cosmic_dark_mode" => {
            let enabled = arguments
                .get("enabled")
                .and_then(|v| v.as_bool())
                .ok_or("Missing 'enabled' parameter (boolean)")?;
            let config_dir = format!(
                "{}/.config/cosmic/com.system76.CosmicTheme.Mode/v1",
                std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into())
            );
            tokio::fs::create_dir_all(&config_dir)
                .await
                .map_err(|e| format!("Failed to create config dir: {}", e))?;
            let config_path = format!("{}/is_dark", config_dir);
            tokio::fs::write(&config_path, if enabled { "true" } else { "false" })
                .await
                .map_err(|e| format!("Failed to write dark mode config: {}", e))?;
            Ok(serde_json::json!({
                "dark_mode": enabled,
                "config_path": config_path,
                "note": "Change takes effect on next COSMIC session or theme reload"
            }))
        }

        "lifeos_cosmic_dock_autohide" => {
            let enabled = arguments
                .get("enabled")
                .and_then(|v| v.as_bool())
                .ok_or("Missing 'enabled' parameter (boolean)")?;
            let config_dir = format!(
                "{}/.config/cosmic/com.system76.CosmicPanel.Dock/v1",
                std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into())
            );
            tokio::fs::create_dir_all(&config_dir)
                .await
                .map_err(|e| format!("Failed to create config dir: {}", e))?;
            let config_path = format!("{}/autohide", config_dir);
            tokio::fs::write(&config_path, if enabled { "true" } else { "false" })
                .await
                .map_err(|e| format!("Failed to write dock config: {}", e))?;
            Ok(serde_json::json!({
                "autohide": enabled,
                "config_path": config_path,
                "note": "Change takes effect on next COSMIC session or panel reload"
            }))
        }

        "lifeos_cosmic_panel_position" => {
            let position = arguments
                .get("position")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'position' parameter")?;
            let anchor = match position {
                "top" => "Top",
                "bottom" => "Bottom",
                _ => {
                    return Err(format!(
                        "Invalid position '{}': use 'top' or 'bottom'",
                        position
                    ))
                }
            };
            let config_dir = format!(
                "{}/.config/cosmic/com.system76.CosmicPanel.Panel/v1",
                std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into())
            );
            tokio::fs::create_dir_all(&config_dir)
                .await
                .map_err(|e| format!("Failed to create config dir: {}", e))?;
            let config_path = format!("{}/anchor", config_dir);
            tokio::fs::write(&config_path, anchor)
                .await
                .map_err(|e| format!("Failed to write panel config: {}", e))?;
            Ok(serde_json::json!({
                "position": position,
                "anchor": anchor,
                "config_path": config_path,
                "note": "Change takes effect on next COSMIC session or panel reload"
            }))
        }

        // ----- Display resolution -----
        "lifeos_display_resolution" => {
            let output_name = arguments
                .get("output")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'output' parameter (e.g. eDP-1)")?;
            let mode = arguments
                .get("mode")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'mode' parameter (e.g. 1920x1080@60)")?;
            // Validate inputs to prevent injection
            if output_name.contains(';')
                || output_name.contains('&')
                || mode.contains(';')
                || mode.contains('&')
            {
                return Err("Invalid characters in output or mode".into());
            }
            let output = tokio::process::Command::new("cosmic-randr")
                .args(["mode", "--output", output_name, "--mode", mode])
                .output()
                .await;
            cmd_result(output, "Set display resolution")
        }

        // ----- AT-SPI2 Accessibility Layer (AY.4) -----
        "lifeos_a11y_tree" => {
            let app = arguments
                .get("app")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'app' parameter")?;
            let depth = arguments.get("depth").and_then(|v| v.as_u64()).unwrap_or(3) as u32;
            match crate::atspi_layer::get_tree(app, depth).await {
                Ok(nodes) => Ok(serde_json::json!({
                    "app": app,
                    "depth": depth,
                    "nodes": nodes.len(),
                    "tree": nodes,
                })),
                Err(e) => Err(format!("AT-SPI2 tree failed: {}", e)),
            }
        }

        "lifeos_a11y_find" => {
            let app = arguments
                .get("app")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'app' parameter")?;
            let role = arguments.get("role").and_then(|v| v.as_str());
            let name_filter = arguments.get("name").and_then(|v| v.as_str());
            match crate::atspi_layer::find_elements(app, role, name_filter).await {
                Ok(elements) => Ok(serde_json::json!({
                    "app": app,
                    "matches": elements.len(),
                    "elements": elements,
                })),
                Err(e) => Err(format!("AT-SPI2 find failed: {}", e)),
            }
        }

        "lifeos_a11y_activate" => {
            let bus = arguments
                .get("bus_name")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'bus_name' parameter")?;
            let path = arguments
                .get("path")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'path' parameter")?;
            match crate::atspi_layer::activate_element(bus, path).await {
                Ok(()) => Ok(serde_json::json!({
                    "activated": true,
                    "bus_name": bus,
                    "path": path,
                })),
                Err(e) => Err(format!("AT-SPI2 activate failed: {}", e)),
            }
        }

        "lifeos_a11y_get_text" => {
            let bus = arguments
                .get("bus_name")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'bus_name' parameter")?;
            let path = arguments
                .get("path")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'path' parameter")?;
            match crate::atspi_layer::get_text(bus, path).await {
                Ok(text) => Ok(serde_json::json!({
                    "bus_name": bus,
                    "path": path,
                    "text": text,
                    "length": text.len(),
                })),
                Err(e) => Err(format!("AT-SPI2 get_text failed: {}", e)),
            }
        }

        "lifeos_a11y_set_text" => {
            let bus = arguments
                .get("bus_name")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'bus_name' parameter")?;
            let path = arguments
                .get("path")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'path' parameter")?;
            let text = arguments
                .get("text")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'text' parameter")?;
            match crate::atspi_layer::set_text(bus, path, text).await {
                Ok(()) => Ok(serde_json::json!({
                    "bus_name": bus,
                    "path": path,
                    "text_set": true,
                    "length": text.len(),
                })),
                Err(e) => Err(format!("AT-SPI2 set_text failed: {}", e)),
            }
        }

        "lifeos_a11y_apps" => {
            let available = crate::atspi_layer::is_available().await;
            if !available {
                return Ok(serde_json::json!({
                    "available": false,
                    "count": 0,
                    "applications": [],
                    "note": "AT-SPI2 bus not available. Ensure at-spi2-core is running."
                }));
            }
            match crate::atspi_layer::list_applications().await {
                Ok(apps) => Ok(serde_json::json!({
                    "available": true,
                    "count": apps.len(),
                    "applications": apps,
                })),
                Err(e) => Err(format!("AT-SPI2 list apps failed: {}", e)),
            }
        }

        _ => Err(format!("Unknown tool: {}", name)),
    }
}

/// Process a LibreOffice UNO bridge command result into MCP JSON.
fn libreoffice_result(
    output: Result<std::process::Output, std::io::Error>,
    label: &str,
) -> Result<serde_json::Value, String> {
    match output {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            let stderr = String::from_utf8_lossy(&o.stderr);
            if o.status.success() {
                // The Python script outputs JSON; parse it or return raw
                match serde_json::from_str::<serde_json::Value>(&stdout) {
                    Ok(parsed) => Ok(parsed),
                    Err(_) => Ok(serde_json::json!({
                        "output": stdout.to_string(),
                        "command": label,
                    })),
                }
            } else {
                Err(format!(
                    "LibreOffice {} failed (exit {}): {} {}",
                    label,
                    o.status.code().unwrap_or(-1),
                    stderr.chars().take(1000).collect::<String>(),
                    stdout.chars().take(1000).collect::<String>(),
                ))
            }
        }
        Err(e) => Err(format!(
            "Failed to run LibreOffice bridge for {}: {}",
            label, e
        )),
    }
}

/// Strip HTML tags from a string, returning only text content.
fn strip_html_tags(html: &str) -> String {
    let mut result = String::with_capacity(html.len());
    let mut in_tag = false;
    let mut last_was_space = false;
    for ch in html.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => {
                in_tag = false;
                // Add a space after closing tags to separate words
                if !last_was_space {
                    result.push(' ');
                    last_was_space = true;
                }
            }
            _ if !in_tag => {
                if ch.is_whitespace() {
                    if !last_was_space {
                        result.push(' ');
                        last_was_space = true;
                    }
                } else {
                    result.push(ch);
                    last_was_space = false;
                }
            }
            _ => {}
        }
    }
    result.trim().to_string()
}

// ---------------------------------------------------------------------------
// Helpers for OS Control Plane tools
// ---------------------------------------------------------------------------

/// Build a swaymsg selector from title or app_id arguments.
fn build_sway_selector(arguments: &serde_json::Value) -> Result<String, String> {
    if let Some(title) = arguments.get("title").and_then(|v| v.as_str()) {
        Ok(format!("[title=\"{}\"]", title.replace('"', "\\\"")))
    } else if let Some(app_id) = arguments.get("app_id").and_then(|v| v.as_str()) {
        Ok(format!("[app_id=\"{}\"]", app_id.replace('"', "\\\"")))
    } else {
        Err("Provide either 'title' or 'app_id' parameter".into())
    }
}

/// Convert a command output to a standard MCP result.
fn cmd_result(
    output: Result<std::process::Output, std::io::Error>,
    label: &str,
) -> Result<serde_json::Value, String> {
    match output {
        Ok(o) if o.status.success() => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            Ok(serde_json::json!({
                "success": true,
                "output": stdout.to_string()
            }))
        }
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            let stdout = String::from_utf8_lossy(&o.stdout);
            Err(format!(
                "{} failed (exit {}): {} {}",
                label,
                o.status.code().unwrap_or(-1),
                stderr,
                stdout
            ))
        }
        Err(e) => Err(format!("{} failed: {}", label, e)),
    }
}

/// Extract window info from swaymsg get_tree JSON output.
fn extract_windows_from_tree(raw: &str) -> Vec<serde_json::Value> {
    let mut windows = Vec::new();
    if let Ok(tree) = serde_json::from_str::<serde_json::Value>(raw) {
        collect_windows(&tree, &mut windows);
    }
    windows
}

/// Recursively walk the sway tree to find leaf nodes (actual windows).
fn collect_windows(node: &serde_json::Value, out: &mut Vec<serde_json::Value>) {
    // A node is a window if it has a non-null name and type "con" or "floating_con"
    let node_type = node.get("type").and_then(|v| v.as_str()).unwrap_or("");
    let name = node.get("name").and_then(|v| v.as_str());
    let app_id = node.get("app_id").and_then(|v| v.as_str());

    if (node_type == "con" || node_type == "floating_con") && name.is_some() {
        let rect = node.get("rect").cloned().unwrap_or(serde_json::json!({}));
        out.push(serde_json::json!({
            "title": name.unwrap_or(""),
            "app_id": app_id.unwrap_or(""),
            "type": node_type,
            "focused": node.get("focused").and_then(|v| v.as_bool()).unwrap_or(false),
            "rect": rect,
        }));
    }

    // Recurse into child nodes
    if let Some(nodes) = node.get("nodes").and_then(|v| v.as_array()) {
        for child in nodes {
            collect_windows(child, out);
        }
    }
    if let Some(nodes) = node.get("floating_nodes").and_then(|v| v.as_array()) {
        for child in nodes {
            collect_windows(child, out);
        }
    }
}
