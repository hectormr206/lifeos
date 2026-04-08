//! Control Layer Selection — determines the best way to perform an action.
//!
//! Hierarchy (from most to least reliable):
//! 1. MCP tools (structured, auditable, fast)
//! 2. Native adapters (platform-specific APIs)
//! 3. Accessibility tree (AT-SPI2, UIAutomation)
//! 4. Vision + input (screenshot + OCR + mouse/keyboard — last resort)

#![allow(dead_code)]

use log::{info, warn};

#[derive(Debug, Clone, PartialEq)]
pub enum ControlLayer {
    /// Structured MCP tool call — most reliable, fastest, auditable
    Mcp,
    /// Platform-specific API adapter (D-Bus, COM, AppleScript)
    NativeAdapter,
    /// Accessibility tree navigation (AT-SPI2, UIAutomation)
    Accessibility,
    /// Vision-based: screenshot + OCR + mouse/keyboard — fallback only
    VisionInput,
}

impl std::fmt::Display for ControlLayer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Mcp => write!(f, "MCP"),
            Self::NativeAdapter => write!(f, "Native Adapter"),
            Self::Accessibility => write!(f, "Accessibility"),
            Self::VisionInput => write!(f, "Vision+Input"),
        }
    }
}

/// Known MCP tools that can handle specific actions
const MCP_CAPABLE_ACTIONS: &[(&str, &str)] = &[
    ("open_app", "lifeos_apps_launch"),
    ("list_windows", "lifeos_windows_list"),
    ("focus_window", "lifeos_windows_focus"),
    ("move_window", "lifeos_windows_move"),
    ("close_window", "lifeos_windows_close"),
    ("get_clipboard", "lifeos_clipboard_get"),
    ("set_clipboard", "lifeos_clipboard_set"),
    ("take_screenshot", "lifeos_system_screenshot"),
    ("set_volume", "lifeos_volume_set"),
    ("get_volume", "lifeos_volume_get"),
    ("send_notification", "lifeos_notify"),
    ("open_file", "lifeos_files_open"),
    ("navigate_url", "lifeos_browser_navigate"),
    ("browser_screenshot", "lifeos_browser_screenshot"),
    ("browser_click", "lifeos_browser_click"),
    ("read_file", "lifeos_files_read"),
    ("write_file", "lifeos_files_write"),
    ("search_files", "lifeos_files_search"),
    ("run_command", "lifeos_shell"),
];

/// Select the best control layer for a given action.
/// Returns the recommended layer and optionally the specific MCP tool name.
pub fn select_layer(action: &str) -> (ControlLayer, Option<String>) {
    let action_lower = action.to_lowercase();

    // 1. Check MCP tools
    for (pattern, tool) in MCP_CAPABLE_ACTIONS {
        if action_lower.contains(pattern) {
            info!("[control_layers] Action '{}' → MCP tool '{}'", action, tool);
            return (ControlLayer::Mcp, Some(tool.to_string()));
        }
    }

    // 2. Check native adapters (D-Bus on Linux)
    let dbus_actions = ["wifi", "bluetooth", "network", "power", "display", "theme"];
    for keyword in &dbus_actions {
        if action_lower.contains(keyword) {
            info!(
                "[control_layers] Action '{}' → Native Adapter (D-Bus)",
                action
            );
            return (ControlLayer::NativeAdapter, None);
        }
    }

    // 3. Check accessibility-suitable actions
    let a11y_actions = ["menu", "button", "dialog", "form", "dropdown", "checkbox"];
    for keyword in &a11y_actions {
        if action_lower.contains(keyword) {
            info!("[control_layers] Action '{}' → Accessibility", action);
            return (ControlLayer::Accessibility, None);
        }
    }

    // 4. Default to vision+input — Layer 4 fallback
    // Vision modules: computer_use.rs (mouse/keyboard), screen_capture.rs (grim),
    // sensory_pipeline.rs (OCR), browser_automation.rs (CDP visual)
    warn!(
        "[control_layers] Action '{}' fell through to Vision+Input (Layer 4). \
         Consider adding an MCP tool for this action.",
        action
    );
    (ControlLayer::VisionInput, None)
}

/// Get all available MCP tools
pub fn available_mcp_tools() -> Vec<(&'static str, &'static str)> {
    MCP_CAPABLE_ACTIONS.to_vec()
}
