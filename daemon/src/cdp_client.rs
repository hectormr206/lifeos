//! CDP (Chrome DevTools Protocol) WebSocket client.
//!
//! Provides a persistent connection to a browser's CDP endpoint so that
//! multiple operations can share the same browser instance and page state.

use futures_util::{SinkExt, StreamExt};
use log::{debug, error, info, warn};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::net::TcpStream;
use tokio::sync::{oneshot, Mutex};
use tokio::time::{timeout, Duration};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

type WsSink = futures_util::stream::SplitSink<WebSocketStream<MaybeTlsStream<TcpStream>>, Message>;

/// A node from the browser's accessibility tree.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AXNode {
    pub role: String,
    pub name: String,
    pub value: Option<String>,
    pub description: Option<String>,
    /// (x, y, width, height)
    pub bounding_box: Option<(f64, f64, f64, f64)>,
    pub children: Vec<AXNode>,
}

/// A persistent CDP WebSocket connection to a browser.
pub struct CdpClient {
    writer: Arc<Mutex<WsSink>>,
    pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>,
    next_id: AtomicU64,
    /// Events received from the browser (keyed by method name, stores latest).
    events: Arc<Mutex<HashMap<String, Value>>>,
    /// Port of the connected browser, used for reconnection.
    port: u16,
    /// WebSocket URL, used for reconnection.
    ws_url: String,
}

