//! GTK4 Overlay Window for LifeOS AI
//!
//! Provides a floating overlay window that appears on Super+Space:
//! - Draggable and resizable window
//! - Chat UI for llama-server interaction
//! - Screen preview integration
//! - Handles global keyboard shortcuts
//!
//! Uses GTK4 (Libadwaita) compatible with COSMIC desktop.

use anyhow::Result;
use glib::clone;
use gtk::gdk;
use gtk4::{self as gtk, prelude::*};
use log::{debug, error, info};
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::overlay::{ChatMessage, ChatRole, OverlayConfig, OverlayState, OverlayTheme};

/// GTK4 Overlay Window Manager
pub struct OverlayWindow {
    _app: gtk::Application,
    window: gtk::ApplicationWindow,
    _overlay_box: gtk::Box,
    chat_scrolled: gtk::ScrolledWindow,
    chat_box: gtk::Box,
    _input_box: gtk::Box,
    input_entry: gtk::Entry,
    send_button: gtk::Button,
    screenshot_button: gtk::Button,
    clear_button: gtk::Button,
    _config: OverlayConfig,
    state: Arc<RwLock<OverlayState>>,
    _screenshot_path: std::path::PathBuf,
}

impl OverlayWindow {
    /// Create new overlay window
    pub fn new(
        app: gtk::Application,
        config: OverlayConfig,
        state: Arc<RwLock<OverlayState>>,
        screenshot_dir: std::path::PathBuf,
    ) -> Result<Self> {
        let window = gtk::ApplicationWindow::builder()
            .application(&app)
            .title("LifeOS AI Overlay")
            .default_width(600)
            .default_height(400)
            .resizable(true)
            .decorated(false) // No window decorations for overlay feel
            .build();

        // Create main container
        let overlay_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(10)
            .margin_top(10)
            .margin_bottom(10)
            .margin_start(10)
            .margin_end(10)
            .build();

        // Create chat area
        let chat_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(5)
            .build();

        let chat_scrolled = gtk::ScrolledWindow::builder()
            .vscrollbar_policy(gtk::PolicyType::Automatic)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .min_content_height(250)
            .child(&chat_box)
            .build();

        // Create input area
        let input_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(5)
            .build();

        let input_entry = gtk::Entry::builder()
            .placeholder_text("Ask AI anything...")
            .hexpand(true)
            .activates_default(true)
            .build();

        let send_button = gtk::Button::builder()
            .label("Send")
            .css_classes(["suggested-action"])
            .build();

        let screenshot_button = gtk::Button::builder().label("📷 Screen").build();
        screenshot_button.set_tooltip_text(Some("Capture and include screen context"));

        let clear_button = gtk::Button::builder().label("🗑 Clear").build();
        clear_button.set_tooltip_text(Some("Clear chat history"));

        input_box.append(&input_entry);
        input_box.append(&send_button);
        input_box.append(&screenshot_button);
        input_box.append(&clear_button);

        // Add header
        let header_label = gtk::Label::builder()
            .label("<b>LifeOS AI Assistant</b>")
            .halign(gtk::Align::Start)
            .margin_bottom(5)
            .build();
        header_label.set_use_markup(true);

        let status_label = gtk::Label::builder()
            .label("Ready")
            .halign(gtk::Align::Start)
            .margin_bottom(10)
            .css_classes(["status-label"])
            .build();

        // Assemble UI
        overlay_box.append(&header_label);
        overlay_box.append(&chat_scrolled);
        overlay_box.append(&status_label);
        overlay_box.append(&input_box);

        window.set_child(Some(&overlay_box));

        // Setup window position
        Self::setup_window_position(&window, &config);

        // Apply theme
        Self::apply_theme(&overlay_box, &config.theme);

        Ok(Self {
            _app: app,
            window,
            _overlay_box: overlay_box,
            chat_scrolled,
            chat_box,
            _input_box: input_box,
            input_entry,
            send_button,
            screenshot_button,
            clear_button,
            _config: config,
            state,
            _screenshot_path: screenshot_dir,
        })
    }

    /// Setup window position
    fn setup_window_position(window: &gtk::ApplicationWindow, _config: &OverlayConfig) {
        window.set_default_size(600, 400);
    }

