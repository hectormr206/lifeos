//! Floating mini-widget — "Eye of Axi".
//!
//! A small, always-on-top, undecorated GTK4 window that renders a colored orb
//! matching `AxiState`. Left-click opens the web dashboard; right-click shows
//! a quick-action popup menu.
//!
//! Gated behind the `ui-overlay` feature flag (via `mod` in main.rs).

use gtk4::gdk::{self, Display};
use gtk4::prelude::*;
use gtk4::{self as gtk, CssProvider};
use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use tokio::sync::broadcast;

use crate::events::DaemonEvent;

/// Size of the floating orb window.
const ORB_SIZE: i32 = 48;

/// Aura colour table — matches `AxiState::aura()` strings.
fn aura_to_rgba(aura: &str) -> (f64, f64, f64) {
    match aura {
        "green" => (0.18, 0.84, 0.45),
        "cyan" => (0.0, 0.82, 0.83),
        "yellow" => (1.0, 0.65, 0.01),
        "blue" => (0.22, 0.26, 0.98),
        "teal" => (0.10, 0.74, 0.61),
        "red" => (1.0, 0.28, 0.34),
        "gray" => (0.39, 0.43, 0.45),
        "indigo" => (0.37, 0.15, 0.80),
        _ => (0.39, 0.43, 0.45),
    }
}

/// Launch the mini-widget GTK application on its own thread.
///
/// `dashboard_url` is the full URL including token query param.
pub fn spawn_mini_widget(
    event_bus: broadcast::Sender<DaemonEvent>,
    dashboard_url: String,
    initial_visible: bool,
) {
    std::thread::spawn(move || {
        let app = gtk::Application::builder()
            .application_id("org.lifeos.axi-eye")
            .build();

        let rx = event_bus.subscribe();
        let url = dashboard_url;
        let visible = initial_visible;

        app.connect_activate(move |app| {
            build_ui(app, rx.resubscribe(), url.clone(), visible);
        });

        // Suppress GTK command-line parsing.
        app.run_with_args::<&str>(&[]);
    });
}

