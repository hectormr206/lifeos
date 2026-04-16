//! systemd-logind PrepareForSleep watcher.
//!
//! Subscribes to `org.freedesktop.login1.Manager.PrepareForSleep` on the
//! system bus and toggles the sensory pipeline's `suspending` flag so
//! camera/screen captures are skipped across a suspend/hibernate cycle.
//! On resume (signal arg = false) it also triggers a capability refresh
//! so the next cycle re-probes `/dev/video*` after the kernel has
//! re-initialised USB peripherals.
//!
//! Closes Fase C #W13 of the camera audit.

use std::sync::Arc;

use anyhow::{Context, Result};
use futures_util::stream::StreamExt;
use zbus::Connection;

use crate::ai::AiManager;
use crate::sensory_pipeline::SensoryPipelineManager;

const LOGIN1_SERVICE: &str = "org.freedesktop.login1";
const LOGIN1_PATH: &str = "/org/freedesktop/login1";
const LOGIN1_IFACE: &str = "org.freedesktop.login1.Manager";

/// Spawn-friendly loop. Returns `Err` only if the initial system-bus
/// connection fails; transient signal stream errors are logged and the
/// loop continues.
pub async fn watch_prepare_for_sleep(
    sensory: Arc<tokio::sync::RwLock<SensoryPipelineManager>>,
    ai_manager: Arc<tokio::sync::RwLock<AiManager>>,
) -> Result<()> {
    let connection = Connection::system()
        .await
        .context("Failed to open system dbus connection for PrepareForSleep")?;

    let proxy = zbus::fdo::DBusProxy::new(&connection)
        .await
        .context("Failed to create DBus fdo proxy")?;

    // Filter to the specific signal we care about — keeps the stream
    // narrow and avoids re-matching on every arbitrary system bus event.
    let rule = zbus::MatchRule::builder()
        .msg_type(zbus::MessageType::Signal)
        .sender(LOGIN1_SERVICE)
        .context("Invalid login1 service name")?
        .path(LOGIN1_PATH)
        .context("Invalid login1 path")?
        .interface(LOGIN1_IFACE)
        .context("Invalid login1 interface")?
        .member("PrepareForSleep")
        .context("Invalid PrepareForSleep member")?
        .build();
    proxy
        .add_match_rule(rule)
        .await
        .context("Failed to install PrepareForSleep match rule")?;

    let mut stream = zbus::MessageStream::from(&connection);
    log::info!("[sleep-watch] listening for PrepareForSleep on system bus");

    while let Some(msg) = stream.next().await {
        let msg = match msg {
            Ok(m) => m,
            Err(err) => {
                log::warn!("[sleep-watch] message stream error: {}", err);
                continue;
            }
        };
        let header = msg.header();
        let iface = header.interface().map(|i| i.as_str()).unwrap_or("");
        let member = header.member().map(|m| m.as_str()).unwrap_or("");
        if iface != LOGIN1_IFACE || member != "PrepareForSleep" {
            continue;
        }

        // Signal body: `b` (boolean). true = about to sleep, false = resumed.
        let body = msg.body();
        let suspending: bool = match body.deserialize() {
            Ok(v) => v,
            Err(err) => {
                log::warn!(
                    "[sleep-watch] could not decode PrepareForSleep body: {}",
                    err
                );
                continue;
            }
        };

        {
            let mgr = sensory.read().await;
            mgr.set_suspending(suspending);
        }

        if suspending {
            log::info!("[sleep-watch] system suspending — camera captures paused");
        } else {
            log::info!("[sleep-watch] system resumed — refreshing sensory capabilities");
            // Re-probe devices / binaries after resume: USB stack may
            // have re-numbered /dev/video* and capture binaries may
            // have been killed during suspend.
            let ai_guard = *ai_manager.read().await;
            let mgr = sensory.read().await.clone();
            if let Err(err) = mgr.refresh_capabilities(&ai_guard).await {
                log::warn!(
                    "[sleep-watch] capability refresh after resume failed: {}",
                    err
                );
            }
        }
    }

    Ok(())
}
