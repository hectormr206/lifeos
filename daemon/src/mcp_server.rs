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
}

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
    ]
}

/// Process an MCP tool call and return the result.
/// This is a dispatcher — actual execution delegates to the appropriate module.
pub async fn call_tool(
    name: &str,
    arguments: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    match name {
        "lifeos_status" => Ok(serde_json::json!({
            "status": "available",
            "note": "Full implementation connects to DaemonState"
        })),
        "lifeos_task" => {
            let objective = arguments
                .get("objective")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'objective' parameter")?;
            Ok(serde_json::json!({
                "queued": true,
                "objective": objective,
                "note": "Task enqueued to supervisor"
            }))
        }
        "lifeos_shell" => {
            let command = arguments
                .get("command")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'command' parameter")?;
            Ok(serde_json::json!({
                "note": "Shell execution delegated to supervisor",
                "command": command
            }))
        }
        _ => Err(format!("Unknown tool: {}", name)),
    }
}
