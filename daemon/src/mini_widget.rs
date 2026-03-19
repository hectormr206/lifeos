//! Floating mini-widget — "Eye of Axi".
//!
//! A small, always-on-top, undecorated GTK4 window that renders a colored orb
//! matching `AxiState`. Left-click opens the web dashboard and dragging lets
//! the compositor reposition the widget on the desktop.
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

/// Size of the floating orb inside the widget window.
const ORB_SIZE: i32 = 48;
const WIDGET_WIDTH: i32 = 208;
const WIDGET_HEIGHT: i32 = 64;

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

fn pretty_state_label(state: &str) -> String {
    match state.to_ascii_lowercase().as_str() {
        "idle" => "En espera".to_string(),
        "listening" => "Escuchando".to_string(),
        "thinking" => "Pensando".to_string(),
        "speaking" => "Hablando".to_string(),
        "watching" => "Observando".to_string(),
        "error" => "Atencion".to_string(),
        "offline" => "Desconectado".to_string(),
        "night" => "Modo nocturno".to_string(),
        other if !other.is_empty() => other.to_string(),
        _ => "Axi".to_string(),
    }
}

/// Launch the mini-widget GTK application on its own thread.
///
/// `dashboard_url` is the full URL including token query param.
pub fn spawn_mini_widget(
    event_bus: broadcast::Sender<DaemonEvent>,
    dashboard_url: String,
    initial_visible: bool,
    initial_state: String,
    initial_badge: Option<String>,
    initial_aura: String,
) {
    std::thread::spawn(move || {
        let app = gtk::Application::builder()
            .application_id("org.lifeos.axi-eye")
            .build();

        let rx = event_bus.subscribe();
        let url = dashboard_url;
        let visible = initial_visible;
        let state = initial_state;
        let badge = initial_badge;
        let aura = initial_aura;

        app.connect_activate(move |app| {
            build_ui(
                app,
                rx.resubscribe(),
                url.clone(),
                visible,
                state.clone(),
                badge.clone(),
                aura.clone(),
            );
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
    initial_state: String,
    initial_badge: Option<String>,
    initial_aura: String,
) {
    let css = CssProvider::new();
    css.load_from_data(
        "window.orb-window { background: transparent; } \
         window.orb-window decoration { background: transparent; border: none; box-shadow: none; } \
         box.widget-shell { \
           background: rgba(12, 15, 24, 0.84); \
           border: 1px solid rgba(132, 153, 198, 0.22); \
           border-radius: 999px; \
           padding: 8px 12px; \
           box-shadow: 0 16px 40px rgba(2, 6, 23, 0.36); \
         } \
         box.widget-copy { min-width: 112px; } \
         label.widget-title { \
           color: rgba(248, 250, 252, 0.96); \
           font-weight: 700; \
           letter-spacing: 0.08em; \
           text-transform: uppercase; \
           font-size: 12px; \
         } \
         label.widget-status { \
           color: rgba(226, 232, 240, 0.88); \
           font-weight: 600; \
           font-size: 12px; \
         } \
         label.widget-badge { \
           color: rgba(148, 163, 184, 0.92); \
           font-size: 11px; \
         }",
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
        .default_width(WIDGET_WIDTH)
        .default_height(WIDGET_HEIGHT)
        .decorated(false)
        .resizable(false)
        .title("Axi")
        .build();
    window.add_css_class("orb-window");
    window.set_tooltip_text(Some("Arrastra para mover · click para abrir Axi"));

    let shell = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    shell.add_css_class("widget-shell");
    shell.set_margin_top(6);
    shell.set_margin_bottom(6);
    shell.set_margin_start(6);
    shell.set_margin_end(6);

    let drawing_area = gtk::DrawingArea::new();
    drawing_area.set_content_width(ORB_SIZE);
    drawing_area.set_content_height(ORB_SIZE);

    let copy_box = gtk::Box::new(gtk::Orientation::Vertical, 2);
    copy_box.add_css_class("widget-copy");

    let title_label = gtk::Label::new(Some("AXI"));
    title_label.add_css_class("widget-title");
    title_label.set_xalign(0.0);

    let status_label = gtk::Label::new(Some(&pretty_state_label(&initial_state)));
    status_label.add_css_class("widget-status");
    status_label.set_xalign(0.0);

    let initial_badge_text = initial_badge
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "LifeOS AI Core".to_string());
    let badge_label = gtk::Label::new(Some(&initial_badge_text));
    badge_label.add_css_class("widget-badge");
    badge_label.set_xalign(0.0);
    badge_label.set_ellipsize(gtk::pango::EllipsizeMode::End);
    badge_label.set_max_width_chars(18);

    copy_box.append(&title_label);
    copy_box.append(&status_label);
    copy_box.append(&badge_label);

    shell.append(&drawing_area);
    shell.append(&copy_box);
    window.set_child(Some(&shell));

    let aura_color: Rc<RefCell<(f64, f64, f64)>> =
        Rc::new(RefCell::new(aura_to_rgba(&initial_aura)));
    let was_dragged = Rc::new(RefCell::new(false));

    let color_ref = aura_color.clone();
    drawing_area.set_draw_func(move |_area, cr, width, height| {
        let (r, g, b) = *color_ref.borrow();
        let cx = width as f64 / 2.0;
        let cy = height as f64 / 2.0;
        let radius = (width.min(height) as f64 / 2.0) - 4.0;

        cr.set_source_rgba(r, g, b, 0.25);
        cr.arc(cx, cy, radius + 3.0, 0.0, 2.0 * std::f64::consts::PI);
        let _ = cr.fill();

        cr.set_source_rgba(r, g, b, 0.9);
        cr.arc(cx, cy, radius, 0.0, 2.0 * std::f64::consts::PI);
        let _ = cr.fill();

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
    shell.add_controller(click);

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
    shell.add_controller(drag);

    let right_click = gtk::GestureClick::new();
    right_click.set_button(3);
    let url_clone2 = dashboard_url;
    right_click.connect_released(move |_, _, _, _| {
        let _ = std::process::Command::new("xdg-open")
            .arg(&url_clone2)
            .spawn();
    });
    shell.add_controller(right_click);

    enum WidgetMessage {
        State {
            aura: String,
            label: String,
            badge: String,
        },
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
            Ok(DaemonEvent::AxiStateChanged {
                ref state,
                ref aura,
                ref reason,
            }) => Some(WidgetMessage::State {
                aura: aura.clone(),
                label: pretty_state_label(state),
                badge: reason
                    .clone()
                    .filter(|value| !value.trim().is_empty())
                    .unwrap_or_else(|| "LifeOS AI Core".to_string()),
            }),
            Ok(DaemonEvent::FeedbackUpdate { ref stage, .. }) => {
                stage.as_ref().map(|value| WidgetMessage::State {
                    aura: "yellow".to_string(),
                    label: "Procesando".to_string(),
                    badge: value.clone(),
                })
            }
            Ok(DaemonEvent::Notification {
                ref priority,
                ref message,
            }) => Some(WidgetMessage::State {
                aura: if priority.eq_ignore_ascii_case("critical")
                    || priority.eq_ignore_ascii_case("error")
                {
                    "red".to_string()
                } else {
                    "teal".to_string()
                },
                label: "Axi aviso".to_string(),
                badge: message.clone(),
            }),
            Ok(DaemonEvent::SensorChanged {
                kill_switch: true, ..
            }) => Some(WidgetMessage::State {
                aura: "gray".to_string(),
                label: "Privacidad".to_string(),
                badge: "Kill switch activo".to_string(),
            }),
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

    let color_for_poll = aura_color;
    let da = drawing_area;
    let widget_window = window.clone();
    let widget_status = status_label.clone();
    let widget_badge = badge_label.clone();
    glib::timeout_add_local(std::time::Duration::from_millis(200), move || {
        let mut redraw = false;
        while let Ok(message) = mpsc_rx.try_recv() {
            match message {
                WidgetMessage::State { aura, label, badge } => {
                    *color_for_poll.borrow_mut() = aura_to_rgba(&aura);
                    widget_status.set_text(&label);
                    widget_badge.set_text(&badge);
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