impl CdpClient {
    /// Connect to a running browser's CDP WebSocket endpoint.
    /// Discovers targets via `GET http://localhost:{port}/json` and connects
    /// to the first page target's `webSocketDebuggerUrl`.
    /// Retries discovery for up to 10 seconds (browser startup time).
    pub async fn connect(port: u16) -> Result<Self, String> {
        let http_client = reqwest::Client::new();
        let json_url = format!("http://127.0.0.1:{}/json", port);

        // Retry target discovery for up to 10 seconds
        let mut ws_url: Option<String> = None;
        for attempt in 0..20 {
            if attempt > 0 {
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
            match http_client.get(&json_url).send().await {
                Ok(resp) => {
                    if let Ok(targets) = resp.json::<Vec<Value>>().await {
                        // Find the first page target
                        for target in &targets {
                            if target["type"].as_str() == Some("page") {
                                if let Some(url) = target["webSocketDebuggerUrl"].as_str() {
                                    ws_url = Some(url.to_string());
                                    break;
                                }
                            }
                        }
                        // If no page target, try first target with a ws URL
                        if ws_url.is_none() {
                            for target in &targets {
                                if let Some(url) = target["webSocketDebuggerUrl"].as_str() {
                                    ws_url = Some(url.to_string());
                                    break;
                                }
                            }
                        }
                        if ws_url.is_some() {
                            break;
                        }
                    }
                }
                Err(_) => {
                    debug!(
                        "[cdp] Discovery attempt {} failed, retrying...",
                        attempt + 1
                    );
                }
            }
        }

        let ws_url = ws_url.ok_or_else(|| {
            format!(
                "Failed to discover CDP target on port {} after 10 seconds",
                port
            )
        })?;

        info!("[cdp] Connecting to WebSocket: {}", ws_url);
        Self::connect_to_ws(port, &ws_url).await
    }

    /// Connect directly to a known WebSocket URL.
    async fn connect_to_ws(port: u16, ws_url: &str) -> Result<Self, String> {
        let (ws_stream, _) = tokio_tungstenite::connect_async(ws_url)
            .await
            .map_err(|e| format!("WebSocket connect failed: {}", e))?;

        let (writer, reader) = ws_stream.split();

        let pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let events: Arc<Mutex<HashMap<String, Value>>> = Arc::new(Mutex::new(HashMap::new()));

        // Spawn background task to read messages and dispatch responses
        let pending_clone = Arc::clone(&pending);
        let events_clone = Arc::clone(&events);
        tokio::spawn(Self::read_loop(reader, pending_clone, events_clone));

        info!("[cdp] Connected to browser on port {}", port);

        Ok(Self {
            writer: Arc::new(Mutex::new(writer)),
            pending,
            next_id: AtomicU64::new(1),
            events,
            port,
            ws_url: ws_url.to_string(),
        })
    }

    /// Background read loop that dispatches CDP responses to pending oneshot senders
    /// and stores events.
    async fn read_loop(
        mut reader: futures_util::stream::SplitStream<WebSocketStream<MaybeTlsStream<TcpStream>>>,
        pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>,
        events: Arc<Mutex<HashMap<String, Value>>>,
    ) {
        while let Some(msg_result) = reader.next().await {
            match msg_result {
                Ok(Message::Text(text)) => {
                    if let Ok(json) = serde_json::from_str::<Value>(&text) {
                        // CDP response: has "id" field
                        if let Some(id) = json.get("id").and_then(|v| v.as_u64()) {
                            let mut guard = pending.lock().await;
                            if let Some(sender) = guard.remove(&id) {
                                let result = if let Some(r) = json.get("result") {
                                    r.clone()
                                } else if let Some(e) = json.get("error") {
                                    e.clone()
                                } else {
                                    json.clone()
                                };
                                let _ = sender.send(result);
                            }
                        } else if let Some(method) = json.get("method").and_then(|v| v.as_str()) {
                            // CDP event
                            let mut guard = events.lock().await;
                            guard.insert(method.to_string(), json);
                        }
                    }
                }
                Ok(Message::Close(_)) => {
                    warn!("[cdp] WebSocket closed by browser");
                    break;
                }
                Err(e) => {
                    error!("[cdp] WebSocket read error: {}", e);
                    break;
                }
                _ => {}
            }
        }
        debug!("[cdp] Read loop exited");
    }

    /// Send a CDP command and wait for the response with a 30-second timeout.
    /// On WebSocket disconnect, attempts one reconnect.
    pub async fn send(&self, method: &str, params: Value) -> Result<Value, String> {
        match self.send_inner(method, params.clone()).await {
            Ok(val) => Ok(val),
            Err(e) if e.contains("WebSocket") || e.contains("send failed") => {
                warn!("[cdp] Send failed ({}), attempting reconnect...", e);
                self.reconnect().await?;
                self.send_inner(method, params).await
            }
            Err(e) => Err(e),
        }
    }

    /// Internal send without reconnect logic.
    async fn send_inner(&self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let msg = json!({
            "id": id,
            "method": method,
            "params": params,
        });

        let (tx, rx) = oneshot::channel();
        {
            let mut guard = self.pending.lock().await;
            guard.insert(id, tx);
        }

        {
            let mut writer = self.writer.lock().await;
            writer
                .send(Message::Text(msg.to_string().into()))
                .await
                .map_err(|e| format!("WebSocket send failed: {}", e))?;
        }

        match timeout(Duration::from_secs(30), rx).await {
            Ok(Ok(value)) => {
                // Check if the response is a CDP error
                if let Some(err_msg) = value.get("message").and_then(|m| m.as_str()) {
                    if value.get("code").is_some() {
                        return Err(format!("CDP error: {}", err_msg));
                    }
                }
                Ok(value)
            }
            Ok(Err(_)) => Err("CDP response channel dropped".to_string()),
            Err(_) => {
                // Remove the pending entry on timeout
                let mut guard = self.pending.lock().await;
                guard.remove(&id);
                Err(format!("CDP command '{}' timed out after 30s", method))
            }
        }
    }

    /// Attempt to reconnect to the browser's WebSocket.
    async fn reconnect(&self) -> Result<(), String> {
        info!("[cdp] Reconnecting to {}...", self.ws_url);

        let (ws_stream, _) = tokio_tungstenite::connect_async(&self.ws_url)
            .await
            .map_err(|e| format!("Reconnect failed: {}", e))?;

        let (new_writer, new_reader) = ws_stream.split();

        // Replace writer
        {
            let mut writer = self.writer.lock().await;
            *writer = new_writer;
        }

        // Clear stale pending requests
        {
            let mut guard = self.pending.lock().await;
            guard.clear();
        }

        // Spawn new read loop
        let pending_clone = Arc::clone(&self.pending);
        let events_clone = Arc::clone(&self.events);
        tokio::spawn(Self::read_loop(new_reader, pending_clone, events_clone));

        info!("[cdp] Reconnected successfully");
        Ok(())
    }

    /// Navigate to a URL and wait for load.
    pub async fn navigate(&self, url: &str) -> Result<(), String> {
        // Enable Page domain events so we receive loadEventFired
        self.send("Page.enable", json!({})).await?;

        // Clear any previous load event
        {
            let mut evts = self.events.lock().await;
            evts.remove("Page.loadEventFired");
        }

        self.send("Page.navigate", json!({"url": url})).await?;

        // Wait for Page.loadEventFired (poll up to 30s)
        let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
        loop {
            {
                let evts = self.events.lock().await;
                if evts.contains_key("Page.loadEventFired") {
                    break;
                }
            }
            if tokio::time::Instant::now() > deadline {
                warn!("[cdp] Page.loadEventFired not received within 30s, continuing anyway");
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }

        Ok(())
    }

    /// Execute JavaScript in the page context and return the result.
    pub async fn evaluate(&self, expression: &str) -> Result<Value, String> {
        let result = self
            .send(
                "Runtime.evaluate",
                json!({
                    "expression": expression,
                    "returnByValue": true,
                    "awaitPromise": true,
                }),
            )
            .await?;

        // Check for exceptions
        if let Some(exception) = result.get("exceptionDetails") {
            let text = exception
                .get("text")
                .and_then(|t| t.as_str())
                .unwrap_or("unknown exception");
            return Err(format!("JS exception: {}", text));
        }

        Ok(result
            .get("result")
            .and_then(|r| r.get("value"))
            .cloned()
            .unwrap_or(Value::Null))
    }

    /// Take a screenshot, return base64 PNG.
    pub async fn screenshot(&self) -> Result<String, String> {
        let result = self
            .send("Page.captureScreenshot", json!({"format": "png"}))
            .await?;
        Ok(result
            .get("data")
            .and_then(|d| d.as_str())
            .unwrap_or("")
            .to_string())
    }

    /// Get the accessibility tree.
    pub async fn get_accessibility_tree(&self) -> Result<Vec<AXNode>, String> {
        let result = self.send("Accessibility.getFullAXTree", json!({})).await?;
        parse_ax_nodes(&result)
    }

    /// Click an element by CSS selector.
    pub async fn click(&self, selector: &str) -> Result<(), String> {
        // 1. Find element via DOM.querySelector
        let doc = self.send("DOM.getDocument", json!({})).await?;
        let root_id = doc
            .get("root")
            .and_then(|r| r.get("nodeId"))
            .and_then(|n| n.as_i64())
            .unwrap_or(1);
        let node = self
            .send(
                "DOM.querySelector",
                json!({
                    "nodeId": root_id,
                    "selector": selector,
                }),
            )
            .await?;
        let node_id = node
            .get("nodeId")
            .and_then(|n| n.as_i64())
            .ok_or_else(|| format!("Element not found: {}", selector))?;

        if node_id == 0 {
            return Err(format!("Element not found: {}", selector));
        }

        // 2. Get bounding box
        let box_model = self
            .send("DOM.getBoxModel", json!({"nodeId": node_id}))
            .await?;
        let content = box_model
            .get("model")
            .and_then(|m| m.get("content"))
            .ok_or("Could not get box model content")?;

        // content is [x1,y1, x2,y2, x3,y3, x4,y4] — take center
        let x = (content.get(0).and_then(|v| v.as_f64()).unwrap_or(0.0)
            + content.get(2).and_then(|v| v.as_f64()).unwrap_or(0.0))
            / 2.0;
        let y = (content.get(1).and_then(|v| v.as_f64()).unwrap_or(0.0)
            + content.get(5).and_then(|v| v.as_f64()).unwrap_or(0.0))
            / 2.0;

        // 3. Dispatch mouse events
        self.send(
            "Input.dispatchMouseEvent",
            json!({
                "type": "mousePressed",
                "x": x,
                "y": y,
                "button": "left",
                "clickCount": 1,
            }),
        )
        .await?;
        self.send(
            "Input.dispatchMouseEvent",
            json!({
                "type": "mouseReleased",
                "x": x,
                "y": y,
                "button": "left",
                "clickCount": 1,
            }),
        )
        .await?;
        Ok(())
    }

    /// Fill an input field by CSS selector.
    pub async fn fill(&self, selector: &str, value: &str) -> Result<(), String> {
        // Focus the element and clear it
        let escaped_selector = selector.replace('\\', "\\\\").replace('\'', "\\'");
        self.evaluate(&format!(
            "document.querySelector('{}').focus(); document.querySelector('{}').value = ''; void 0;",
            escaped_selector, escaped_selector
        ))
        .await?;

        // Type each character via Input.dispatchKeyEvent
        for ch in value.chars() {
            let text = ch.to_string();
            self.send(
                "Input.dispatchKeyEvent",
                json!({
                    "type": "keyDown",
                    "text": text,
                }),
            )
            .await?;
            self.send(
                "Input.dispatchKeyEvent",
                json!({
                    "type": "keyUp",
                    "text": text,
                }),
            )
            .await?;
        }

        // Dispatch input event for React/Vue reactivity
        self.evaluate(&format!(
            "document.querySelector('{}').dispatchEvent(new Event('input', {{bubbles: true}})); void 0;",
            escaped_selector
        ))
        .await?;
        Ok(())
    }

    /// Get all cookies for the current page.
    pub async fn get_cookies(&self) -> Result<Vec<Value>, String> {
        // Try Network.getCookies (widely supported)
        let result = self.send("Network.getCookies", json!({})).await?;
        if let Some(cookies) = result.get("cookies").and_then(|c| c.as_array()) {
            return Ok(cookies.clone());
        }
        // Fallback: Storage.getCookies
        let result = self.send("Storage.getCookies", json!({})).await?;
        Ok(result
            .get("cookies")
            .and_then(|c| c.as_array())
            .cloned()
            .unwrap_or_default())
    }

    /// Set cookies.
    pub async fn set_cookies(&self, cookies: &[Value]) -> Result<(), String> {
        self.send("Network.setCookies", json!({"cookies": cookies}))
            .await?;
        Ok(())
    }

    /// Open a new tab and return the target id.
    pub async fn new_tab(&self, url: &str) -> Result<String, String> {
        let result = self
            .send("Target.createTarget", json!({"url": url}))
            .await?;
        Ok(result
            .get("targetId")
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string())
    }

    /// Switch to a tab by target id.
    pub async fn activate_tab(&self, target_id: &str) -> Result<(), String> {
        self.send("Target.activateTarget", json!({"targetId": target_id}))
            .await?;
        Ok(())
    }

    /// Close a tab.
    pub async fn close_tab(&self, target_id: &str) -> Result<(), String> {
        self.send("Target.closeTarget", json!({"targetId": target_id}))
            .await?;
        Ok(())
    }

    /// Get console errors (enables Runtime domain, then evaluates collector).
    pub async fn get_console_errors(&self) -> Result<Vec<String>, String> {
        self.send("Runtime.enable", json!({})).await?;
        let result = self
            .evaluate("(function() { return window.__lifeos_errors || []; })()")
            .await?;
        Ok(result
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default())
    }

    /// Enable network interception.
    pub async fn enable_network_interception(&self) -> Result<(), String> {
        self.send("Network.enable", json!({})).await?;
        Ok(())
    }

    /// Set download behavior.
    pub async fn set_download_path(&self, path: &str) -> Result<(), String> {
        self.send(
            "Browser.setDownloadBehavior",
            json!({
                "behavior": "allow",
                "downloadPath": path,
            }),
        )
        .await?;
        Ok(())
    }
}

/// Parse CDP accessibility tree nodes into our `AXNode` struct.
fn parse_ax_nodes(result: &Value) -> Result<Vec<AXNode>, String> {
    let nodes = result
        .get("nodes")
        .and_then(|n| n.as_array())
        .ok_or("No nodes array in accessibility tree response")?;

    let parsed: Vec<AXNode> = nodes
        .iter()
        .map(|node| {
            let role = node
                .get("role")
                .and_then(|r| r.get("value"))
                .and_then(|v| v.as_str())
                .unwrap_or("unknown")
                .to_string();
            let name = node
                .get("name")
                .and_then(|r| r.get("value"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let value = node
                .get("value")
                .and_then(|r| r.get("value"))
                .and_then(|v| v.as_str())
                .map(String::from);
            let description = node
                .get("description")
                .and_then(|r| r.get("value"))
                .and_then(|v| v.as_str())
                .map(String::from);

            AXNode {
                role,
                name,
                value,
                description,
                bounding_box: None, // CDP AX tree doesn't always include bbox
                children: Vec::new(),
            }
        })
        .collect();

    Ok(parsed)
}