fn build_ui(
    app: &gtk::Application,
    rx: broadcast::Receiver<DaemonEvent>,
    dashboard_url: String,
    initial_visible: bool,
) {
    // CSS for transparent background.
    let css = CssProvider::new();
    css.load_from_data(
        "window.orb-window { background: transparent; } \
         window.orb-window decoration { background: transparent; border: none; box-shadow: none; }",
    );
    if let Some(display) = Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }

    let window = gtk::Window::builder()
        .application(app)
        .default_width(ORB_SIZE)
        .default_height(ORB_SIZE)
        .decorated(false)
        .resizable(false)
        .title("Axi")
        .build();
    window.add_css_class("orb-window");

    let drawing_area = gtk::DrawingArea::new();
    drawing_area.set_content_width(ORB_SIZE);
    drawing_area.set_content_height(ORB_SIZE);
    window.set_child(Some(&drawing_area));

    // Shared aura colour state.
    let aura_color: Rc<RefCell<(f64, f64, f64)>> = Rc::new(RefCell::new(aura_to_rgba("gray")));
    let was_dragged = Rc::new(RefCell::new(false));

    // Draw callback.
    let color_ref = aura_color.clone();
    drawing_area.set_draw_func(move |_area, cr, width, height| {
        let (r, g, b) = *color_ref.borrow();
        let cx = width as f64 / 2.0;
        let cy = height as f64 / 2.0;
        let radius = (width.min(height) as f64 / 2.0) - 4.0;

        // Outer glow.
        cr.set_source_rgba(r, g, b, 0.25);
        cr.arc(cx, cy, radius + 3.0, 0.0, 2.0 * std::f64::consts::PI);
        let _ = cr.fill();

        // Main circle.
        cr.set_source_rgba(r, g, b, 0.9);
        cr.arc(cx, cy, radius, 0.0, 2.0 * std::f64::consts::PI);
        let _ = cr.fill();

        // Inner highlight.
        cr.set_source_rgba(1.0, 1.0, 1.0, 0.15);
        cr.arc(
            cx,
            cy - radius * 0.2,
            radius * 0.5,
            0.0,
            2.0 * std::f64::consts::PI,
        );
        let _ = cr.fill();
    });

    // Left-click → open dashboard.
    let click = gtk::GestureClick::new();
    click.set_button(1);
    let drag_flag = was_dragged.clone();
    click.connect_pressed(move |_, _, _, _| {
        *drag_flag.borrow_mut() = false;
    });
    let url_clone = dashboard_url.clone();
    let drag_flag = was_dragged.clone();
    click.connect_released(move |_, _, _, _| {
        let dragged = *drag_flag.borrow();
        *drag_flag.borrow_mut() = false;
        if dragged {
            return;
        }
        let _ = std::process::Command::new("xdg-open")
            .arg(&url_clone)
            .spawn();
    });
    drawing_area.add_controller(click);

    // Dragging the orb asks the compositor to move the floating window.
    let drag = gtk::GestureDrag::new();
    drag.set_button(1);
    let drag_flag = was_dragged.clone();
    let window_weak = window.downgrade();
    drag.connect_drag_begin(move |gesture, start_x, start_y| {
        *drag_flag.borrow_mut() = true;
        let Some(window) = window_weak.upgrade() else {
            return;
        };
        let Some(native) = window.native() else {
            return;
        };
        let Some(surface) = native.surface() else {
            return;
        };
        let Some(sequence) = gesture.last_updated_sequence() else {
            return;
        };
        let Some(event) = gesture.last_event(Some(&sequence)) else {
            return;
        };
        let Some(device) = gesture.device().or_else(|| event.device()) else {
            return;
        };
        let Ok(toplevel) = surface.dynamic_cast::<gdk::Toplevel>() else {
            return;
        };
        toplevel.begin_move(
            &device,
            gesture.current_button() as i32,
            start_x,
            start_y,
            event.time(),
        );
    });
    drawing_area.add_controller(drag);

    // Right-click → also open dashboard (quick actions in future).
    let right_click = gtk::GestureClick::new();
    right_click.set_button(3);
    let url_clone2 = dashboard_url;
    right_click.connect_released(move |_, _, _, _| {
        let _ = std::process::Command::new("xdg-open")
            .arg(&url_clone2)
            .spawn();
    });
    drawing_area.add_controller(right_click);

    // Bridge tokio broadcast → glib via std::sync::mpsc (Send-safe).
    enum WidgetMessage {
        Aura(String),
        Visibility(bool),
    }

    let (mpsc_tx, mpsc_rx) = std::sync::mpsc::channel::<WidgetMessage>();
    let rx = Arc::new(std::sync::Mutex::new(rx));
    std::thread::spawn(move || loop {
        let event = {
            let mut guard = rx.lock().unwrap();
            guard.blocking_recv()
        };
        let message = match event {
            Ok(DaemonEvent::AxiStateChanged { ref aura, .. }) => {
                Some(WidgetMessage::Aura(aura.clone()))
            }
            Ok(DaemonEvent::SensorChanged {
                kill_switch: true, ..
            }) => Some(WidgetMessage::Aura("gray".to_string())),
            Ok(DaemonEvent::MiniWidgetVisibilityChanged { visible }) => {
                Some(WidgetMessage::Visibility(visible))
            }
            Err(broadcast::error::RecvError::Closed) => break,
            _ => None,
        };
        if let Some(message) = message {
            let _ = mpsc_tx.send(message);
        }
    });

    // Poll the mpsc channel from the glib main loop (every 200ms).
    let color_for_poll = aura_color;
    let da = drawing_area;
    let widget_window = window.clone();
    glib::timeout_add_local(std::time::Duration::from_millis(200), move || {
        let mut redraw = false;
        while let Ok(message) = mpsc_rx.try_recv() {
            match message {
                WidgetMessage::Aura(aura) => {
                    *color_for_poll.borrow_mut() = aura_to_rgba(&aura);
                    redraw = true;
                }
                WidgetMessage::Visibility(visible) => {
                    if visible {
                        widget_window.present();
                    } else {
                        widget_window.set_visible(false);
                    }
                }
            }
        }
        if redraw {
            da.queue_draw();
        }
        glib::ControlFlow::Continue
    });

    window.present();
    if !initial_visible {
        window.set_visible(false);
    }
}
