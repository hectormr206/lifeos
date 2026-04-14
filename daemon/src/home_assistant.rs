//! Home Assistant integration for LifeOS daemon.
//!
//! Provides a REST API client for Home Assistant, supporting entity state queries,
//! service calls, area listing, automation triggering, and real-time SSE event
//! streaming. A basic natural-language command parser (Spanish/English keywords)
//! is also included for voice/chat command dispatch.
//!
//! Feature-gated: compile with `--features homeassistant`.

#[cfg(feature = "homeassistant")]
#[allow(dead_code)]
pub mod homeassistant {
    use log::{error, info, warn};
    use reqwest::{Client, StatusCode};
    use serde::{Deserialize, Serialize};
    use std::time::Duration;
    use tokio::sync::mpsc;

    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    /// Runtime configuration loaded from environment variables.
    #[derive(Debug, Clone)]
    pub struct HomeAssistantConfig {
        /// Base URL, e.g. `http://homeassistant.local:8123`
        pub url: String,
        /// Long-lived access token
        pub token: String,
        /// HTTP request timeout (default: 10 s)
        pub timeout: Duration,
    }

    impl HomeAssistantConfig {
        /// Load config from environment variables.
        ///
        /// Required vars:
        /// - `LIFEOS_HA_URL`  — base URL of the HA instance
        /// - `LIFEOS_HA_TOKEN` — long-lived access token
        ///
        /// Returns `None` if either required variable is missing or empty.
        pub fn from_env() -> Option<Self> {
            let url = std::env::var("LIFEOS_HA_URL")
                .ok()
                .filter(|s| !s.is_empty())?;
            let token = std::env::var("LIFEOS_HA_TOKEN")
                .ok()
                .filter(|s| !s.is_empty())?;

            // Strip trailing slash so we can always append paths with `/`
            let url = url.trim_end_matches('/').to_string();

            Some(Self {
                url,
                token,
                timeout: Duration::from_secs(10),
            })
        }
    }

    // -------------------------------------------------------------------------
    // Data types
    // -------------------------------------------------------------------------

    /// A Home Assistant entity with its current state and attributes.
    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct HaEntity {
        pub entity_id: String,
        pub state: String,
        /// Free-form attributes blob (brightness, temperature, friendly_name, …)
        pub attributes: serde_json::Value,
        pub last_changed: String,
        pub last_updated: String,
    }

    /// Payload for a Home Assistant service call.
    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct HaServiceCall {
        pub domain: String,
        pub service: String,
        /// Target entity ID (optional — some services operate on an area/group)
        pub entity_id: Option<String>,
        /// Additional service data (e.g. `{"temperature": 22}`)
        pub data: Option<serde_json::Value>,
    }

    impl HaServiceCall {
        /// Construct a minimal service call targeting a single entity.
        pub fn for_entity(
            domain: impl Into<String>,
            service: impl Into<String>,
            entity_id: impl Into<String>,
        ) -> Self {
            Self {
                domain: domain.into(),
                service: service.into(),
                entity_id: Some(entity_id.into()),
                data: None,
            }
        }

        /// Attach extra service data to this call.
        pub fn with_data(mut self, data: serde_json::Value) -> Self {
            self.data = Some(data);
            self
        }
    }

    /// A Home Assistant area (room / zone).
    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct HaArea {
        pub area_id: String,
        pub name: String,
        #[serde(default)]
        pub aliases: Vec<String>,
    }

    /// A single event received through the SSE stream.
    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct HaEvent {
        pub event_type: String,
        pub data: serde_json::Value,
        pub origin: Option<String>,
        pub time_fired: Option<String>,
    }

    // Internal response wrapper for the /api/areas endpoint.
    #[derive(Debug, Deserialize)]
    struct HaAreaListResponse {
        #[serde(default)]
        result: Vec<HaArea>,
    }

    // -------------------------------------------------------------------------
    // Manager
    // -------------------------------------------------------------------------

    /// High-level client for the Home Assistant REST API.
    pub struct HomeAssistantManager {
        config: HomeAssistantConfig,
        client: Client,
    }

