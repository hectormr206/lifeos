//! ASCII Art module for Axi the Axolotl easter eggs
//!
//! Provides ASCII art representations of Axi for CLI output and easter eggs.

/// ASCII art of Axi the Axolotl
pub const AXI_ASCII: &str = r#"
    ╭━━━━━━━━━━━━━━╮
   ╭┃  ◕    ◕   ┃╮
   ╰┃     ▽      ┃╯
    ╰┳━━━━━━━━━━┳╯
   ╭━┫  ││││││  ┣━╮
   │  ╰━━━━━━━━━━╯  │
   ╰━━━━┳━━━━┳━━━━╯
        ╰────╯
"#;

/// Mini ASCII art of Axi (compact version)
pub const AXI_MINI: &str = r#"
   ╭━━━━╮
  ╭┃◕  ◕┃╮
  ╰┃ ▽  ┃╯
   ╰┳━━┳╯
    ╰──╯
"#;

/// Sleeping Axi (offline state)
#[allow(dead_code)]
pub const AXI_SLEEPING: &str = r#"
    ╭━━━━━━━━━━━━━━╮
   ╭┃  -    -    ┃╮   Z z z
   ╰┃     ≈      ┃╯
    ╰┳━━━━━━━━━━┳╯
   ╭━┫  ││││││  ┣━╮
   │  ╰━━━━━━━━━━╯  │
   ╰━━━━┳━━━━┳━━━━╯
        ╰────╯
"#;

/// Updating Axi (with helmet)
#[allow(dead_code)]
pub const AXI_UPDATING: &str = r#"
     ▄▄▄▄▄▄▄▄▄▄▄▄
    ╭━━━━━━━━━━━━━━╮
   ╭┃  ◕    ◕   ┃╮
   ╰┃     ⌣      ┃╯
    ╰┳━━━━━━━━━━┳╯
   ╭━┫  ││││││  ┣━╮
   │  ╰━━━━━━━━━━╯  │
   ╰━━━━┳━━━━┳━━━━╯
        ╰────╯
"#;

/// Error Axi (worried)
#[allow(dead_code)]
pub const AXI_WORRIED: &str = r#"
    ╭━━━━━━━━━━━━━━╮
   ╭┃  ◕︵  ◕   ┃╮  💧
   ╰┃     ω      ┃╯
    ╰┳━━━━━━━━━━┳╯
   ╭━┫  ││││││  ┣━╮
   │  ╰━━━━━━━━━━╯  │
   ╰━━━━┳━━━━┳━━━━╯
        ╰────╯
"#;

/// Autonomy Axi (with glasses)
#[allow(dead_code)]
pub const AXI_AUTONOMY: &str = r#"
    ╭━━━━━━━━━━━━━━╮
   ╭┃ ▣    ▣    ┃╮
   ╰┃     ⌣      ┃╯
    ╰┳━━━━━━━━━━┳╯
   ╭━┫  ││││││  ┣━╮
   │  ╰━━━━━━━━━━╯  │
   ╰━━━━┳━━━━┳━━━━╯
        ╰────╯
"#;

/// Focus Axi (with headphones)
#[allow(dead_code)]
pub const AXI_FOCUS: &str = r#"
   ▄▀        ▀▄
  █  ╭━━━━━━╮  █
  █ ╭┃◕    ◕┃╮ █
  █ ╰┃  ─   ┃╯ █
  █  ╰┳━━━━┳╯  █
   █ ╭┫││││┣╮ █
    ╰┻━━━━┻╯
"#;

/// Motivational messages from Axi
pub const AXI_QUOTES: &[&str] = &[
    "Every rollback is a new beginning!",
    "Regeneration is my superpower. Resilience is yours.",
    "In the depths of Xochimilco, we never give up!",
    "Sometimes you need to sleep to dream better solutions.",
    "I may be an axolotl, but I'm always evolving.",
    "Systems heal. So do you. Take your time.",
    "The best updates are the ones you don't notice.",
    "Stay curious, stay regenerative!",
    "Error 404: Sadness not found. Let's fix this!",
    "Remember: even I need to hibernate sometimes.",
    "Focus mode activated. Distractions deactivated.",
    "Your data is safe with me. I'm very good at keeping secrets in my gills.",
    "Life is better with a permanent smile!",
    "Rolling back doesn't mean going backwards—it means getting back to what works.",
    "I'm not just a mascot, I'm your system's best friend!",
];

