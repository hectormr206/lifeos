//! ASCII Art module for LifeOS CLI
//!
//! This module provides ASCII art assets for CLI output,
//! including Axi the Axolotl easter eggs and system state visualizations.

pub mod axi;

pub use axi::{get_random_fact, get_random_quote, AXI_ASCII, AXI_MINI};