    impl HomeAssistantManager {
        /// Create a new manager with a shared `reqwest::Client`.
        pub fn new(config: HomeAssistantConfig) -> Self {
            let client = Client::builder()
                .timeout(config.timeout)
                .build()
                .expect("failed to build reqwest client for HomeAssistant");

            info!(
                "[HomeAssistant] manager initialised — base URL: {}",
                config.url
            );

            Self { config, client }
        }

        // ------------------------------------------------------------------
        // Internal helpers
        // ------------------------------------------------------------------

        fn base_url(&self) -> &str {
            &self.config.url
        }

        fn bearer(&self) -> String {
            format!("Bearer {}", self.config.token)
        }

        async fn get_json<T: for<'de> Deserialize<'de>>(&self, path: &str) -> Result<T, HaError> {
            let url = format!("{}{}", self.base_url(), path);
            let resp = self
                .client
                .get(&url)
                .header("Authorization", self.bearer())
                .header("Content-Type", "application/json")
                .send()
                .await
                .map_err(HaError::Http)?;

            let status = resp.status();
            if !status.is_success() {
                let body = resp.text().await.unwrap_or_default();
                warn!("[HomeAssistant] GET {path} returned {status}: {body}");
                return Err(HaError::ApiError(status, body));
            }

            resp.json::<T>().await.map_err(HaError::Decode)
        }

        async fn post_json(
            &self,
            path: &str,
            body: &serde_json::Value,
        ) -> Result<serde_json::Value, HaError> {
            let url = format!("{}{}", self.base_url(), path);
            let resp = self
                .client
                .post(&url)
                .header("Authorization", self.bearer())
                .header("Content-Type", "application/json")
                .json(body)
                .send()
                .await
                .map_err(HaError::Http)?;

            let status = resp.status();
            if !status.is_success() {
                let body_text = resp.text().await.unwrap_or_default();
                warn!("[HomeAssistant] POST {path} returned {status}: {body_text}");
                return Err(HaError::ApiError(status, body_text));
            }

            resp.json::<serde_json::Value>()
                .await
                .map_err(HaError::Decode)
        }

        // ------------------------------------------------------------------
        // Public API
        // ------------------------------------------------------------------

        /// Fetch all entity states from `/api/states`.
        pub async fn get_states(&self) -> Result<Vec<HaEntity>, HaError> {
            info!("[HomeAssistant] fetching all states");
            self.get_json::<Vec<HaEntity>>("/api/states").await
        }

        /// Fetch a single entity state from `/api/states/{entity_id}`.
        pub async fn get_state(&self, entity_id: &str) -> Result<HaEntity, HaError> {
            info!("[HomeAssistant] fetching state for {entity_id}");
            let path = format!("/api/states/{entity_id}");
            self.get_json::<HaEntity>(&path).await
        }

        /// Call a Home Assistant service via `POST /api/services/{domain}/{service}`.
        ///
        /// `data` is merged with `entity_id` in the request body.
        pub async fn call_service(
            &self,
            domain: &str,
            service: &str,
            entity_id: Option<&str>,
            data: Option<serde_json::Value>,
        ) -> Result<serde_json::Value, HaError> {
            info!("[HomeAssistant] call_service {domain}.{service} entity={entity_id:?}");

            let mut body = data.unwrap_or_else(|| serde_json::json!({}));
            if let Some(eid) = entity_id {
                if let Some(obj) = body.as_object_mut() {
                    obj.insert(
                        "entity_id".to_string(),
                        serde_json::Value::String(eid.to_string()),
                    );
                }
            }

            let path = format!("/api/services/{domain}/{service}");
            self.post_json(&path, &body).await
        }

        /// Toggle an entity (on → off, off → on).
        pub async fn toggle(&self, entity_id: &str) -> Result<serde_json::Value, HaError> {
            info!("[HomeAssistant] toggle {entity_id}");
            let domain = domain_from_entity_id(entity_id);
            self.call_service(domain, "toggle", Some(entity_id), None)
                .await
        }

        /// Turn an entity on.
        pub async fn turn_on(&self, entity_id: &str) -> Result<serde_json::Value, HaError> {
            info!("[HomeAssistant] turn_on {entity_id}");
            let domain = domain_from_entity_id(entity_id);
            self.call_service(domain, "turn_on", Some(entity_id), None)
                .await
        }

