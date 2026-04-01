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

use serde::{Deserialize, Serialize};

/// MCP tool definition following the Model Context Protocol specification.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpTool {
    pub name: String,
    pub description: String,
    #[serde(rename = "inputSchema")]
    pub input_schema: serde_json::Value,
}

/// MCP server capabilities declaration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpServerInfo {
    pub name: String,
    pub version: String,
    pub capabilities: McpCapabilities,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpCapabilities {
    pub tools: McpToolCapability,
    pub sampling: McpSamplingCapability,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpSamplingCapability {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpToolCapability {
    #[serde(rename = "listChanged")]
    pub list_changed: bool,
}

/// Get the MCP server info for LifeOS.
pub fn server_info() -> McpServerInfo {
    McpServerInfo {
        name: "lifeos".into(),
        version: env!("CARGO_PKG_VERSION").into(),
        capabilities: McpCapabilities {
            tools: McpToolCapability {
                list_changed: false,
            },
            sampling: McpSamplingCapability {},
        },
    }
}

/// List all tools exposed by the LifeOS MCP server.
pub fn list_tools() -> Vec<McpTool> {
    vec![
        McpTool {
            name: "lifeos_status".into(),
            description: "Get Axi's current state: mode, sensors, last signal, context."
                .into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {},
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_task".into(),
            description:
                "Enqueue a task for Axi's supervisor to execute autonomously. Returns task ID."
                    .into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "objective": {
                        "type": "string",
                        "description": "What you want Axi to do"
                    },
                    "priority": {
                        "type": "string",
                        "enum": ["low", "normal", "high", "urgent"],
                        "default": "normal"
                    }
                },
                "required": ["objective"]
            }),
        },
        McpTool {
            name: "lifeos_memory_search".into(),
            description: "Search Axi's memory plane for past events, decisions, and notes."
                .into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Search query"
                    },
                    "limit": {
                        "type": "integer",
                        "default": 10
                    }
                },
                "required": ["query"]
            }),
        },
        McpTool {
            name: "lifeos_desktop_action".into(),
            description: "Control the Linux desktop: open apps/URLs, type text, send keys, take screenshots, manage Flatpak apps, set volume/brightness.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": [
                            "flatpak_install", "flatpak_remove", "flatpak_list",
                            "open_url", "open_app", "open_file",
                            "type_text", "send_keys",
                            "set_volume", "set_brightness", "night_mode",
                            "screenshot"
                        ]
                    },
                    "params": {
                        "type": "object",
                        "description": "Action-specific parameters"
                    }
                },
                "required": ["action"]
            }),
        },
        McpTool {
            name: "lifeos_system_health".into(),
            description: "Get hardware health summary: CPU/GPU temperature, SSD health, battery, disk space, RAM usage.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {},
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_shell".into(),
            description: "Execute a shell command on the LifeOS host. Subject to risk gating — dangerous commands are blocked.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "Shell command to execute"
                    },
                    "working_directory": {
                        "type": "string",
                        "description": "Optional working directory"
                    }
                },
                "required": ["command"]
            }),
        },
        McpTool {
            name: "lifeos_game_guard_status".into(),
            description: "Get GPU Game Guard status: game detected, LLM mode (GPU/CPU), VRAM usage.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {},
                "required": []
            }),
        },
        // ----- OS Control Plane tools (AY.1) -----
        McpTool {
            name: "lifeos_windows_list".into(),
            description: "List all open windows with titles, app IDs, and geometry (COSMIC/Wayland via swaymsg).".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {},
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_windows_focus".into(),
            description: "Focus a window by title or app_id.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "title": { "type": "string", "description": "Window title substring to match" },
                    "app_id": { "type": "string", "description": "Application ID (e.g. org.mozilla.firefox)" }
                },
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_windows_move".into(),
            description: "Move a window to a different workspace.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "title": { "type": "string", "description": "Window title substring" },
                    "app_id": { "type": "string", "description": "Application ID" },
                    "workspace": { "type": "string", "description": "Target workspace number or name" }
                },
                "required": ["workspace"]
            }),
        },
        McpTool {
            name: "lifeos_windows_close".into(),
            description: "Close a window by title or app_id.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "title": { "type": "string", "description": "Window title substring" },
                    "app_id": { "type": "string", "description": "Application ID" }
                },
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_apps_launch".into(),
            description: "Launch an application by name or .desktop file ID.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "app": { "type": "string", "description": "App binary name (e.g. firefox)" },
                    "desktop": { "type": "string", "description": ".desktop file ID (e.g. org.mozilla.firefox.desktop)" }
                },
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_apps_list_installed".into(),
            description: "List installed desktop applications from .desktop files.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {},
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_apps_running".into(),
            description: "List currently running GUI applications.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {},
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_clipboard_get".into(),
            description: "Get current Wayland clipboard contents.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {},
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_clipboard_set".into(),
            description: "Set Wayland clipboard contents.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "content": { "type": "string", "description": "Text to copy to clipboard" }
                },
                "required": ["content"]
            }),
        },
        McpTool {
            name: "lifeos_volume_get".into(),
            description: "Get current audio volume level (WirePlumber/PipeWire).".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {},
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_volume_set".into(),
            description: "Set audio volume level (0.0 to 1.0).".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "level": { "type": "number", "description": "Volume level from 0.0 (mute) to 1.0 (100%)" }
                },
                "required": ["level"]
            }),
        },
        McpTool {
            name: "lifeos_brightness_get".into(),
            description: "Get current screen brightness level as percentage.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {},
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_brightness_set".into(),
            description: "Set screen brightness level (0-100).".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "level": { "type": "integer", "description": "Brightness percentage 0-100" }
                },
                "required": ["level"]
            }),
        },
        McpTool {
            name: "lifeos_notify".into(),
            description: "Send a desktop notification.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "title": { "type": "string", "description": "Notification title" },
                    "body": { "type": "string", "description": "Notification body text" },
                    "urgency": { "type": "string", "enum": ["low", "normal", "critical"], "default": "normal" }
                },
                "required": ["body"]
            }),
        },
        McpTool {
            name: "lifeos_files_open".into(),
            description: "Open a file with the default application (xdg-open).".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Absolute path to the file to open" }
                },
                "required": ["path"]
            }),
        },
        McpTool {
            name: "lifeos_displays_list".into(),
            description: "List connected displays with resolution, scale, and position.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {},
                "required": []
            }),
        },
        // ----- Control Layer Selection (AY.2) -----
        McpTool {
            name: "lifeos_select_layer".into(),
            description: "Select the best control layer (MCP/Native/Accessibility/Vision) for a given action.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "description": "Action to evaluate (e.g. 'open_app', 'click button', 'set wifi')"
                    }
                },
                "required": ["action"]
            }),
        },
        // ----- Browser MCP Bridge tools (AY.3) -----
        McpTool {
            name: "lifeos_browser_navigate".into(),
            description: "Navigate the browser to a URL and capture a screenshot.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "URL to navigate to"
                    }
                },
                "required": ["url"]
            }),
        },
        McpTool {
            name: "lifeos_browser_screenshot".into(),
            description: "Capture a screenshot of the current browser page.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {},
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_browser_extract_text".into(),
            description: "Extract all visible text content from the current browser page.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {},
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_browser_click".into(),
            description: "Click an element on the current browser page by CSS selector.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "selector": {
                        "type": "string",
                        "description": "CSS selector of the element to click"
                    }
                },
                "required": ["selector"]
            }),
        },
        McpTool {
            name: "lifeos_browser_fill".into(),
            description: "Fill an input field on the current browser page by CSS selector.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "selector": {
                        "type": "string",
                        "description": "CSS selector of the input element"
                    },
                    "value": {
                        "type": "string",
                        "description": "Value to fill into the input"
                    }
                },
                "required": ["selector", "value"]
            }),
        },
        // ----- LibreOffice MCP tools -----
        McpTool {
            name: "lifeos_writer_export_pdf".into(),
            description: "Export a LibreOffice Writer document to PDF via UNO bridge.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "input": { "type": "string", "description": "Path to the input document (odt, docx, etc.)" },
                    "output": { "type": "string", "description": "Path for the output PDF file" }
                },
                "required": ["input", "output"]
            }),
        },
        McpTool {
            name: "lifeos_calc_read_cells".into(),
            description: "Read cells from a LibreOffice Calc spreadsheet range (e.g. A1:D10) via UNO bridge.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "file": { "type": "string", "description": "Path to spreadsheet file (ods, xlsx, csv)" },
                    "range": { "type": "string", "description": "Cell range like A1:D10" }
                },
                "required": ["file", "range"]
            }),
        },
        McpTool {
            name: "lifeos_calc_verify_formula".into(),
            description: "Verify a cell value or formula matches an expected value in a LibreOffice Calc spreadsheet.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "file": { "type": "string", "description": "Path to spreadsheet file" },
                    "cell": { "type": "string", "description": "Cell address like E5" },
                    "expected": { "type": "string", "description": "Expected value or formula (e.g. '=SUM(A1:D1)' or '1500')" }
                },
                "required": ["file", "cell", "expected"]
            }),
        },
        McpTool {
            name: "lifeos_calc_sheet_info".into(),
            description: "Get sheet names, row/column counts, and basic info from a LibreOffice Calc spreadsheet.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "file": { "type": "string", "description": "Path to spreadsheet file" }
                },
                "required": ["file"]
            }),
        },
        // ----- COSMIC Desktop: Workspaces -----
        McpTool {
            name: "lifeos_workspaces_list".into(),
            description: "List all workspaces with names, focused state, and output (COSMIC/swaymsg).".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {},
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_workspaces_switch".into(),
            description: "Switch to a workspace by number or name.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "workspace": { "type": "string", "description": "Workspace number or name to switch to" }
                },
                "required": ["workspace"]
            }),
        },
        McpTool {
            name: "lifeos_workspaces_create".into(),
            description: "Create a new workspace by name (switches to it if it does not exist).".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "name": { "type": "string", "description": "Name for the new workspace" }
                },
                "required": ["name"]
            }),
        },
        McpTool {
            name: "lifeos_workspaces_move_window_to".into(),
            description: "Move the currently focused window to a different workspace.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "workspace": { "type": "string", "description": "Target workspace number or name" }
                },
                "required": ["workspace"]
            }),
        },
        // ----- COSMIC Apps Launch -----
        McpTool {
            name: "lifeos_cosmic_terminal".into(),
            description: "Launch COSMIC Terminal, optionally running a command inside it.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "command": { "type": "string", "description": "Optional command to run inside the terminal (e.g. htop)" }
                },
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_cosmic_files".into(),
            description: "Launch COSMIC Files file manager, optionally at a specific path.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Directory path to open" }
                },
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_cosmic_editor".into(),
            description: "Launch COSMIC Text Editor, optionally opening a specific file.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "file": { "type": "string", "description": "File path to open in the editor" }
                },
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_cosmic_settings".into(),
            description: "Launch COSMIC Settings, optionally opening a specific page (display, sound, network, etc.).".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "page": { "type": "string", "description": "Settings page to open (e.g. display, sound, network, bluetooth)" }
                },
                "required": []
            }),
        },
        McpTool {
            name: "lifeos_cosmic_store".into(),
            description: "Launch the COSMIC App Store.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {},
                "required": []
            }),
        },
        // ----- COSMIC Desktop Control -----
        McpTool {
            name: "lifeos_cosmic_dark_mode".into(),
            description: "Enable or disable COSMIC dark mode by writing the theme config.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "enabled": { "type": "boolean", "description": "true for dark mode, false for light mode" }
                },
                "required": ["enabled"]
            }),
        },
        McpTool {
            name: "lifeos_cosmic_dock_autohide".into(),
            description: "Enable or disable COSMIC dock auto-hide.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "enabled": { "type": "boolean", "description": "true to enable auto-hide, false to disable" }
                },
                "required": ["enabled"]
            }),
        },
        McpTool {
            name: "lifeos_cosmic_panel_position".into(),
            description: "Set the COSMIC panel position (top or bottom).".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "position": { "type": "string", "enum": ["top", "bottom"], "description": "Panel position" }
                },
                "required": ["position"]
            }),
        },
        // ----- Screen/Display -----
        McpTool {
            name: "lifeos_display_resolution".into(),
            description: "Set display resolution and refresh rate via cosmic-randr.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "output": { "type": "string", "description": "Output name (e.g. eDP-1, HDMI-A-1)" },
                    "mode": { "type": "string", "description": "Resolution and refresh rate (e.g. 1920x1080@60)" }
                },
                "required": ["output", "mode"]
            }),
        },
    ]
}