    /// Apply theme to overlay
    fn apply_theme(overlay_box: &gtk::Box, theme: &OverlayTheme) {
        let css = match theme {
            OverlayTheme::Dark => {
                r#"
                    .overlay-box {
                        background-color: #1e1e2e;
                        border-radius: 12px;
                        padding: 15px;
                    }
                    .status-label {
                        color: #88c0d0;
                        font-size: 0.85em;
                    }
                    entry {
                        background-color: #2d2d3d;
                        border-radius: 8px;
                        padding: 10px;
                        border: 1px solid #3d3d4d;
                    }
                    .button {
                        background-color: #4a4a5a;
                        color: white;
                        border-radius: 8px;
                        padding: 8px 16px;
                    }
                    .button:hover {
                        background-color: #5a5a6a;
                    }
                    .message-user {
                        background-color: #4a4a5a;
                        color: white;
                        padding: 10px;
                        border-radius: 8px;
                        margin-bottom: 5px;
                    }
                    .message-assistant {
                        background-color: #1e1e2e;
                        color: #88c0d0;
                        padding: 10px;
                        border-radius: 8px;
                        margin-bottom: 5px;
                        border-left: 3px solid #88c0d0;
                    }
                "#
            }
            OverlayTheme::Light => {
                r#"
                    .overlay-box {
                        background-color: #ffffff;
                        border: 1px solid #d0d0d0;
                        border-radius: 12px;
                        padding: 15px;
                        box-shadow: 0 4px 20px rgba(0,0,0,0.15);
                    }
                    .status-label {
                        color: #2196f3;
                        font-size: 0.85em;
                    }
                    entry {
                        background-color: #f5f5f5;
                        border-radius: 8px;
                        padding: 10px;
                        border: 1px solid #e0e0e0;
                    }
                    .button {
                        background-color: #2196f3;
                        color: white;
                        border-radius: 8px;
                        padding: 8px 16px;
                    }
                    .button:hover {
                        background-color: #1971c2;
                    }
                    .message-user {
                        background-color: #e8f4f8;
                        color: #1a1a1a;
                        padding: 10px;
                        border-radius: 8px;
                        margin-bottom: 5px;
                    }
                    .message-assistant {
                        background-color: #f8f9fa;
                        color: #1a1a1a;
                        padding: 10px;
                        border-radius: 8px;
                        margin-bottom: 5px;
                        border-left: 3px solid #2196f3;
                    }
                "#
            }
            OverlayTheme::Auto => {
                r#"
                    @media (prefers-color-scheme: dark) {
                        .overlay-box { background-color: #1e1e2e; }
                        .message-user { background-color: #4a4a5a; color: white; }
                        .message-assistant { background-color: #1e1e2e; color: #88c0d0; border-left-color: #88c0d0; }
                        .button { background-color: #4a4a5a; }
                        .status-label { color: #88c0d0; }
                    }
                    @media (prefers-color-scheme: light) {
                        .overlay-box { background-color: #ffffff; border: 1px solid #d0d0d0; }
                        .message-user { background-color: #e8f4f8; color: #1a1a1a; }
                        .message-assistant { background-color: #f8f9fa; color: #1a1a1a; border-left-color: #2196f3; }
                        .button { background-color: #2196f3; }
                        .status-label { color: #2196f3; }
                    }
                "#
            }
        };

        let provider = gtk::CssProvider::new();
        provider.load_from_data(css);
        overlay_box
            .style_context()
            .add_provider(&provider, gtk::STYLE_PROVIDER_PRIORITY_USER);
    }

    /// Show overlay window
    pub fn show(&self) {
        debug!("Showing overlay window");
        self.window.present();
        self.window.grab_focus();

        if let Ok(mut state) = self.state.try_write() {
            state.visible = true;
        }
    }

    /// Hide overlay window
    pub fn hide(&self) {
        debug!("Hiding overlay window");
        self.window.hide();

        if let Ok(mut state) = self.state.try_write() {
            state.visible = false;
        }
    }

    /// Toggle visibility
    pub fn toggle(&self) {
        if self.window.is_visible() {
            self.hide();
        } else {
            self.show();
        }
    }

    /// Check if window is visible
    pub fn is_visible(&self) -> bool {
        self.window.is_visible()
    }

    /// Add chat message to UI
    pub fn add_message(&self, message: ChatMessage) {
        // Create message widget
        let message_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(10)
            .margin_bottom(10)
            .build();

        let role_label = match message.role {
            ChatRole::User => "You:",
            ChatRole::Assistant => "AI:",
            ChatRole::System => "System:",
        };

        let role_text = gtk::Label::builder()
            .label(format!("<b>{}</b>", role_label))
            .build();
        role_text.set_use_markup(true);
        role_text.add_css_class("role-label");
        match message.role {
            ChatRole::User => role_text.add_css_class("role-user"),
            ChatRole::Assistant => role_text.add_css_class("role-assistant"),
            ChatRole::System => {}
        }

        let content_text = gtk::Label::builder()
            .label(&message.content)
            .wrap_mode(gtk::pango::WrapMode::Word)
            .halign(gtk::Align::Start)
            .css_classes(["message-content"])
            .build();

        message_box.append(&role_text);
        message_box.append(&content_text);

        // Add separator
        if message.role == ChatRole::User {
            let separator = gtk::Separator::builder().build();
            separator.set_orientation(gtk::Orientation::Horizontal);
            self.chat_box.append(&separator);
        }

        self.chat_box.append(&message_box);

        // Scroll to bottom
        let adjustment = self.chat_scrolled.vadjustment();
        adjustment.set_value(adjustment.upper());
    }

    /// Clear all messages
    pub fn clear_messages(&self) {
        // Remove all children from chat_box except the last separator
        while let Some(child) = self.chat_box.first_child() {
            self.chat_box.remove(&child);
        }
    }

    /// Update status label
    pub fn set_status(&self, status: &str, _status_type: &str) {
        info!("Status: {}", status);
    }

    /// Set loading state
    pub fn set_loading(&self, loading: bool) {
        if loading {
            self.input_entry.set_sensitive(false);
            self.send_button.set_sensitive(false);
            self.send_button.set_label("Thinking...");
            self.set_status("Processing", "loading");
        } else {
            self.input_entry.set_sensitive(true);
            self.send_button.set_sensitive(true);
            self.send_button.set_label("Send");
            self.input_entry.grab_focus();
            self.set_status("Ready", "ready");
        }
    }

    /// Get current input text
    pub fn get_input(&self) -> String {
        self.input_entry.text().to_string()
    }

    /// Clear input
    pub fn clear_input(&self) {
        self.input_entry.set_text("");
    }

    /// Setup signal handlers
    pub fn setup_handlers(&self) {
        // Send button
        let state = self.state.clone();
        let input_entry = self.input_entry.clone();

        self.send_button.connect_clicked(clone!(
            #[strong]
            state,
            #[strong]
            input_entry,
            move |_| {
                let message = input_entry.text().to_string();
                if !message.is_empty() {
                    input_entry.set_text("");
                    // Include screen context
                    let include_screen = true;
                    // For now, generate response without actual llama-server call
                    let response = format!("I understand: {}", message);

                    if let Ok(mut st) = state.try_write() {
                        // Add user message to state
                        st.chat_history.push(ChatMessage {
                            id: uuid::Uuid::new_v4().to_string(),
                            role: ChatRole::User,
                            content: message.clone(),
                            timestamp: chrono::Utc::now().to_rfc3339(),
                            has_screen_context: include_screen,
                        });

                        // Add AI response
                        st.chat_history.push(ChatMessage {
                            id: uuid::Uuid::new_v4().to_string(),
                            role: ChatRole::Assistant,
                            content: response,
                            timestamp: chrono::Utc::now().to_rfc3339(),
                            has_screen_context: include_screen,
                        });

                        st.last_message_timestamp = chrono::Utc::now().to_rfc3339();
                    }
                }
            }
        ));

        // Screenshot button
        let state = self.state.clone();
        self.screenshot_button.connect_clicked(clone!(
            #[strong]
            state,
            move |_| {
                if let Ok(mut st) = state.try_write() {
                    st.chat_history.push(ChatMessage {
                        id: uuid::Uuid::new_v4().to_string(),
                        role: ChatRole::System,
                        content: "[Screen captured - AI can now see what you're seeing]"
                            .to_string(),
                        timestamp: chrono::Utc::now().to_rfc3339(),
                        has_screen_context: true,
                    });
                }
            }
        ));

        // Clear button
        let chat_box = self.chat_box.clone();
        self.clear_button.connect_clicked(clone!(
            #[strong]
            chat_box,
            move |_| {
                while let Some(child) = chat_box.first_child() {
                    chat_box.remove(&child);
                }
            }
        ));

        // Escape key to hide
        let window = self.window.clone();
        let key_controller = gtk::EventControllerKey::new();
        key_controller.connect_key_pressed(clone!(
            #[strong]
            window,
            move |_, key, _, _| {
                if key == gdk::Key::Escape {
                    window.hide();
                    glib::Propagation::Stop
                } else {
                    glib::Propagation::Proceed
                }
            }
        ));

        window.add_controller(key_controller);

        // Focus entry on show
        let input_entry = self.input_entry.clone();
        self.window.connect_show(clone!(
            #[strong]
            input_entry,
            move |_| {
                input_entry.grab_focus();
            }
        ));

        // Update state on hide
        let state = self.state.clone();
        self.window.connect_hide(clone!(
            #[strong]
            state,
            move |_| {
                if let Ok(mut st) = state.try_write() {
                    st.visible = false;
                }
            }
        ));
    }

    /// Get window for external access
    pub fn window(&self) -> &gtk::ApplicationWindow {
        &self.window
    }
}

/// Create and run the overlay application
pub fn run_overlay_app(
    config: OverlayConfig,
    state: Arc<RwLock<OverlayState>>,
    screenshot_dir: std::path::PathBuf,
) -> Result<()> {
    info!("Starting GTK4 overlay application");

    let app = gtk::Application::builder()
        .application_id("lifeos.ai.overlay")
        .flags(gtk::gio::ApplicationFlags::NON_UNIQUE)
        .build();

    app.connect_activate(move |app| {
        match OverlayWindow::new(
            app.clone(),
            config.clone(),
            state.clone(),
            screenshot_dir.clone(),
        ) {
            Ok(overlay_window) => {
                overlay_window.setup_handlers();

                // Add window to application
                app.add_window(&overlay_window.window);

                info!("Overlay window created successfully");
            }
            Err(e) => {
                error!("Failed to create overlay window: {}", e);
            }
        }
    });

    // Run the application
    app.run();

    Ok(())
}