        /// Turn an entity off.
        pub async fn turn_off(&self, entity_id: &str) -> Result<serde_json::Value, HaError> {
            info!("[HomeAssistant] turn_off {entity_id}");
            let domain = domain_from_entity_id(entity_id);
            self.call_service(domain, "turn_off", Some(entity_id), None)
                .await
        }

        /// Set target temperature on a `climate` entity.
        pub async fn set_temperature(
            &self,
            entity_id: &str,
            temperature: f64,
        ) -> Result<serde_json::Value, HaError> {
            info!("[HomeAssistant] set_temperature {entity_id} → {temperature}");
            let data = serde_json::json!({ "temperature": temperature });
            self.call_service("climate", "set_temperature", Some(entity_id), Some(data))
                .await
        }

        /// List all areas via the WebSocket-based areas list endpoint.
        ///
        /// Home Assistant exposes areas through the config endpoint; we parse
        /// the `/api/config` response to extract area information when the
        /// dedicated areas REST endpoint is unavailable.
        pub async fn get_areas(&self) -> Result<Vec<HaArea>, HaError> {
            info!("[HomeAssistant] fetching areas");
            // HA 2023.x+ exposes areas via /api/config/area_registry/list
            match self
                .get_json::<Vec<HaArea>>("/api/config/area_registry/list")
                .await
            {
                Ok(areas) => Ok(areas),
                Err(e) => {
                    warn!(
                        "[HomeAssistant] area_registry/list failed ({e:?}), falling back to /api/config"
                    );
                    // Fall back: parse areas from config blob
                    let config: serde_json::Value = self.get_json("/api/config").await?;
                    let areas = config
                        .get("areas")
                        .and_then(|v| serde_json::from_value(v.clone()).ok())
                        .unwrap_or_default();
                    Ok(areas)
                }
            }
        }

        /// Trigger an automation by calling `automation.trigger`.
        pub async fn trigger_automation(
            &self,
            automation_id: &str,
        ) -> Result<serde_json::Value, HaError> {
            info!("[HomeAssistant] trigger_automation {automation_id}");
            self.call_service("automation", "trigger", Some(automation_id), None)
                .await
        }

        /// Subscribe to the Home Assistant event stream (Server-Sent Events).
        ///
        /// Returns a `Receiver` channel. Events are decoded from the SSE stream
        /// and sent to the channel until the stream ends or an error occurs.
        ///
        /// The caller should spawn this in a background task.
        pub async fn listen_events(
            &self,
            event_type: Option<&str>,
        ) -> Result<mpsc::Receiver<HaEvent>, HaError> {
            let path = match event_type {
                Some(et) => format!("/api/stream?restrict={et}"),
                None => "/api/stream".to_string(),
            };
            let url = format!("{}{}", self.base_url(), path);
            info!("[HomeAssistant] subscribing to SSE stream at {url}");

            let response = self
                .client
                .get(&url)
                .header("Authorization", self.bearer())
                .header("Accept", "text/event-stream")
                .send()
                .await
                .map_err(HaError::Http)?;

            if !response.status().is_success() {
                let status = response.status();
                let body = response.text().await.unwrap_or_default();
                return Err(HaError::ApiError(status, body));
            }

            let (tx, rx) = mpsc::channel::<HaEvent>(128);

            tokio::spawn(async move {
                // Read entire SSE response body as text in chunks.
                // HA SSE uses long-lived HTTP — we read the full text which completes when the
                // connection closes, then parse all events at once. For a true streaming
                // implementation, reqwest `stream` feature + futures-util would be needed.
                let body = match response.text().await {
                    Ok(b) => b,
                    Err(e) => {
                        error!("[HomeAssistant] SSE read error: {e}");
                        return;
                    }
                };
                let mut buffer = body;

                // SSE messages are separated by double newlines
                while let Some(pos) = buffer.find("\n\n") {
                    let message = buffer[..pos].to_string();
                    buffer = buffer[pos + 2..].to_string();

                    let data_payload: String = message
                        .lines()
                        .filter(|l| l.starts_with("data:"))
                        .map(|l| l.trim_start_matches("data:").trim())
                        .collect::<Vec<_>>()
                        .join("");

                    if data_payload.is_empty() {
                        continue;
                    }

                    match serde_json::from_str::<HaEvent>(&data_payload) {
                        Ok(event) => {
                            if tx.send(event).await.is_err() {
                                return;
                            }
                        }
                        Err(e) => {
                            warn!(
                                "[HomeAssistant] failed to decode SSE event: {e} — payload: {data_payload}"
                            );
                        }
                    }
                }

                info!("[HomeAssistant] SSE stream ended");
            });

            Ok(rx)
        }
    }