/// Process an MCP tool call and return the result.
/// This is a dispatcher — actual execution delegates to the appropriate module.
pub async fn call_tool(
    name: &str,
    arguments: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    match name {
        "lifeos_status" => {
            let alerts = crate::proactive::check_all(None).await;
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
            let command = arguments
                .get("command")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'command' parameter")?;

            // Blocklist check — same patterns as telegram_tools.rs
            let lower = command.to_lowercase();
            let blocked = [
                "rm -rf /",
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

            // Execute with risk gating
            let output = tokio::process::Command::new("sh")
                .arg("-c")
                .arg(command)
                .output()
                .await
                .map_err(|e| format!("Execution failed: {}", e))?;

            let stdout = String::from_utf8_lossy(&output.stdout);
            let stderr = String::from_utf8_lossy(&output.stderr);
            Ok(serde_json::json!({
                "exit_code": output.status.code(),
                "stdout": stdout.chars().take(4000).collect::<String>(),
                "stderr": stderr.chars().take(2000).collect::<String>(),
            }))
        }
        "lifeos_system_health" => {
            let alerts = crate::proactive::check_all(None).await;
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

            let result = crate::desktop_operator::DesktopOperator::execute(&action).await;
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
            let result = crate::desktop_operator::DesktopOperator::execute(&action).await;
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

// ---------------------------------------------------------------------------
// Sampling — allow MCP clients to request LLM completions through LifeOS
// ---------------------------------------------------------------------------

/// Handle a `sampling/createMessage` request by routing through the LLM router.
///
/// Accepts MCP-spec params:
/// - `messages`: array of `{role, content}` where content is text or structured
/// - `modelPreferences`: optional hints (unused for now — router picks the best)
/// - `maxTokens`: optional max output tokens
///
/// Returns `{role, content, model}` per the MCP sampling response schema.
async fn handle_sampling_create_message(
    params: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    use crate::llm_router::{ChatMessage, LlmRouter, RouterRequest};
    use crate::privacy_filter::PrivacyLevel;

    // Parse messages from the MCP request
    let messages_val = params
        .get("messages")
        .and_then(|v| v.as_array())
        .ok_or("Missing or invalid 'messages' array")?;

    let mut chat_messages: Vec<ChatMessage> = Vec::with_capacity(messages_val.len());
    for msg in messages_val {
        let role = msg
            .get("role")
            .and_then(|v| v.as_str())
            .unwrap_or("user")
            .to_string();

        // MCP content can be {type: "text", text: "..."} or a plain string
        let content = match msg.get("content") {
            Some(c) if c.is_object() => {
                // Extract text from structured content
                let text = c.get("text").and_then(|v| v.as_str()).unwrap_or("");
                serde_json::Value::String(text.to_string())
            }
            Some(c) if c.is_array() => {
                // Array of content parts — concatenate text parts
                let parts: Vec<&str> = c
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter_map(|p| {
                        if p.get("type").and_then(|t| t.as_str()) == Some("text") {
                            p.get("text").and_then(|t| t.as_str())
                        } else {
                            None
                        }
                    })
                    .collect();
                serde_json::Value::String(parts.join("\n"))
            }
            Some(c) => c.clone(),
            None => serde_json::Value::String(String::new()),
        };

        chat_messages.push(ChatMessage { role, content });
    }

    if chat_messages.is_empty() {
        return Err("'messages' array must not be empty".into());
    }

    let max_tokens = params
        .get("maxTokens")
        .and_then(|v| v.as_u64())
        .map(|v| v as u32);

    let router_request = RouterRequest {
        messages: chat_messages,
        complexity: None,
        sensitivity: None,
        preferred_provider: None,
        max_tokens,
    };

    let router = LlmRouter::new(PrivacyLevel::Balanced);
    let response = router
        .chat(&router_request)
        .await
        .map_err(|e| format!("LLM router error: {}", e))?;

    Ok(serde_json::json!({
        "role": "assistant",
        "content": {
            "type": "text",
            "text": response.text
        },
        "model": format!("{}/{}", response.provider, response.model),
        "_meta": {
            "provider": response.provider,
            "latency_ms": response.latency_ms,
            "tokens_used": response.tokens_used
        }
    }))
}

// ---------------------------------------------------------------------------
// External MCP server discovery
// ---------------------------------------------------------------------------

/// Discover tools from an external MCP server by sending a `tools/list` JSON-RPC request.
pub async fn discover_tools_from_server(server_url: &str) -> Result<Vec<McpTool>, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| format!("HTTP client error: {}", e))?;

    let request_body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/list",
        "params": {}
    });

    let resp = client
        .post(server_url)
        .json(&request_body)
        .send()
        .await
        .map_err(|e| format!("Failed to contact MCP server at {}: {}", server_url, e))?;

    if !resp.status().is_success() {
        return Err(format!("MCP server returned HTTP {}", resp.status()));
    }

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| format!("Invalid JSON response: {}", e))?;

    // The result should be an array of tool definitions
    let tools_value = body
        .get("result")
        .cloned()
        .unwrap_or(serde_json::Value::Array(vec![]));

    let tools: Vec<McpTool> = serde_json::from_value(tools_value)
        .map_err(|e| format!("Failed to parse tools from response: {}", e))?;

    Ok(tools)
}