/// Fun facts about axolotls
pub const AXI_FACTS: &[&str] = &[
    "🦎 Axolotls can regenerate their brain. LifeOS can regenerate your system. Coincidence?",
    "🦎 Real axolotls are native to Lake Xochimilco in Mexico City!",
    "🦎 Axolotls can regrow entire limbs, spinal cords, and even parts of their hearts.",
    "🦎 Unlike most salamanders, axolotls stay in their aquatic larval form forever—just like LifeOS stays fresh!",
    "🦎 Axolotls have external gills that look like antenas—they're basically alien technology!",
    "🦎 An axolotl's smile is permanent. Just like LifeOS's commitment to not breaking your system.",
    "🦎 Axolotls can regenerate the same limb up to 5 times with no scarring. LifeOS: infinite rollbacks.",
    "🦎 The word 'axolotl' comes from Aztec Nahuatl, meaning 'water dog' or 'water monster'.",
    "🦎 Axolotls are studied by scientists for their incredible regenerative abilities—just like LifeOS developers study resilient systems!",
    "🦎 Wild axolotls are critically endangered. Captive ones thrive—just like LifeOS in your care!",
    "🦎 Axolotls have almost 10x larger genomes than humans. More data, more power!",
    "🦎 Unlike other salamanders, axolotls never undergo metamorphosis. LifeOS: no breaking changes!",
    "🦎 Axolotls were sacred to the Aztec god Xolotl, who disguised himself as the creature to avoid sacrifice.",
    "🦎 An axolotl can go weeks without eating. LifeOS can go weeks without needing attention!",
    "🦎 Axolotls have tiny, nearly invisible teeth. They're gentle—just like our update process!",
];

/// Get a random motivational quote from Axi
pub fn get_random_quote() -> &'static str {
    AXI_QUOTES[fastrand::usize(..AXI_QUOTES.len())]
}

/// Get a random fun fact about axolotls
pub fn get_random_fact() -> &'static str {
    AXI_FACTS[fastrand::usize(..AXI_FACTS.len())]
}

/// Get ASCII art for a specific system state
#[allow(dead_code)]
pub fn get_ascii_for_state(state: AxiState) -> &'static str {
    match state {
        AxiState::Healthy => AXI_ASCII,
        AxiState::Updating => AXI_UPDATING,
        AxiState::Offline => AXI_SLEEPING,
        AxiState::Error => AXI_WORRIED,
        AxiState::Autonomy => AXI_AUTONOMY,
        AxiState::Focus => AXI_FOCUS,
        AxiState::Mini => AXI_MINI,
    }
}

/// Axi system states for ASCII art
#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AxiState {
    /// Normal healthy state
    Healthy,
    /// System updating
    Updating,
    /// System offline/sleeping
    Offline,
    /// Error state
    Error,
    /// Autonomy/Intelligence mode
    Autonomy,
    /// Focus/Flow mode
    Focus,
    /// Compact mini version
    Mini,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_random_quote() {
        let quote = get_random_quote();
        assert!(!quote.is_empty());
        assert!(AXI_QUOTES.contains(&quote));
    }

    #[test]
    fn test_get_random_fact() {
        let fact = get_random_fact();
        assert!(!fact.is_empty());
        assert!(AXI_FACTS.contains(&fact));
    }

    #[test]
    fn test_get_ascii_for_state() {
        assert!(!get_ascii_for_state(AxiState::Healthy).is_empty());
        assert!(!get_ascii_for_state(AxiState::Updating).is_empty());
        assert!(!get_ascii_for_state(AxiState::Offline).is_empty());
        assert!(!get_ascii_for_state(AxiState::Error).is_empty());
        assert!(!get_ascii_for_state(AxiState::Autonomy).is_empty());
        assert!(!get_ascii_for_state(AxiState::Focus).is_empty());
        assert!(!get_ascii_for_state(AxiState::Mini).is_empty());
    }

    #[test]
    fn test_axi_quotes_not_empty() {
        for quote in AXI_QUOTES {
            assert!(!quote.is_empty());
        }
    }

    #[test]
    fn test_axi_facts_not_empty() {
        for fact in AXI_FACTS {
            assert!(!fact.is_empty());
        }
    }
}