    // -------------------------------------------------------------------------
    // Error type
    // -------------------------------------------------------------------------

    /// Errors that can occur when communicating with Home Assistant.
    #[derive(Debug)]
    pub enum HaError {
        /// HTTP transport error
        Http(reqwest::Error),
        /// API returned a non-2xx status
        ApiError(StatusCode, String),
        /// Response body could not be decoded
        Decode(reqwest::Error),
        /// Configuration is missing or invalid
        Config(String),
    }

    impl std::fmt::Display for HaError {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            match self {
                HaError::Http(e) => write!(f, "HTTP error: {e}"),
                HaError::ApiError(status, body) => {
                    write!(f, "API error {status}: {body}")
                }
                HaError::Decode(e) => write!(f, "decode error: {e}"),
                HaError::Config(msg) => write!(f, "config error: {msg}"),
            }
        }
    }

    impl std::error::Error for HaError {
        fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
            match self {
                HaError::Http(e) | HaError::Decode(e) => Some(e),
                _ => None,
            }
        }
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// Derive the HA domain from an entity_id such as `light.sala` → `"light"`.
    fn domain_from_entity_id(entity_id: &str) -> &str {
        entity_id.split('.').next().unwrap_or("homeassistant")
    }

    // -------------------------------------------------------------------------
    // Natural-language command parser (keyword-based, no LLM)
    // -------------------------------------------------------------------------

    /// Parse a plain-text command (Spanish or English) into a `HaServiceCall`.
    ///
    /// This is a simple keyword/pattern matcher — it does **not** use an LLM.
    /// It covers the most common smart-home commands spoken in Spanish.
    ///
    /// # Examples
    /// ```
    /// let cmd = parse_ha_command("enciende la luz de la sala");
    /// // → HaServiceCall { domain: "light", service: "turn_on", entity_id: Some("light.sala"), … }
    ///
    /// let cmd = parse_ha_command("apaga el ventilador del cuarto");
    /// // → HaServiceCall { domain: "fan", service: "turn_off", entity_id: Some("fan.ventilador_cuarto"), … }
    ///
    /// let cmd = parse_ha_command("pon el aire a 22 grados");
    /// // → HaServiceCall { domain: "climate", service: "set_temperature", data: {"temperature": 22}, … }
    /// ```
    pub fn parse_ha_command(text: &str) -> Option<HaServiceCall> {
        let lower = text.to_lowercase();
        let lower = lower.trim();

        // ---- Determine action -----------------------------------------------

        let action = if contains_any(lower, &["enciende", "prende", "activa", "turn on", "on"]) {
            "turn_on"
        } else if contains_any(lower, &["apaga", "desactiva", "turn off", "off"]) {
            "turn_off"
        } else if contains_any(lower, &["cambia", "alterna", "toggle"]) {
            "toggle"
        } else if contains_any(
            lower,
            &[
                "temperatura",
                "grados",
                "degrees",
                "pon el aire",
                "set temperature",
                "ajusta",
            ],
        ) {
            "set_temperature"
        } else if contains_any(
            lower,
            &["activa automatización", "run automation", "ejecuta"],
        ) {
            "trigger_automation"
        } else {
            return None;
        };

        // ---- Temperature command ---------------------------------------------

        if action == "set_temperature" {
            let temp = extract_number(lower)?;
            let entity_id = find_climate_entity(lower)
                .unwrap_or_else(|| "climate.aire_acondicionado".to_string());
            return Some(HaServiceCall {
                domain: "climate".to_string(),
                service: "set_temperature".to_string(),
                entity_id: Some(entity_id),
                data: Some(serde_json::json!({ "temperature": temp })),
            });
        }

        // ---- Automation trigger ---------------------------------------------

        if action == "trigger_automation" {
            let automation_id =
                find_automation_id(lower).unwrap_or_else(|| "automation.default".to_string());
            return Some(HaServiceCall {
                domain: "automation".to_string(),
                service: "trigger".to_string(),
                entity_id: Some(automation_id),
                data: None,
            });
        }

        // ---- Device type and location ---------------------------------------

        let (domain, entity_prefix) = classify_device(lower);
        let location = extract_location(lower);

        let entity_id = match location {
            Some(loc) => format!("{entity_prefix}.{loc}"),
            None => format!("{entity_prefix}.principal"),
        };

        Some(HaServiceCall {
            domain: domain.to_string(),
            service: action.to_string(),
            entity_id: Some(entity_id),
            data: None,
        })
    }

    // --- Parser helpers -------------------------------------------------------

    fn contains_any(text: &str, keywords: &[&str]) -> bool {
        keywords.iter().any(|kw| text.contains(kw))
    }

    /// Classify the device mentioned in the command.
    /// Returns (domain, entity_id_prefix).
    fn classify_device(text: &str) -> (&'static str, &'static str) {
        if contains_any(
            text,
            &["luz", "luces", "foco", "lampara", "light", "lámpara"],
        ) {
            ("light", "light")
        } else if contains_any(text, &["ventilador", "fan"]) {
            ("fan", "fan")
        } else if contains_any(
            text,
            &[
                "aire",
                "clima",
                "ac",
                "climate",
                "calefactor",
                "calefacción",
            ],
        ) {
            ("climate", "climate")
        } else if contains_any(
            text,
            &["enchufe", "tomacorriente", "switch", "plug", "outlet"],
        ) {
            ("switch", "switch")
        } else if contains_any(text, &["cortina", "persiana", "cover", "blind", "roller"]) {
            ("cover", "cover")
        } else if contains_any(text, &["alarma", "alarm", "seguridad"]) {
            ("alarm_control_panel", "alarm_control_panel")
        } else if contains_any(text, &["cerradura", "puerta", "lock", "door"]) {
            ("lock", "lock")
        } else if contains_any(
            text,
            &[
                "tv",
                "televisión",
                "television",
                "media",
                "altavoz",
                "speaker",
            ],
        ) {
            ("media_player", "media_player")
        } else {
            ("homeassistant", "homeassistant")
        }
    }

    /// Extract a room/area name and return a sanitised slug.
    fn extract_location(text: &str) -> Option<String> {
        // Common room keywords → canonical slug
        let rooms: &[(&[&str], &str)] = &[
            (&["sala", "living", "sala de estar"], "sala"),
            (
                &["cuarto", "habitación", "dormitorio", "bedroom", "recámara"],
                "cuarto",
            ),
            (&["cocina", "kitchen"], "cocina"),
            (&["baño", "bathroom", "aseo"], "bano"),
            (&["garage", "garaje", "cochera"], "garage"),
            (
                &["jardín", "jardin", "patio", "garden", "exterior"],
                "jardin",
            ),
            (&["oficina", "office", "despacho", "estudio"], "oficina"),
            (&["pasillo", "hallway", "corridor"], "pasillo"),
            (&["comedor", "dining"], "comedor"),
        ];

        for (keywords, slug) in rooms {
            if keywords.iter().any(|kw| text.contains(kw)) {
                return Some(slug.to_string());
            }
        }

        None
    }

    /// Extract the first integer/float from a string.
    fn extract_number(text: &str) -> Option<f64> {
        // Find a sequence of digits (optionally followed by . or ,)
        let mut num_str = String::new();
        let mut found = false;
        for ch in text.chars() {
            if ch.is_ascii_digit() {
                num_str.push(ch);
                found = true;
            } else if found && (ch == '.' || ch == ',') {
                num_str.push('.');
            } else if found {
                break;
            }
        }
        num_str.parse::<f64>().ok()
    }

    /// Guess the climate entity from context.
    fn find_climate_entity(text: &str) -> Option<String> {
        let location = extract_location(text)?;
        Some(format!("climate.{location}"))
    }

    /// Guess the automation entity ID from context.
    fn find_automation_id(text: &str) -> Option<String> {
        // Look for quoted identifiers or well-known automation names
        if text.contains("noche") || text.contains("night") {
            return Some("automation.modo_noche".to_string());
        }
        if text.contains("llegada") || text.contains("llegue") || text.contains("arrive") {
            return Some("automation.llegada_a_casa".to_string());
        }
        if text.contains("salida") || text.contains("salir") || text.contains("leave") {
            return Some("automation.salida_de_casa".to_string());
        }
        if text.contains("mañana") || text.contains("morning") {
            return Some("automation.rutina_manana".to_string());
        }
        None
    }

    // -------------------------------------------------------------------------
    // Tests
    // -------------------------------------------------------------------------

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn test_parse_turn_on_light() {
            let cmd = parse_ha_command("enciende la luz de la sala").unwrap();
            assert_eq!(cmd.domain, "light");
            assert_eq!(cmd.service, "turn_on");
            assert_eq!(cmd.entity_id.as_deref(), Some("light.sala"));
        }

        #[test]
        fn test_parse_turn_off_fan() {
            let cmd = parse_ha_command("apaga el ventilador del cuarto").unwrap();
            assert_eq!(cmd.domain, "fan");
            assert_eq!(cmd.service, "turn_off");
            assert_eq!(cmd.entity_id.as_deref(), Some("fan.cuarto"));
        }

        #[test]
        fn test_parse_set_temperature() {
            let cmd = parse_ha_command("pon el aire a 22 grados").unwrap();
            assert_eq!(cmd.domain, "climate");
            assert_eq!(cmd.service, "set_temperature");
            let data = cmd.data.as_ref().unwrap();
            assert_eq!(data["temperature"], serde_json::json!(22.0));
        }

        #[test]
        fn test_parse_temperature_with_room() {
            let cmd = parse_ha_command("ajusta la temperatura del cuarto a 18 grados").unwrap();
            assert_eq!(cmd.domain, "climate");
            assert_eq!(cmd.service, "set_temperature");
            assert_eq!(cmd.entity_id.as_deref(), Some("climate.cuarto"));
        }

        #[test]
        fn test_parse_toggle() {
            let cmd = parse_ha_command("alterna el enchufe de la cocina").unwrap();
            assert_eq!(cmd.domain, "switch");
            assert_eq!(cmd.service, "toggle");
            assert_eq!(cmd.entity_id.as_deref(), Some("switch.cocina"));
        }

        #[test]
        fn test_parse_unknown_returns_none() {
            assert!(parse_ha_command("cuanto mide el puente golden gate").is_none());
        }

        #[test]
        fn test_domain_from_entity_id() {
            assert_eq!(domain_from_entity_id("light.sala"), "light");
            assert_eq!(domain_from_entity_id("climate.cuarto"), "climate");
            assert_eq!(domain_from_entity_id("no_dot"), "no_dot");
        }

        #[test]
        fn test_extract_number() {
            assert_eq!(extract_number("22 grados"), Some(22.0));
            assert_eq!(extract_number("temperatura 18.5 C"), Some(18.5));
            assert_eq!(extract_number("sin número aquí"), None);
        }

        #[test]
        fn test_ha_service_call_builder() {
            let call = HaServiceCall::for_entity("light", "turn_on", "light.sala")
                .with_data(serde_json::json!({"brightness": 255}));
            assert_eq!(call.entity_id.as_deref(), Some("light.sala"));
            let data = call.data.as_ref().unwrap();
            assert_eq!(data["brightness"], 255);
        }

        #[test]
        fn test_config_from_env_missing() {
            // Ensure missing vars return None without panicking
            std::env::remove_var("LIFEOS_HA_URL");
            std::env::remove_var("LIFEOS_HA_TOKEN");
            assert!(HomeAssistantConfig::from_env().is_none());
        }
    }
}
