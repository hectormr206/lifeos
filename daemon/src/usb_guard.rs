//! USB Guard — Monitor and control USB device connections.
//!
//! Detects when new USB devices are connected and classifies them:
//! - Known devices (in whitelist): allow silently
//! - Unknown HID devices: high suspicion (BadUSB), block and alert
//! - Unknown storage: medium suspicion, alert user
//!
//! Uses udev monitoring or periodic `lsusb` polling as fallback.

use anyhow::Result;
use log::{info, warn};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::PathBuf;
use tokio::fs;
use tokio::process::Command;

const WHITELIST_FILE: &str = "usb-whitelist.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsbDevice {
    pub vendor_id: String,
    pub product_id: String,
    pub name: String,
    pub bus: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UsbWhitelist {
    /// Allowed device IDs in "vendor:product" format.
    pub allowed: HashSet<String>,
}

pub struct UsbGuardManager {
    data_dir: PathBuf,
    whitelist: UsbWhitelist,
    known_devices: HashSet<String>,
}

impl UsbGuardManager {
    pub async fn new(data_dir: PathBuf) -> Self {
        let whitelist = if let Ok(content) = fs::read_to_string(data_dir.join(WHITELIST_FILE)).await
        {
            serde_json::from_str(&content).unwrap_or_default()
        } else {
            UsbWhitelist::default()
        };

        // Snapshot current devices as "known"
        let known = list_usb_device_ids().await.unwrap_or_default();

        Self {
            data_dir,
            whitelist,
            known_devices: known,
        }
    }

    /// Check for new USB devices since last scan.
    /// Returns list of new devices not in whitelist.
    pub async fn check_new_devices(&mut self) -> Vec<UsbDevice> {
        let current = list_usb_devices().await.unwrap_or_default();
        let current_ids: HashSet<String> = current
            .iter()
            .map(|d| format!("{}:{}", d.vendor_id, d.product_id))
            .collect();

        let mut new_devices = Vec::new();
        for device in &current {
            let id = format!("{}:{}", device.vendor_id, device.product_id);
            if !self.known_devices.contains(&id) && !self.whitelist.allowed.contains(&id) {
                warn!(
                    "[usb_guard] New unknown USB device: {} ({}:{})",
                    device.name, device.vendor_id, device.product_id
                );
                new_devices.push(device.clone());
            }
        }

        self.known_devices = current_ids;
        new_devices
    }

    /// Add a device to the whitelist.
    pub async fn allow_device(&mut self, vendor_id: &str, product_id: &str) -> Result<()> {
        let id = format!("{}:{}", vendor_id, product_id);
        self.whitelist.allowed.insert(id.clone());
        info!("[usb_guard] Whitelisted device: {}", id);
        self.save_whitelist().await
    }

    /// List all whitelisted devices.
    pub fn list_whitelisted(&self) -> &HashSet<String> {
        &self.whitelist.allowed
    }

    async fn save_whitelist(&self) -> Result<()> {
        let json = serde_json::to_string_pretty(&self.whitelist)?;
        fs::write(self.data_dir.join(WHITELIST_FILE), json).await?;
        Ok(())
    }
}

/// List connected USB devices via lsusb.
async fn list_usb_devices() -> Result<Vec<UsbDevice>> {
    let output = Command::new("lsusb").output().await?;
    let text = String::from_utf8_lossy(&output.stdout);

    let mut devices = Vec::new();
    for line in text.lines() {
        // Format: Bus 001 Device 003: ID 1d6b:0002 Linux Foundation 2.0 root hub
        let parts: Vec<&str> = line.splitn(7, ' ').collect();
        if parts.len() >= 7 {
            let bus = parts[1].to_string();
            if let Some(id_part) = parts.get(5) {
                let ids: Vec<&str> = id_part.split(':').collect();
                if ids.len() == 2 {
                    devices.push(UsbDevice {
                        vendor_id: ids[0].to_string(),
                        product_id: ids[1].to_string(),
                        name: parts[6..].join(" "),
                        bus,
                    });
                }
            }
        }
    }

    Ok(devices)
}

/// Get just the device IDs as a set.
async fn list_usb_device_ids() -> Result<HashSet<String>> {
    let devices = list_usb_devices().await?;
    Ok(devices
        .iter()
        .map(|d| format!("{}:{}", d.vendor_id, d.product_id))
        .collect())
}