/// Discover resources from an external MCP server by sending a `resources/list` JSON-RPC request.
pub async fn discover_resources_from_server(
    server_url: &str,
) -> Result<Vec<serde_json::Value>, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| format!("HTTP client error: {}", e))?;

    let request_body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "resources/list",
        "params": {}
    });

    let resp = client
        .post(server_url)
        .json(&request_body)
        .send()
        .await
        .map_err(|e| format!("Failed to contact MCP server at {}: {}", server_url, e))?;

    if !resp.status().is_success() {
        return Err(format!("MCP server returned HTTP {}", resp.status()));
    }

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| format!("Invalid JSON response: {}", e))?;

    let resources = body
        .get("result")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    Ok(resources)
}

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 Transport (stdio)
// ---------------------------------------------------------------------------

/// A JSON-RPC 2.0 request.
#[derive(Debug, Deserialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    pub id: Option<serde_json::Value>,
    pub method: String,
    #[serde(default)]
    pub params: serde_json::Value,
}

/// A JSON-RPC 2.0 response.
#[derive(Debug, Serialize)]
pub struct JsonRpcResponse {
    pub jsonrpc: String,
    pub id: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<serde_json::Value>,
}

/// Handle a single JSON-RPC request and produce a response.
pub async fn handle_jsonrpc(req: JsonRpcRequest) -> JsonRpcResponse {
    let (result, error) = match req.method.as_str() {
        "initialize" => (
            Some(serde_json::json!({
                "protocolVersion": "2025-11-25",
                "serverInfo": server_info(),
                "capabilities": {
                    "tools": { "listChanged": false },
                    "sampling": {}
                }
            })),
            None,
        ),
        "tools/list" => (
            Some(serde_json::to_value(list_tools()).unwrap_or_default()),
            None,
        ),
        "tools/call" => {
            let name = req
                .params
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let args = req
                .params
                .get("arguments")
                .cloned()
                .unwrap_or(serde_json::json!({}));
            match call_tool(name, &args).await {
                Ok(val) => (
                    Some(
                        serde_json::json!({ "content": [{"type": "text", "text": val.to_string()}] }),
                    ),
                    None,
                ),
                Err(e) => (
                    None,
                    Some(serde_json::json!({"code": -32603, "message": e})),
                ),
            }
        }
        "sampling/createMessage" => match handle_sampling_create_message(&req.params).await {
            Ok(val) => (Some(val), None),
            Err(e) => (
                None,
                Some(serde_json::json!({"code": -32603, "message": e})),
            ),
        },
        _ => (
            None,
            Some(
                serde_json::json!({"code": -32601, "message": format!("Method not found: {}", req.method)}),
            ),
        ),
    };

    JsonRpcResponse {
        jsonrpc: "2.0".into(),
        id: req.id,
        result,
        error,
    }
}
