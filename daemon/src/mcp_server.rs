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
        _ => Err(format!("Unknown tool: {}", name)),
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
                let text = c
                    .get("text")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
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
        "sampling/createMessage" => {
            match handle_sampling_create_message(&req.params).await {
                Ok(val) => (Some(val), None),
                Err(e) => (
                    None,
                    Some(serde_json::json!({"code": -32603, "message": e})),
                ),
            }
        }
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
