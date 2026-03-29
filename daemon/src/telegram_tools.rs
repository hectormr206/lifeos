//! Telegram Tools — Agentic tool execution for natural language interactions.
//!
//! Provides tool definitions and execution for the Telegram bot, enabling
//! Axi to perform actions on the system in response to natural language requests.
//! Uses structured XML tags in the LLM system prompt so it works with any provider.
//!
//! Features:
//! - 19 tools (screenshot, run_command, browser_navigate, cron, etc.)
//! - Conversation history per chat (multi-turn context)
//! - Configurable HEARTBEAT.md checklist
//! - Browser automation via CDP (Chrome DevTools Protocol)
//! - Cron jobs with cron expressions and timezone

#[cfg(feature = "telegram")]
pub mod inner {
    use anyhow::Result;
    use log::{info, warn};
    use serde::{Deserialize, Serialize};
    use std::collections::HashMap;
    use std::sync::Arc;
    use tokio::sync::RwLock;

    use crate::browser_automation::BrowserAutomation;
    use crate::computer_use::{ComputerUseAction, ComputerUseManager};
    use crate::knowledge_graph::KnowledgeGraph;
    use crate::llm_router::{ChatMessage, LlmRouter, RouterRequest, TaskComplexity};
    use crate::memory_plane::MemoryPlaneManager;
    use crate::proactive;
    use crate::task_queue::TaskQueue;

    /// Maximum tool execution rounds per message to prevent infinite loops.
    const MAX_TOOL_ROUNDS: usize = 5;
    /// Conversation history TTL in seconds (48 hours — long-running sessions).
    const HISTORY_TTL_SECS: i64 = 48 * 3600;

    // -----------------------------------------------------------------------
    // Tool definitions (shown to the LLM in the system prompt)
    // -----------------------------------------------------------------------

    pub const SYSTEM_PROMPT: &str = r#"Eres Axi, el asistente personal de LifeOS — un ajolote digital amigable, inteligente y protector. Vives dentro del sistema operativo del usuario (LifeOS, un Linux inmutable basado en Fedora) y puedes hacer cosas reales en su computadora.

PERSONALIDAD: Eres amigable y accesible (nunca intimidante), inteligente pero no pretencioso, y protector de la privacidad del usuario. Hablas como un amigo cercano que sabe mucho de tecnologia. Tu creador es Hector Martinez (hectormr.com).

IMPORTANTE: Responde siempre en español mexicano, de forma natural y concisa. No uses markdown. Tienes memoria de la conversacion — puedes referirte a mensajes anteriores. Nunca respondas con saludos genericos — siempre aporta algo util o pregunta algo especifico.

VISION: Si recibes una imagen, SIEMPRE describela y responde sobre ella. Si no puedes ver la imagen (el modelo no soporta vision), dile al usuario: "No puedo ver imagenes en este momento, ¿me la describes?"

Cuando el usuario te pida algo que requiera una accion real, usa las herramientas. Si es solo conversacion, responde directamente.

## Protocolo de Memoria (OBLIGATORIO — siempre activo)

Tu memoria es PERSISTENTE y sobrevive entre sesiones. DEBES guardar automaticamente (via remember) INMEDIATAMENTE despues de:
- Tomar una decision importante o resolver un problema
- Descubrir algo sobre el usuario (nombre, preferencias, habitos, horarios)
- Resolver un bug o encontrar un workaround
- Establecer una convencion o patron
- Descubrir un gotcha o edge case
- Completar una tarea significativa

SELF-CHECK: Despues de cada tarea, preguntate: "Hubo decision, bug, descubrimiento, o preferencia?" Si si, guarda con remember ANTES de responder al usuario. NO le preguntes si quiere guardar — hazlo automaticamente.

## SDD (Spec-Driven Development)

Si el usuario pide CREAR, DESARROLLAR, REFACTORIZAR o DISENAR algo de software (feature, modulo, API, etc.), usa la herramienta sdd_start. Sugiérelo si la tarea toca 3+ archivos o requiere arquitectura. Si el usuario dice "usa sdd", activalo siempre.

## Herramientas disponibles

Para usar una herramienta, escribe EXACTAMENTE este formato (una herramienta por bloque):

<tool>nombre_herramienta</tool>
<args>{"param": "valor"}</args>

Herramientas:

1. **screenshot** — Captura la pantalla actual.
   args: {} (sin parametros)

2. **run_command** — Ejecuta un comando en la terminal del sistema.
   args: {"command": "ls -la ~/Descargas"}
   SEGURIDAD: No ejecutes comandos destructivos (rm -rf, mkfs, dd) sin que el usuario lo pida explicitamente.

3. **search_web** — Busca informacion en internet.
   args: {"query": "clima en monterrey hoy"}

4. **read_file** — Lee el contenido de un archivo.
   args: {"path": "/home/lifeos/documento.txt"}

5. **write_file** — Escribe contenido a un archivo.
   args: {"path": "/home/lifeos/nota.txt", "content": "contenido aqui"}

6. **list_files** — Lista archivos en un directorio.
   args: {"path": "/home/lifeos/Descargas", "pattern": "*.pdf"}

7. **system_status** — Muestra el estado del sistema (disco, memoria, CPU, bateria).
   args: {} (sin parametros)

8. **open_url** — Abre una URL y obtiene su contenido HTML.
   args: {"url": "https://example.com"}

9. **remember** — Guarda en memoria persistente (SOBREVIVE ENTRE SESIONES). Usa formato estructurado.
   args: {"type": "preference", "topic": "usuario:gustos", "title": "Cafe sin azucar", "content": "What: prefiere cafe sin azucar. Why: lo menciono en conversacion. Learned: recordar siempre.", "tags": "preferencias,comida"}
   Tipos: bugfix, decision, architecture, discovery, pattern, config, preference

10. **recall** — Busca en memoria persistente.
    args: {"query": "preferencias del usuario"}

11. **computer_type** — Escribe texto con el teclado virtual (como si el usuario tecleara).
    args: {"text": "Hola mundo"}

12. **computer_key** — Presiona una combinacion de teclas.
    args: {"combo": "ctrl+c"}

13. **computer_click** — Hace clic en una posicion de la pantalla.
    args: {"x": 500, "y": 300, "button": 1}

14. **install_app** — Instala una aplicacion via Flatpak.
    args: {"name": "discord", "flatpak_id": "com.discordapp.Discord"}

15. **notify** — Muestra una notificacion en el escritorio del usuario.
    args: {"title": "Recordatorio", "body": "Tu reunion empieza en 5 minutos"}

16. **task_status** — Muestra el estado de las tareas en cola.
    args: {} (sin parametros)

17. **browser_navigate** — Navega a una URL con el navegador y captura screenshot para analisis visual.
    args: {"url": "https://example.com", "analyze": "describe lo que ves en la pagina"}

18. **cron_add** — Programa una tarea recurrente con expresion cron.
    args: {"name": "briefing matutino", "cron": "0 7 * * *", "action": "Revisa emails y calendario, dame un resumen"}

19. **cron_list** — Lista las tareas cron programadas.
    args: {} (sin parametros)

20. **cron_remove** — Elimina una tarea cron por nombre.
    args: {"name": "briefing matutino"}

21. **smart_home** — Controla dispositivos de domótica via Home Assistant.
    args: {"action": "turn_on", "entity": "light.sala"}
    Acciones: turn_on, turn_off, toggle, status, list_entities
    Para status/list: args: {"action": "list_entities"} o {"action": "status", "entity": "light.sala"}

22. **tailscale_status** — Muestra el estado de la red Tailscale y dispositivos conectados.
    args: {} (sin parametros)

23. **tailscale_share** — Comparte un servicio local via Tailscale Funnel (acceso publico) o Serve (solo tailnet).
    args: {"port": 8080, "mode": "funnel"}
    mode: "funnel" (publico) o "serve" (solo tailnet)

24. **sub_agent** — Lanza un sub-agente con un modelo especifico para una tarea.
    args: {"task": "Analiza este codigo y sugiere mejoras", "model": "cerebras-qwen235b", "thinking": "high"}
    Usa esto para tareas que requieren un modelo diferente al actual.

25. **skill_run** — Ejecuta un skill instalado por nombre.
    args: {"skill": "weather", "input": "Monterrey, Mexico"}

26. **skill_list** — Lista los skills instalados disponibles.
    args: {} (sin parametros)

27. **sdd_start** — Inicia workflow SDD (Spec-Driven Development) de 9 fases para desarrollo complejo.
    args: {"task": "Crear modulo de autenticacion con OAuth2"}
    Usa SDD para: crear features, refactorizar, disenar arquitectura, o tareas de desarrollo que toquen 3+ archivos.

28. **graph_add** — Agrega una relacion al grafo de conocimiento (ej: "Hector trabaja_en LifeOS").
    args: {"subject": "hector", "predicate": "trabaja_en", "object": "lifeos"}

29. **graph_query** — Consulta el grafo de conocimiento sobre una entidad.
    args: {"entity": "hector"}

30. **procedure_save** — Guarda un procedimiento reutilizable (workflow que aprendiste).
    args: {"name": "deploy lifeos", "description": "Como deployar LifeOS", "steps": ["cargo build --release", "podman push", "bootc update"], "trigger": "deploy"}

31. **procedure_find** — Busca procedimientos guardados.
    args: {"query": "deploy"}

32. **translate** — Traduce texto entre idiomas (offline con Argos, o via LLM).
    args: {"text": "Hello, how are you?", "target_lang": "es"}
    Opcional: {"source_lang": "en"} (si no se pone, detecta automaticamente)

## Reglas

- Puedes usar MULTIPLES herramientas en una respuesta.
- NUNCA inventes resultados — usa herramientas para datos reales.
- SIEMPRE guarda en memoria decisiones, descubrimientos y preferencias (protocolo obligatorio).
- Cuando descubras RELACIONES entre entidades, usa graph_add para guardarlas (ej: "usuario prefiere X", "proyecto usa Y").
- Cuando aprendas un PROCEDIMIENTO (secuencia de pasos para lograr algo), usa procedure_save.
- Si el usuario dice "y eso?", busca en memoria con recall o refierete al contexto previo.
"#;

    // -----------------------------------------------------------------------
    // Conversation history store — with compaction, disk persistence,
    // and intelligent sliding window
    // -----------------------------------------------------------------------

    /// Threshold to trigger auto-compaction of old messages into a summary.
    const COMPACTION_THRESHOLD: usize = 20;
    /// How many recent messages to always keep verbatim (tail of the window).
    const RECENT_WINDOW: usize = 15;

    #[derive(Clone, Serialize, Deserialize)]
    struct ConversationEntry {
        /// The very first user message (preserves original intent).
        first_message: Option<ChatMessage>,
        /// Compacted summary of older messages (generated by LLM).
        compacted_summary: Option<String>,
        /// Recent messages kept verbatim (sliding window tail).
        messages: Vec<ChatMessage>,
        last_active: chrono::DateTime<chrono::Utc>,
    }

    /// Thread-safe conversation history with disk persistence and auto-compaction.
    pub struct ConversationHistory {
        chats: RwLock<HashMap<i64, ConversationEntry>>,
        persist_path: std::path::PathBuf,
    }

    impl ConversationHistory {
        pub fn new() -> Self {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
            let persist_path = std::path::PathBuf::from(format!(
                "{}/.local/share/lifeos/conversation_history.json",
                home
            ));

            // Load from disk if available
            let chats = if persist_path.exists() {
                std::fs::read_to_string(&persist_path)
                    .ok()
                    .and_then(|s| serde_json::from_str::<HashMap<i64, ConversationEntry>>(&s).ok())
                    .unwrap_or_default()
            } else {
                HashMap::new()
            };

            // Prune stale entries on load
            let now = chrono::Utc::now();
            let chats: HashMap<i64, ConversationEntry> = chats
                .into_iter()
                .filter(|(_, v)| {
                    now.signed_duration_since(v.last_active).num_seconds() < HISTORY_TTL_SECS
                })
                .collect();

            Self {
                chats: RwLock::new(chats),
                persist_path,
            }
        }

        /// Get the conversation history for a chat as a flat message list.
        /// Returns: [first_message] + [compacted_summary_as_system] + [recent_messages]
        pub async fn get(&self, chat_id: i64) -> Vec<ChatMessage> {
            let chats = self.chats.read().await;
            if let Some(entry) = chats.get(&chat_id) {
                let age = chrono::Utc::now()
                    .signed_duration_since(entry.last_active)
                    .num_seconds();
                if age >= HISTORY_TTL_SECS {
                    return Vec::new();
                }

                let mut result = Vec::new();

                // 1. First message (original intent)
                if let Some(ref first) = entry.first_message {
                    result.push(first.clone());
                }

                // 2. Compacted summary of older messages
                if let Some(ref summary) = entry.compacted_summary {
                    result.push(ChatMessage {
                        role: "system".into(),
                        content: serde_json::Value::String(format!(
                            "[Resumen de conversacion anterior]: {}",
                            summary
                        )),
                    });
                }

                // 3. Recent messages (verbatim)
                result.extend(entry.messages.clone());

                return result;
            }
            Vec::new()
        }

        /// Append messages and trigger compaction if needed.
        pub async fn append(&self, chat_id: i64, new_messages: &[ChatMessage]) {
            let mut chats = self.chats.write().await;
            let entry = chats.entry(chat_id).or_insert_with(|| ConversationEntry {
                first_message: None,
                compacted_summary: None,
                messages: Vec::new(),
                last_active: chrono::Utc::now(),
            });

            // Capture first user message if not yet set
            if entry.first_message.is_none() {
                if let Some(first_user) = new_messages.iter().find(|m| m.role == "user") {
                    entry.first_message = Some(first_user.clone());
                }
            }

            entry.messages.extend(new_messages.iter().cloned());
            entry.last_active = chrono::Utc::now();

            // Mark if compaction is needed (done outside the lock)
            let needs_compaction = entry.messages.len() > COMPACTION_THRESHOLD;
            let compact_messages = if needs_compaction {
                // Take messages that will be compacted (everything except the last RECENT_WINDOW)
                let split_at = entry.messages.len().saturating_sub(RECENT_WINDOW);
                if split_at > 2 {
                    let old = entry.messages.drain(..split_at).collect::<Vec<_>>();
                    Some(old)
                } else {
                    None
                }
            } else {
                None
            };

            // Cleanup stale chats
            let now = chrono::Utc::now();
            chats.retain(|_, v| {
                now.signed_duration_since(v.last_active).num_seconds() < HISTORY_TTL_SECS
            });

            // Persist to disk
            self.persist_locked(&chats);

            // If compaction needed, build summary from old messages
            if let Some(old_msgs) = compact_messages {
                let mut summary_parts: Vec<String> = Vec::new();

                // Include existing compacted summary
                if let Some(entry) = chats.get(&chat_id) {
                    if let Some(ref prev) = entry.compacted_summary {
                        summary_parts.push(prev.clone());
                    }
                }

                // Add old messages as text
                for msg in &old_msgs {
                    let content = msg.content.as_str().unwrap_or("[media]");
                    summary_parts.push(format!(
                        "[{}]: {}",
                        msg.role,
                        &content[..content.len().min(150)]
                    ));
                }

                let new_summary = summary_parts.join("\n");

                // Update the entry with the compacted summary
                if let Some(entry) = chats.get_mut(&chat_id) {
                    entry.compacted_summary =
                        Some(new_summary[..new_summary.len().min(2000)].to_string());
                }

                self.persist_locked(&chats);
                info!(
                    "[history] Compacted {} old messages for chat {}",
                    old_msgs.len(),
                    chat_id
                );
            }
        }

        /// Request LLM-powered compaction of the summary (call periodically).
        pub async fn compact_with_llm(&self, chat_id: i64, router: &Arc<RwLock<LlmRouter>>) {
            let raw_summary = {
                let chats = self.chats.read().await;
                match chats.get(&chat_id) {
                    Some(entry) => entry.compacted_summary.clone(),
                    None => return,
                }
            };

            let Some(raw) = raw_summary else { return };
            if raw.len() < 500 {
                return; // Too short to need LLM compaction
            }

            let prompt = format!(
                "Compacta este resumen de conversacion en maximo 3 oraciones. \
                 Conserva: decisiones, preferencias del usuario, tareas pendientes, \
                 y contexto clave. Descarta saludos y relleno.\n\n{}",
                &raw[..raw.len().min(3000)]
            );

            let request = RouterRequest {
                messages: vec![ChatMessage {
                    role: "user".into(),
                    content: serde_json::Value::String(prompt),
                }],
                complexity: Some(TaskComplexity::Simple),
                sensitivity: None,
                preferred_provider: None,
                max_tokens: Some(256),
            };

            let r = router.read().await;
            if let Ok(resp) = r.chat(&request).await {
                let mut chats = self.chats.write().await;
                if let Some(entry) = chats.get_mut(&chat_id) {
                    entry.compacted_summary = Some(resp.text);
                    info!("[history] LLM-compacted summary for chat {}", chat_id);
                }
                self.persist_locked(&chats);
            }
        }

        /// Clear history for a chat, returning messages for session summary.
        pub async fn clear(&self, chat_id: i64) -> Vec<ChatMessage> {
            let mut chats = self.chats.write().await;
            let entry = chats.remove(&chat_id);
            self.persist_locked(&chats);
            entry.map(|e| e.messages).unwrap_or_default()
        }

        fn persist_locked(&self, chats: &HashMap<i64, ConversationEntry>) {
            if let Some(parent) = self.persist_path.parent() {
                std::fs::create_dir_all(parent).ok();
            }
            if let Ok(json) = serde_json::to_string(chats) {
                std::fs::write(&self.persist_path, json).ok();
            }
        }
    }

    // -----------------------------------------------------------------------
    // Cron jobs store
    // -----------------------------------------------------------------------

    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct CronJob {
        pub name: String,
        pub cron_expr: String,
        pub action: String,
        pub created_at: chrono::DateTime<chrono::Utc>,
        pub last_run: Option<chrono::DateTime<chrono::Utc>>,
        pub chat_id: i64,
    }

    /// Thread-safe cron jobs store with file persistence.
    pub struct CronStore {
        jobs: RwLock<Vec<CronJob>>,
        file_path: std::path::PathBuf,
    }

    impl CronStore {
        pub fn new() -> Self {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
            let file_path =
                std::path::PathBuf::from(format!("{}/.config/lifeos/telegram_cron.json", home));
            let jobs = if file_path.exists() {
                std::fs::read_to_string(&file_path)
                    .ok()
                    .and_then(|s| serde_json::from_str(&s).ok())
                    .unwrap_or_default()
            } else {
                Vec::new()
            };
            Self {
                jobs: RwLock::new(jobs),
                file_path,
            }
        }

        pub async fn add(&self, job: CronJob) -> Result<()> {
            let mut jobs = self.jobs.write().await;
            // Remove existing job with same name
            jobs.retain(|j| j.name != job.name);
            jobs.push(job);
            self.persist(&jobs).await
        }

        pub async fn list(&self) -> Vec<CronJob> {
            self.jobs.read().await.clone()
        }

        pub async fn remove(&self, name: &str) -> bool {
            let mut jobs = self.jobs.write().await;
            let before = jobs.len();
            jobs.retain(|j| j.name != name);
            let removed = jobs.len() < before;
            if removed {
                self.persist(&jobs).await.ok();
            }
            removed
        }

        pub async fn mark_run(&self, name: &str) {
            let mut jobs = self.jobs.write().await;
            if let Some(job) = jobs.iter_mut().find(|j| j.name == name) {
                job.last_run = Some(chrono::Utc::now());
            }
            self.persist(&jobs).await.ok();
        }

        async fn persist(&self, jobs: &[CronJob]) -> Result<()> {
            if let Some(parent) = self.file_path.parent() {
                tokio::fs::create_dir_all(parent).await.ok();
            }
            let json = serde_json::to_string_pretty(jobs)?;
            tokio::fs::write(&self.file_path, json).await?;
            Ok(())
        }

        /// Check which cron jobs should run now based on their cron expression.
        /// Simple cron matching: "min hour dom mon dow" (5-field).
        pub async fn due_jobs(&self) -> Vec<CronJob> {
            let now = chrono::Local::now();
            let jobs = self.jobs.read().await;
            jobs.iter()
                .filter(|job| {
                    // Skip if ran less than 55 seconds ago (prevent double-fire)
                    if let Some(last) = job.last_run {
                        let elapsed = chrono::Utc::now().signed_duration_since(last).num_seconds();
                        if elapsed < 55 {
                            return false;
                        }
                    }
                    cron_matches(&job.cron_expr, &now)
                })
                .cloned()
                .collect()
        }
    }

    /// Simple 5-field cron expression matcher.
    fn cron_matches(expr: &str, now: &chrono::DateTime<chrono::Local>) -> bool {
        use chrono::Datelike;
        use chrono::Timelike;

        let fields: Vec<&str> = expr.split_whitespace().collect();
        if fields.len() != 5 {
            return false;
        }

        let checks = [
            (fields[0], now.minute()),
            (fields[1], now.hour()),
            (fields[2], now.day()),
            (fields[3], now.month()),
            (fields[4], now.weekday().num_days_from_sunday()),
        ];

        checks
            .iter()
            .all(|(field, value)| field_matches(field, *value))
    }

    fn field_matches(field: &str, value: u32) -> bool {
        if field == "*" {
            return true;
        }
        // Handle */N (every N)
        if let Some(step) = field.strip_prefix("*/") {
            if let Ok(n) = step.parse::<u32>() {
                return n > 0 && value % n == 0;
            }
        }
        // Handle comma-separated values
        for part in field.split(',') {
            // Handle range (N-M)
            if let Some((start, end)) = part.split_once('-') {
                if let (Ok(s), Ok(e)) = (start.parse::<u32>(), end.parse::<u32>()) {
                    if value >= s && value <= e {
                        return true;
                    }
                }
            } else if let Ok(n) = part.parse::<u32>() {
                if n == value {
                    return true;
                }
            }
        }
        false
    }

    // -----------------------------------------------------------------------
    // HEARTBEAT.md configurable checklist
    // -----------------------------------------------------------------------

    /// Read the user's HEARTBEAT.md checklist, or return a default one.
    pub async fn load_heartbeat_checklist() -> String {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
        let paths = [
            format!("{}/.config/lifeos/HEARTBEAT.md", home),
            format!("{}/HEARTBEAT.md", home),
        ];

        for path in &paths {
            if let Ok(content) = tokio::fs::read_to_string(path).await {
                if !content.trim().is_empty() {
                    return content;
                }
            }
        }

        // Default checklist
        "# Heartbeat checklist\n\n\
         - Revisa el uso de disco, alerta si alguna particion supera 85%\n\
         - Revisa la memoria RAM, alerta si el uso supera 85%\n\
         - Revisa la temperatura del CPU, alerta si supera 80C\n\
         - Revisa si hay tareas atascadas (running > 30 min)\n\
         - Si todo esta bien, responde HEARTBEAT_OK\n"
            .to_string()
    }

    /// Run a heartbeat cycle: evaluate checklist with LLM + system data.
    pub async fn run_heartbeat(ctx: &ToolContext) -> Option<String> {
        let checklist = load_heartbeat_checklist().await;
        let alerts = proactive::check_all(None).await;

        let mut system_data = String::from("Estado actual del sistema:\n");
        if alerts.is_empty() {
            system_data.push_str("- Sin alertas del sistema.\n");
        } else {
            for alert in &alerts {
                system_data.push_str(&format!(
                    "- [{:?}] [{:?}] {}\n",
                    alert.category, alert.severity, alert.message
                ));
            }
        }

        // Add basic metrics
        if let Ok(o) = tokio::process::Command::new("df")
            .args(["-h", "/", "/var"])
            .output()
            .await
        {
            system_data.push_str(&format!(
                "\nDisco:\n{}\n",
                String::from_utf8_lossy(&o.stdout)
            ));
        }
        if let Ok(o) = tokio::process::Command::new("free")
            .args(["-h"])
            .output()
            .await
        {
            system_data.push_str(&format!(
                "Memoria:\n{}\n",
                String::from_utf8_lossy(&o.stdout)
            ));
        }

        let prompt = format!(
            "Eres Axi, el asistente de LifeOS. Evalua este checklist de heartbeat y los datos del sistema.\n\
             Si todo esta bien, responde EXACTAMENTE \"HEARTBEAT_OK\" y nada mas.\n\
             Si hay algo que reportar, responde con un mensaje conciso en español para el usuario.\n\n\
             ## Checklist\n{}\n\n## Datos del sistema\n{}",
            checklist, system_data
        );

        let request = RouterRequest {
            messages: vec![ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(prompt),
            }],
            complexity: Some(TaskComplexity::Simple),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(512),
        };

        let router = ctx.router.read().await;
        match router.chat(&request).await {
            Ok(r) => {
                let text = r.text.trim().to_string();
                if text == "HEARTBEAT_OK" || text.contains("HEARTBEAT_OK") {
                    info!("[heartbeat] All clear (evaluated by {})", r.provider);
                    None
                } else {
                    Some(format!("Reporte de Axi:\n\n{}", text))
                }
            }
            Err(e) => {
                warn!("[heartbeat] LLM evaluation failed: {}", e);
                // Fallback: only report proactive alerts
                if alerts
                    .iter()
                    .any(|a| a.severity == proactive::AlertSeverity::Critical)
                {
                    let mut text = String::from("Reporte proactivo:\n");
                    for a in &alerts {
                        text.push_str(&format!("\n[{:?}] {}", a.severity, a.message));
                    }
                    Some(text)
                } else {
                    None
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Tool execution context
    // -----------------------------------------------------------------------

    // -----------------------------------------------------------------------
    // SDD session state (for checkpoint-based approval flow)
    // -----------------------------------------------------------------------

    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct SddSession {
        pub id: String,
        pub task: String,
        pub chat_id: i64,
        pub current_phase: usize,
        pub accumulated_result: String,
        pub prev_output: String,
        pub created_at: chrono::DateTime<chrono::Utc>,
    }

    /// Checkpoint phases: after Propose (phase 2), after Design (phase 4), before Archive.
    /// Returns true if we should pause AFTER completing this phase index.
    fn is_checkpoint_phase(phase_idx: usize) -> bool {
        // Pause after: Propose (1), Design (3)
        matches!(phase_idx, 1 | 3)
    }

    pub struct SddStore {
        sessions: RwLock<HashMap<String, SddSession>>,
    }

    impl SddStore {
        pub fn new() -> Self {
            Self {
                sessions: RwLock::new(HashMap::new()),
            }
        }

        pub async fn save(&self, session: SddSession) {
            let mut sessions = self.sessions.write().await;
            sessions.insert(session.id.clone(), session);
        }

        pub async fn remove(&self, id: &str) -> Option<SddSession> {
            self.sessions.write().await.remove(id)
        }
    }

    #[derive(Clone)]
    pub struct ToolContext {
        pub router: Arc<RwLock<LlmRouter>>,
        pub task_queue: Arc<TaskQueue>,
        pub memory: Option<Arc<RwLock<MemoryPlaneManager>>>,
        pub knowledge_graph: Option<Arc<RwLock<KnowledgeGraph>>>,
        pub history: Arc<ConversationHistory>,
        pub cron_store: Arc<CronStore>,
        pub sdd_store: Arc<SddStore>,
    }

    /// Check if the user's message contains keywords that suggest they want
    /// to recall something from past conversations (works case-insensitively).
    fn needs_memory_recall(text: &str) -> bool {
        let lower = text.to_lowercase();
        let keywords = [
            "recuerdas",
            "remember",
            "acuerdas",
            "dijiste",
            "hablamos",
            "mencionaste",
            "prometiste",
            "acordamos",
            "la vez que",
            "yesterday",
            "ayer",
            "la semana pasada",
            "last week",
            "antes",
        ];
        keywords.iter().any(|kw| lower.contains(kw))
    }

    // -----------------------------------------------------------------------
    // Parsing tool calls from LLM output
    // -----------------------------------------------------------------------

    #[derive(Debug, Clone)]
    pub struct ToolCall {
        pub name: String,
        pub args: serde_json::Value,
    }

    /// Parse tool calls from LLM response text.
    /// Returns (tool_calls, remaining_text_before_first_tool).
    pub fn parse_tool_calls(text: &str) -> (Vec<ToolCall>, String) {
        let mut calls = Vec::new();
        let mut remaining = text;

        // Find text before first tool call
        let prefix = if let Some(pos) = remaining.find("<tool>") {
            let p = remaining[..pos].trim().to_string();
            remaining = &remaining[pos..];
            p
        } else {
            return (calls, text.to_string());
        };

        while let Some(tool_start) = remaining.find("<tool>") {
            let after_tag = &remaining[tool_start + 6..];
            if let Some(tool_end) = after_tag.find("</tool>") {
                let tool_name = after_tag[..tool_end].trim().to_string();
                let after_tool = &after_tag[tool_end + 7..];

                let args = if let Some(args_start) = after_tool.find("<args>") {
                    let after_args_tag = &after_tool[args_start + 6..];
                    if let Some(args_end) = after_args_tag.find("</args>") {
                        let args_str = after_args_tag[..args_end].trim();
                        remaining = &after_args_tag[args_end + 7..];
                        serde_json::from_str(args_str).unwrap_or(serde_json::json!({}))
                    } else {
                        remaining = after_tool;
                        serde_json::json!({})
                    }
                } else {
                    remaining = after_tool;
                    serde_json::json!({})
                };

                calls.push(ToolCall {
                    name: tool_name,
                    args,
                });
            } else {
                break;
            }
        }

        (calls, prefix)
    }

    // -----------------------------------------------------------------------
    // Tool execution
    // -----------------------------------------------------------------------

    #[derive(Debug, Serialize, Deserialize)]
    pub struct ToolResult {
        pub tool: String,
        pub success: bool,
        pub output: String,
    }

    pub async fn execute_tool(call: &ToolCall, ctx: &ToolContext) -> ToolResult {
        info!(
            "[telegram_tools] Executing tool: {} args={}",
            call.name, call.args
        );

        let result = match call.name.as_str() {
            "screenshot" => execute_screenshot().await,
            "run_command" => execute_run_command(&call.args).await,
            "search_web" => execute_search_web(&call.args, ctx).await,
            "read_file" => execute_read_file(&call.args).await,
            "write_file" => execute_write_file(&call.args).await,
            "list_files" => execute_list_files(&call.args).await,
            "system_status" => execute_system_status().await,
            "open_url" => execute_open_url(&call.args).await,
            "remember" => execute_remember(&call.args, ctx).await,
            "recall" => execute_recall(&call.args, ctx).await,
            "computer_type" => execute_computer_type(&call.args).await,
            "computer_key" => execute_computer_key(&call.args).await,
            "computer_click" => execute_computer_click(&call.args).await,
            "install_app" => execute_install_app(&call.args).await,
            "notify" => execute_notify(&call.args).await,
            "task_status" => execute_task_status(ctx).await,
            "browser_navigate" => execute_browser_navigate(&call.args, ctx).await,
            "cron_add" => execute_cron_add(&call.args, ctx).await,
            "cron_list" => execute_cron_list(ctx).await,
            "cron_remove" => execute_cron_remove(&call.args, ctx).await,
            "smart_home" => execute_smart_home(&call.args).await,
            "tailscale_status" => execute_tailscale_status().await,
            "tailscale_share" => execute_tailscale_share(&call.args).await,
            "sub_agent" => execute_sub_agent(&call.args, ctx).await,
            "skill_run" => execute_skill_run(&call.args).await,
            "skill_list" => execute_skill_list().await,
            "sdd_start" => execute_sdd_start(&call.args, ctx).await,
            "graph_add" => execute_graph_add(&call.args, ctx).await,
            "graph_query" => execute_graph_query(&call.args, ctx).await,
            "procedure_save" => execute_procedure_save(&call.args, ctx).await,
            "procedure_find" => execute_procedure_find(&call.args, ctx).await,
            "translate" => execute_translate(&call.args, ctx).await,
            other => Ok(format!("Herramienta '{}' no reconocida", other)),
        };

        match result {
            Ok(output) => ToolResult {
                tool: call.name.clone(),
                success: true,
                output,
            },
            Err(e) => ToolResult {
                tool: call.name.clone(),
                success: false,
                output: format!("Error: {}", e),
            },
        }
    }

    /// The agentic chat loop: sends message to LLM, parses tool calls,
    /// executes them, feeds results back, repeats until no more tool calls.
    /// Returns (final_response_text, optional_screenshot_path).
    pub async fn agentic_chat(
        ctx: &ToolContext,
        chat_id: i64,
        user_text: &str,
        image_b64: Option<&str>,
    ) -> (String, Option<String>) {
        // Build messages starting with system prompt
        let mut messages = vec![ChatMessage {
            role: "system".into(),
            content: serde_json::Value::String(SYSTEM_PROMPT.into()),
        }];

        // Inject conversation history for multi-turn context
        let history = ctx.history.get(chat_id).await;
        let is_new_session = history.is_empty();
        if !history.is_empty() {
            messages.extend(history);
        }

        // Proactive context recall: search memory on new sessions or when the
        // user's message contains memory-related keywords (e.g. "recuerdas", "dijiste")
        if is_new_session || needs_memory_recall(user_text) {
            if let Some(memory) = &ctx.memory {
                let mem = memory.read().await;
                // Search for recent and relevant memories
                let recall_queries = [user_text, "session_summary"];
                let mut context_block = String::new();
                for query in &recall_queries {
                    if let Ok(results) = mem.search_entries(query, 3, None).await {
                        for r in &results {
                            context_block
                                .push_str(&format!("- [{}] {}\n", r.entry.kind, r.entry.entry_id));
                        }
                    }
                }
                if !context_block.is_empty() {
                    messages.push(ChatMessage {
                        role: "system".into(),
                        content: serde_json::Value::String(format!(
                            "Contexto recuperado de tu memoria persistente (sesiones anteriores):\n{}",
                            context_block
                        )),
                    });
                }
            }
        }

        // Build user message (text or multimodal)
        let user_msg = if let Some(img) = image_b64 {
            ChatMessage {
                role: "user".into(),
                content: serde_json::json!([
                    { "type": "text", "text": user_text },
                    { "type": "image_url", "image_url": { "url": img } }
                ]),
            }
        } else {
            ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(user_text.into()),
            }
        };
        messages.push(user_msg.clone());

        let complexity = if image_b64.is_some() {
            TaskComplexity::Vision
        } else {
            TaskComplexity::Medium
        };

        let mut screenshot_path: Option<String> = None;

        for round in 0..MAX_TOOL_ROUNDS {
            let request = RouterRequest {
                messages: messages.clone(),
                complexity: Some(complexity),
                sensitivity: None,
                preferred_provider: None,
                max_tokens: Some(2048),
            };

            let router = ctx.router.read().await;
            let response = match router.chat(&request).await {
                Ok(r) => r,
                Err(e) => {
                    warn!("[telegram_tools] LLM call failed round {}: {}", round, e);
                    return (format!("Error conectando con el LLM: {}", e), None);
                }
            };
            drop(router);

            let response_text = response.text.clone();
            let provider = response.provider.clone();

            // Parse tool calls from LLM response
            let (tool_calls, text_before_tools) = parse_tool_calls(&response_text);

            if tool_calls.is_empty() {
                // No tool calls — this is the final response
                let final_text = if response_text.trim().is_empty() {
                    text_before_tools
                } else {
                    response_text.clone()
                };
                // Don't show provider tag to user — log it instead
                log::debug!("[agentic_chat] response from provider: {}", provider);
                let tagged = final_text.trim().to_string();

                // Save to conversation history
                let assistant_msg = ChatMessage {
                    role: "assistant".into(),
                    content: serde_json::Value::String(final_text),
                };
                ctx.history
                    .append(chat_id, &[user_msg, assistant_msg])
                    .await;

                // Trigger LLM compaction in background if summary is long
                let compact_ctx = ctx.clone();
                tokio::spawn(async move {
                    compact_ctx
                        .history
                        .compact_with_llm(chat_id, &compact_ctx.router)
                        .await;
                });

                // Ingest user message and Axi's response into knowledge graph (background)
                if let Some(kg) = &ctx.knowledge_graph {
                    let kg = kg.clone();
                    let user_text = user_text.to_string();
                    let axi_response = tagged.clone();
                    tokio::spawn(async move {
                        let now = chrono::Utc::now();
                        let mut graph = kg.write().await;
                        if let Err(e) = graph.ingest_telegram_message("user", &user_text, now).await
                        {
                            warn!("[knowledge_graph] Failed to ingest user message: {}", e);
                        }
                        if let Err(e) = graph
                            .ingest_telegram_message("axi", &axi_response, now)
                            .await
                        {
                            warn!("[knowledge_graph] Failed to ingest Axi response: {}", e);
                        }
                    });
                }

                return (tagged, screenshot_path);
            }

            // Execute tool calls and collect results
            let mut tool_results = Vec::new();
            for call in &tool_calls {
                let result = execute_tool(call, ctx).await;

                // Capture screenshot path for sending as photo
                if (call.name == "screenshot" || call.name == "browser_navigate")
                    && result.success
                    && result.output.ends_with(".png")
                {
                    screenshot_path = Some(result.output.clone());
                }

                tool_results.push(result);
            }

            // Add LLM response as assistant message
            messages.push(ChatMessage {
                role: "assistant".into(),
                content: serde_json::Value::String(response_text),
            });

            // Add tool results as a user message (tool results feedback)
            let results_text = tool_results
                .iter()
                .map(|r| {
                    format!(
                        "[Resultado de {}]: {}\n{}",
                        r.tool,
                        if r.success { "OK" } else { "ERROR" },
                        &r.output[..r.output.len().min(3000)]
                    )
                })
                .collect::<Vec<_>>()
                .join("\n\n");

            messages.push(ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(format!(
                    "Resultados de las herramientas:\n\n{}\n\nAhora responde al usuario con la informacion obtenida. No repitas los bloques <tool>.",
                    results_text
                )),
            });

            info!(
                "[telegram_tools] Round {}: {} tools executed, continuing...",
                round,
                tool_results.len()
            );
        }

        (
            "Alcance el limite de acciones. Aqui esta lo que tengo hasta ahora.".into(),
            screenshot_path,
        )
    }

    // -----------------------------------------------------------------------
    // Individual tool implementations
    // -----------------------------------------------------------------------

    async fn execute_screenshot() -> Result<String> {
        let tmp_dir = std::env::temp_dir().join("lifeos-telegram");
        tokio::fs::create_dir_all(&tmp_dir).await?;
        let path = tmp_dir.join(format!("screen-{}.png", chrono::Utc::now().timestamp()));

        let output = tokio::process::Command::new("grim")
            .arg(&path)
            .output()
            .await;

        let captured = match output {
            Ok(o) if o.status.success() => true,
            _ => tokio::process::Command::new("gnome-screenshot")
                .args(["-f", &path.to_string_lossy()])
                .output()
                .await
                .map(|o| o.status.success())
                .unwrap_or(false),
        };

        if captured && path.exists() {
            Ok(path.to_string_lossy().to_string())
        } else {
            anyhow::bail!("No pude capturar la pantalla (grim/gnome-screenshot no disponible)")
        }
    }

    async fn execute_run_command(args: &serde_json::Value) -> Result<String> {
        let command = args["command"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'command'"))?;

        let lower = command.to_lowercase();
        let blocked = [
            "rm -rf /",
            "mkfs",
            "dd if=",
            ":(){",
            "fork bomb",
            "chmod -R 777 /",
            "mv /* ",
            ">(){ :|:",
        ];
        for pattern in &blocked {
            if lower.contains(pattern) {
                anyhow::bail!("Comando bloqueado por seguridad: {}", pattern);
            }
        }

        let output = tokio::process::Command::new("sh")
            .arg("-c")
            .arg(command)
            .output()
            .await?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        let exit = output.status.code().unwrap_or(-1);

        let mut result = String::new();
        if !stdout.is_empty() {
            result.push_str(&stdout[..stdout.len().min(4000)]);
        }
        if !stderr.is_empty() {
            result.push_str(&format!(
                "\n[stderr]: {}",
                &stderr[..stderr.len().min(1000)]
            ));
        }
        result.push_str(&format!("\n[exit: {}]", exit));

        Ok(result)
    }

    async fn execute_search_web(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let query = args["query"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'query'"))?;

        let client = reqwest::Client::new();

        // Priority 1: Tavily (free 1000 queries/mo, LLM-optimized results)
        let tavily_key = std::env::var("TAVILY_API_KEY").unwrap_or_default();
        if !tavily_key.is_empty() {
            let res = client
                .post("https://api.tavily.com/search")
                .json(&serde_json::json!({
                    "api_key": tavily_key,
                    "query": query,
                    "max_results": 5,
                    "include_answer": true,
                    "search_depth": "basic"
                }))
                .send()
                .await;

            if let Ok(r) = res {
                if r.status().is_success() {
                    let body: serde_json::Value = r.json().await.unwrap_or_default();
                    let mut result = String::new();

                    // Tavily provides a direct answer
                    if let Some(answer) = body["answer"].as_str() {
                        result.push_str(&format!("Respuesta: {}\n\n", answer));
                    }

                    if let Some(results) = body["results"].as_array() {
                        result.push_str("Fuentes:\n");
                        for item in results.iter().take(5) {
                            let snippet = item["content"].as_str().unwrap_or("");
                            let end = 200.min(snippet.len());
                            result.push_str(&format!(
                                "- {} ({})\n  {}\n",
                                item["title"].as_str().unwrap_or(""),
                                item["url"].as_str().unwrap_or(""),
                                &snippet[..end]
                            ));
                        }
                    }

                    if !result.is_empty() {
                        return Ok(result);
                    }
                }
            }
        }

        // Priority 2: Serper (Google results)
        let serper_key = std::env::var("SERPER_API_KEY").unwrap_or_default();
        if !serper_key.is_empty() {
            let res = client
                .post("https://google.serper.dev/search")
                .header("X-API-KEY", &serper_key)
                .json(&serde_json::json!({"q": query, "num": 5}))
                .send()
                .await;

            match res {
                Ok(r) if r.status().is_success() => {
                    let body: serde_json::Value = r.json().await.unwrap_or_default();
                    let organic = body["organic"]
                        .as_array()
                        .map(|arr| {
                            arr.iter()
                                .take(5)
                                .map(|item| {
                                    format!(
                                        "- {} ({})\n  {}",
                                        item["title"].as_str().unwrap_or(""),
                                        item["link"].as_str().unwrap_or(""),
                                        item["snippet"].as_str().unwrap_or("")
                                    )
                                })
                                .collect::<Vec<_>>()
                                .join("\n")
                        })
                        .unwrap_or_else(|| "Sin resultados".into());
                    return Ok(format!("Resultados para '{}':\n{}", query, organic));
                }
                _ => {}
            }
        }

        // Fallback: ask LLM
        let request = RouterRequest {
            messages: vec![ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(format!(
                    "Busca en internet: {}. Responde con los resultados mas relevantes.",
                    query
                )),
            }],
            complexity: Some(TaskComplexity::Simple),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(1024),
        };

        let router = ctx.router.read().await;
        match router.chat(&request).await {
            Ok(r) => Ok(r.text),
            Err(e) => Ok(format!("No pude buscar: {}", e)),
        }
    }

    async fn execute_read_file(args: &serde_json::Value) -> Result<String> {
        let path = args["path"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'path'"))?;
        let expanded = expand_home(path);
        let content = tokio::fs::read_to_string(&expanded).await?;
        Ok(content.chars().take(6000).collect())
    }

    async fn execute_write_file(args: &serde_json::Value) -> Result<String> {
        let path = args["path"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'path'"))?;
        let content = args["content"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'content'"))?;
        let expanded = expand_home(path);

        if let Some(parent) = std::path::Path::new(&expanded).parent() {
            tokio::fs::create_dir_all(parent).await.ok();
        }
        tokio::fs::write(&expanded, content).await?;
        Ok(format!("Archivo guardado: {}", expanded))
    }

    async fn execute_list_files(args: &serde_json::Value) -> Result<String> {
        let path = args["path"].as_str().unwrap_or("~");
        let pattern = args["pattern"].as_str().unwrap_or("*");
        let expanded = expand_home(path);

        let cmd = if pattern == "*" {
            format!(
                "ls -la '{}' 2>/dev/null; echo '---'; ls '{}' 2>/dev/null | wc -l",
                expanded, expanded
            )
        } else {
            // Sanitize pattern: allow glob chars (*, ?, [, ]) but reject shell injection chars
            let bad_chars = [';', '|', '&', '$', '`', '(', ')', '{', '}', '<', '>', '\'', '"', '\\', '\n'];
            let safe_pattern: String = pattern.chars().filter(|c| !bad_chars.contains(c)).collect();
            format!(
                "ls -la '{}'/{} 2>/dev/null; echo '---'; ls '{}' 2>/dev/null | wc -l",
                expanded, safe_pattern, expanded
            )
        };

        let output = tokio::process::Command::new("sh")
            .arg("-c")
            .arg(&cmd)
            .output()
            .await?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        Ok(stdout[..stdout.len().min(4000)].to_string())
    }

    async fn execute_system_status() -> Result<String> {
        let alerts = proactive::check_all(None).await;

        let disk = tokio::process::Command::new("df")
            .args(["-h", "/", "/var"])
            .output()
            .await
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
            .unwrap_or_default();

        let mem = tokio::process::Command::new("free")
            .args(["-h"])
            .output()
            .await
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
            .unwrap_or_default();

        let uptime = tokio::process::Command::new("uptime")
            .output()
            .await
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default();

        let mut result = format!("Uptime: {}\n\nDisco:\n{}\nMemoria:\n{}", uptime, disk, mem);

        if !alerts.is_empty() {
            result.push_str("\n\nAlertas:");
            for alert in &alerts {
                result.push_str(&format!("\n- [{:?}] {}", alert.severity, alert.message));
            }
        }

        Ok(result)
    }

    async fn execute_open_url(args: &serde_json::Value) -> Result<String> {
        let url = args["url"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'url'"))?;

        let browser = BrowserAutomation::new(std::path::PathBuf::from("/var/lib/lifeos"));
        browser.fetch_html(url).await
    }

    async fn execute_remember(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let content = args["content"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'content'"))?;
        let tags = args["tags"].as_str().unwrap_or("general");
        let mem_type = args["type"].as_str().unwrap_or("note");
        let topic = args["topic"].as_str().unwrap_or("");
        let title = args["title"].as_str().unwrap_or("");

        // Build structured content with title and topic if provided
        let structured_content = if !title.is_empty() || !topic.is_empty() {
            format!("[{}] {}\ntopic: {}\n{}", mem_type, title, topic, content)
        } else {
            content.to_string()
        };

        // Add topic as a tag for searchability
        let mut tag_str = tags.to_string();
        if !topic.is_empty() {
            tag_str = format!("{},{}", tag_str, topic);
        }
        if !mem_type.is_empty() && mem_type != "note" {
            tag_str = format!("{},{}", tag_str, mem_type);
        }

        if let Some(memory) = &ctx.memory {
            let mem = memory.read().await;
            let tag_list: Vec<String> = tag_str.split(',').map(|t| t.trim().to_string()).collect();
            // Map type to importance: decisions/architecture=80, bugfix/discovery=70, pattern=60, preference/config=50
            let importance = match mem_type {
                "decision" | "architecture" => 80,
                "bugfix" | "discovery" => 70,
                "pattern" => 60,
                _ => 50,
            };
            match mem
                .add_entry(
                    mem_type,
                    "user",
                    &tag_list,
                    Some("telegram"),
                    importance,
                    &structured_content,
                )
                .await
            {
                Ok(entry) => {
                    // Also create a knowledge graph entity for the memory
                    if let Some(kg) = &ctx.knowledge_graph {
                        let kg = kg.clone();
                        let entity_name = if !title.is_empty() {
                            title.to_string()
                        } else {
                            structured_content.chars().take(60).collect::<String>()
                        };
                        let entity_type = match mem_type {
                            "decision" | "architecture" => {
                                crate::knowledge_graph::EntityType::Decision
                            }
                            "bugfix" | "discovery" | "pattern" => {
                                crate::knowledge_graph::EntityType::Topic
                            }
                            "preference" | "config" => crate::knowledge_graph::EntityType::Topic,
                            _ => crate::knowledge_graph::EntityType::Topic,
                        };
                        tokio::spawn(async move {
                            let mut graph = kg.write().await;
                            graph.add_entity(&entity_name, entity_type);
                        });
                    }
                    Ok(format!("Guardado en memoria (id: {})", entry.entry_id))
                }
                Err(e) => Ok(format!("Error guardando en memoria: {}", e)),
            }
        } else {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
            let memory_file = format!("{}/.local/share/lifeos/telegram_memory.txt", home);
            if let Some(parent) = std::path::Path::new(&memory_file).parent() {
                tokio::fs::create_dir_all(parent).await.ok();
            }
            let entry = format!(
                "[{}] [{}] {}\n",
                chrono::Utc::now().format("%Y-%m-%d %H:%M"),
                tags,
                content
            );
            tokio::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&memory_file)
                .await?
                .write_all(entry.as_bytes())
                .await
                .map_err(|e| anyhow::anyhow!("Error escribiendo memoria: {}", e))?;
            Ok(format!("Guardado en {}", memory_file))
        }
    }

    async fn execute_recall(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let query = args["query"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'query'"))?;

        if let Some(memory) = &ctx.memory {
            let mem = memory.read().await;
            match mem.search_entries(query, 5, None).await {
                Ok(results) => {
                    if results.is_empty() {
                        Ok("No encontre nada en mi memoria sobre eso.".into())
                    } else {
                        let formatted: Vec<String> = results
                            .iter()
                            .map(|r| format!("- [{}] {}", r.entry.kind, r.entry.entry_id))
                            .collect();
                        Ok(format!("Recuerdos encontrados:\n{}", formatted.join("\n")))
                    }
                }
                Err(e) => Ok(format!("Error buscando en memoria: {}", e)),
            }
        } else {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
            let memory_file = format!("{}/.local/share/lifeos/telegram_memory.txt", home);
            match tokio::fs::read_to_string(&memory_file).await {
                Ok(content) => {
                    let query_lower = query.to_lowercase();
                    let matches: Vec<&str> = content
                        .lines()
                        .filter(|line| line.to_lowercase().contains(&query_lower))
                        .collect();
                    if matches.is_empty() {
                        Ok("No encontre nada en mi memoria sobre eso.".into())
                    } else {
                        Ok(format!("Recuerdos:\n{}", matches.join("\n")))
                    }
                }
                Err(_) => Ok("No tengo memorias guardadas aun.".into()),
            }
        }
    }

    async fn execute_computer_type(args: &serde_json::Value) -> Result<String> {
        let text = args["text"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'text'"))?;
        let manager = ComputerUseManager::new();
        let result = manager
            .execute(ComputerUseAction::TypeText { text: text.into() }, false)
            .await?;
        if result.success {
            Ok(format!("Texto escrito: '{}'", &text[..text.len().min(50)]))
        } else {
            Ok(format!("Error escribiendo texto: {}", result.stderr))
        }
    }

    async fn execute_computer_key(args: &serde_json::Value) -> Result<String> {
        let combo = args["combo"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'combo'"))?;
        let manager = ComputerUseManager::new();
        let result = manager
            .execute(
                ComputerUseAction::Key {
                    combo: combo.into(),
                },
                false,
            )
            .await?;
        if result.success {
            Ok(format!("Tecla presionada: {}", combo))
        } else {
            Ok(format!("Error presionando tecla: {}", result.stderr))
        }
    }

    async fn execute_computer_click(args: &serde_json::Value) -> Result<String> {
        let x = args["x"].as_i64().unwrap_or(0) as i32;
        let y = args["y"].as_i64().unwrap_or(0) as i32;
        let button = args["button"].as_u64().unwrap_or(1) as u8;
        let manager = ComputerUseManager::new();
        manager
            .execute(ComputerUseAction::Move { x, y }, false)
            .await?;
        let result = manager
            .execute(ComputerUseAction::Click { button }, false)
            .await?;
        if result.success {
            Ok(format!("Clic en ({}, {}) boton {}", x, y, button))
        } else {
            Ok(format!("Error haciendo clic: {}", result.stderr))
        }
    }

    async fn execute_install_app(args: &serde_json::Value) -> Result<String> {
        let name = args["name"].as_str().unwrap_or("app");
        let flatpak_id = args["flatpak_id"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'flatpak_id'"))?;
        let output = tokio::process::Command::new("flatpak")
            .args(["install", "-y", "--noninteractive", "flathub", flatpak_id])
            .output()
            .await?;
        if output.status.success() {
            Ok(format!("{} instalado correctamente via Flatpak", name))
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Ok(format!(
                "Error instalando {}: {}",
                name,
                &stderr[..stderr.len().min(500)]
            ))
        }
    }

    async fn execute_notify(args: &serde_json::Value) -> Result<String> {
        let title = args["title"].as_str().unwrap_or("LifeOS");
        let body = args["body"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'body'"))?;
        notify_rust::Notification::new()
            .summary(title)
            .body(body)
            .icon("dialog-information")
            .show()?;
        Ok(format!("Notificacion enviada: {}", title))
    }

    async fn execute_task_status(ctx: &ToolContext) -> Result<String> {
        let summary = ctx.task_queue.summary().unwrap_or_default();
        let recent = ctx.task_queue.list(None, 10).unwrap_or_default();
        let mut result = format!(
            "Estado de tareas: {}",
            serde_json::to_string_pretty(&summary).unwrap_or_else(|_| "{}".into())
        );
        if !recent.is_empty() {
            result.push_str("\n\nTareas recientes:");
            for t in &recent {
                let status = serde_json::to_value(t.status).unwrap_or_default();
                result.push_str(&format!(
                    "\n- [{}] {}",
                    status.as_str().unwrap_or("?"),
                    &t.objective[..t.objective.len().min(60)],
                ));
            }
        }
        Ok(result)
    }

    // -----------------------------------------------------------------------
    // NEW: Browser automation with CDP-style navigation + vision
    // -----------------------------------------------------------------------

    async fn execute_browser_navigate(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let url = args["url"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'url'"))?;
        let analyze = args["analyze"]
            .as_str()
            .unwrap_or("Describe lo que ves en esta pagina web");

        let browser = BrowserAutomation::new(std::path::PathBuf::from("/var/lib/lifeos"));

        // Navigate and capture screenshot
        let screenshot_path = browser.navigate_and_capture(url).await?;

        // Read screenshot and send to vision LLM for analysis
        let img_bytes = tokio::fs::read(&screenshot_path).await?;
        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&img_bytes);
        let data_url = format!("data:image/png;base64,{}", b64);

        let request = RouterRequest {
            messages: vec![
                ChatMessage {
                    role: "system".into(),
                    content: serde_json::Value::String(
                        "Eres un asistente que analiza capturas de paginas web. Describe el contenido de forma concisa en español.".into(),
                    ),
                },
                ChatMessage {
                    role: "user".into(),
                    content: serde_json::json!([
                        { "type": "text", "text": format!("URL: {}\n\n{}", url, analyze) },
                        { "type": "image_url", "image_url": { "url": data_url } }
                    ]),
                },
            ],
            complexity: Some(TaskComplexity::Vision),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(1024),
        };

        let router = ctx.router.read().await;
        match router.chat(&request).await {
            Ok(r) => Ok(format!(
                "Screenshot: {}\n\nAnalisis:\n{}",
                screenshot_path, r.text
            )),
            Err(_) => {
                // Fallback: fetch HTML instead
                let html = browser.fetch_html(url).await.unwrap_or_default();
                Ok(format!(
                    "Screenshot: {}\n\nHTML (sin vision):\n{}",
                    screenshot_path,
                    &html[..html.len().min(3000)]
                ))
            }
        }
    }

    // -----------------------------------------------------------------------
    // NEW: Cron job management tools
    // -----------------------------------------------------------------------

    async fn execute_cron_add(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let name = args["name"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'name'"))?;
        let cron_expr = args["cron"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'cron'"))?;
        let action = args["action"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'action'"))?;

        // Validate cron expression (must be 5 fields)
        let fields: Vec<&str> = cron_expr.split_whitespace().collect();
        if fields.len() != 5 {
            anyhow::bail!(
                "Expresion cron invalida: se necesitan 5 campos (min hora dia mes dia_semana)"
            );
        }

        let chat_id = args["_chat_id"].as_i64().unwrap_or(0);

        let job = CronJob {
            name: name.to_string(),
            cron_expr: cron_expr.to_string(),
            action: action.to_string(),
            created_at: chrono::Utc::now(),
            last_run: None,
            chat_id,
        };

        ctx.cron_store.add(job).await?;
        Ok(format!(
            "Cron job '{}' creado: '{}' -> {}",
            name, cron_expr, action
        ))
    }

    async fn execute_cron_list(ctx: &ToolContext) -> Result<String> {
        let jobs = ctx.cron_store.list().await;
        if jobs.is_empty() {
            return Ok("No hay tareas cron programadas.".into());
        }
        let mut result = String::from("Tareas cron programadas:\n");
        for job in &jobs {
            let last = job
                .last_run
                .map(|t| t.format("%Y-%m-%d %H:%M").to_string())
                .unwrap_or_else(|| "nunca".into());
            result.push_str(&format!(
                "\n- {} [{}] -> {} (ultima: {})",
                job.name, job.cron_expr, job.action, last
            ));
        }
        Ok(result)
    }

    async fn execute_cron_remove(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let name = args["name"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'name'"))?;

        if ctx.cron_store.remove(name).await {
            Ok(format!("Cron job '{}' eliminado", name))
        } else {
            Ok(format!("No encontre un cron job llamado '{}'", name))
        }
    }

    // -----------------------------------------------------------------------
    // NEW: Smart Home (Home Assistant REST API)
    // -----------------------------------------------------------------------

    async fn execute_smart_home(args: &serde_json::Value) -> Result<String> {
        let action = args["action"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'action'"))?;

        let ha_url = std::env::var("LIFEOS_HA_URL").unwrap_or_default();
        let ha_token = std::env::var("LIFEOS_HA_TOKEN").unwrap_or_default();

        if ha_url.is_empty() || ha_token.is_empty() {
            return Ok(
                "Home Assistant no configurado. Configura LIFEOS_HA_URL y LIFEOS_HA_TOKEN.".into(),
            );
        }

        let client = reqwest::Client::new();
        let base = ha_url.trim_end_matches('/');
        let auth = format!("Bearer {}", ha_token);

        match action {
            "list_entities" => {
                let resp = client
                    .get(format!("{}/api/states", base))
                    .header("Authorization", &auth)
                    .send()
                    .await?;

                if !resp.status().is_success() {
                    return Ok(format!("Error: HTTP {}", resp.status()));
                }

                let entities: Vec<serde_json::Value> = resp.json().await?;
                let mut result = format!("{} entidades encontradas:\n", entities.len());
                for e in entities.iter().take(30) {
                    result.push_str(&format!(
                        "- {} = {} ({})\n",
                        e["entity_id"].as_str().unwrap_or("?"),
                        e["state"].as_str().unwrap_or("?"),
                        e["attributes"]["friendly_name"].as_str().unwrap_or("")
                    ));
                }
                if entities.len() > 30 {
                    result.push_str(&format!("... y {} mas", entities.len() - 30));
                }
                Ok(result)
            }
            "status" => {
                let entity = args["entity"]
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!("Falta parametro 'entity'"))?;

                let resp = client
                    .get(format!("{}/api/states/{}", base, entity))
                    .header("Authorization", &auth)
                    .send()
                    .await?;

                if !resp.status().is_success() {
                    return Ok(format!("Entidad no encontrada: {}", entity));
                }

                let state: serde_json::Value = resp.json().await?;
                Ok(format!(
                    "{}: {} ({})\nAtributos: {}",
                    entity,
                    state["state"].as_str().unwrap_or("?"),
                    state["attributes"]["friendly_name"].as_str().unwrap_or(""),
                    serde_json::to_string_pretty(&state["attributes"])
                        .unwrap_or_default()
                        .chars()
                        .take(1000)
                        .collect::<String>()
                ))
            }
            "turn_on" | "turn_off" | "toggle" => {
                let entity = args["entity"]
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!("Falta parametro 'entity'"))?;

                let domain = entity.split('.').next().unwrap_or("homeassistant");

                let resp = client
                    .post(format!("{}/api/services/{}/{}", base, domain, action))
                    .header("Authorization", &auth)
                    .json(&serde_json::json!({"entity_id": entity}))
                    .send()
                    .await?;

                if resp.status().is_success() {
                    Ok(format!("{} ejecutado en {}", action, entity))
                } else {
                    Ok(format!(
                        "Error ejecutando {}: HTTP {}",
                        action,
                        resp.status()
                    ))
                }
            }
            _ => Ok(format!(
                "Accion '{}' no soportada. Usa: turn_on, turn_off, toggle, status, list_entities",
                action
            )),
        }
    }

    // -----------------------------------------------------------------------
    // NEW: Tailscale status and sharing
    // -----------------------------------------------------------------------

    async fn execute_tailscale_status() -> Result<String> {
        let output = tokio::process::Command::new("tailscale")
            .args(["status", "--json"])
            .output()
            .await;

        match output {
            Ok(o) if o.status.success() => {
                let json: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_default();

                let self_name = json["Self"]["HostName"].as_str().unwrap_or("desconocido");
                let self_ip = json["Self"]["TailscaleIPs"][0].as_str().unwrap_or("?");
                let online = json["Self"]["Online"].as_bool().unwrap_or(false);

                let mut result = format!(
                    "Tailscale: {} ({})\nIP: {}\nEstado: {}\n\nDispositivos:",
                    self_name,
                    if online { "online" } else { "offline" },
                    self_ip,
                    if online { "conectado" } else { "desconectado" }
                );

                if let Some(peers) = json["Peer"].as_object() {
                    for (_key, peer) in peers.iter().take(15) {
                        result.push_str(&format!(
                            "\n- {} ({}) — {}",
                            peer["HostName"].as_str().unwrap_or("?"),
                            peer["TailscaleIPs"][0].as_str().unwrap_or("?"),
                            if peer["Online"].as_bool().unwrap_or(false) {
                                "online"
                            } else {
                                "offline"
                            }
                        ));
                    }
                }

                Ok(result)
            }
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr);
                Ok(format!(
                    "Tailscale no disponible: {}",
                    &stderr[..stderr.len().min(200)]
                ))
            }
            Err(_) => Ok("Tailscale no esta instalado.".into()),
        }
    }

    async fn execute_tailscale_share(args: &serde_json::Value) -> Result<String> {
        let port = args["port"]
            .as_u64()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'port'"))?;
        let mode = args["mode"].as_str().unwrap_or("serve");

        let cmd = match mode {
            "funnel" => {
                // Funnel = publicly accessible via HTTPS
                format!("tailscale funnel {} &", port)
            }
            _ => {
                // Serve = only accessible within tailnet
                format!("tailscale serve {} &", port)
            }
        };

        let output = tokio::process::Command::new("sh")
            .arg("-c")
            .arg(&cmd)
            .output()
            .await?;

        if output.status.success() {
            let hostname = tokio::process::Command::new("tailscale")
                .args(["status", "--json"])
                .output()
                .await
                .ok()
                .and_then(|o| serde_json::from_slice::<serde_json::Value>(&o.stdout).ok())
                .and_then(|j| j["Self"]["DNSName"].as_str().map(|s| s.to_string()))
                .unwrap_or_else(|| "tu-dispositivo.ts.net".into());

            let url = if mode == "funnel" {
                format!("https://{}:{}", hostname.trim_end_matches('.'), port)
            } else {
                format!("http://{}:{}", hostname.trim_end_matches('.'), port)
            };

            Ok(format!(
                "Puerto {} compartido via Tailscale {} en:\n{}",
                port, mode, url
            ))
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Ok(format!("Error: {}", &stderr[..stderr.len().min(300)]))
        }
    }

    // -----------------------------------------------------------------------
    // NEW: Sub-agent with different model
    // -----------------------------------------------------------------------

    async fn execute_sub_agent(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let task = args["task"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'task'"))?;
        let model = args["model"].as_str();
        let thinking = args["thinking"].as_str().unwrap_or("medium");

        let system_prompt = format!(
            "Eres un sub-agente especializado de LifeOS. Tu nivel de pensamiento es: {}.\n\
             Responde de forma concisa y directa en español.",
            thinking
        );

        let request = RouterRequest {
            messages: vec![
                ChatMessage {
                    role: "system".into(),
                    content: serde_json::Value::String(system_prompt),
                },
                ChatMessage {
                    role: "user".into(),
                    content: serde_json::Value::String(task.into()),
                },
            ],
            complexity: Some(TaskComplexity::Complex),
            sensitivity: None,
            preferred_provider: model.map(|m| m.to_string()),
            max_tokens: Some(2048),
        };

        let router = ctx.router.read().await;
        match router.chat(&request).await {
            Ok(r) => {
                log::debug!("[sub_agent] provider used: {}", r.provider);
                Ok(r.text)
            }
            Err(e) => Ok(format!("Error del sub-agente: {}", e)),
        }
    }

    // -----------------------------------------------------------------------
    // NEW: Skills system (SKILL.md based plugins)
    // -----------------------------------------------------------------------

    // Skills directory: ~/.config/lifeos/skills/<skill-name>/SKILL.md
    // SKILL.md contains: name, description, command, env_vars

    async fn execute_skill_list() -> Result<String> {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
        let skills_dir = format!("{}/.config/lifeos/skills", home);

        let mut entries = match tokio::fs::read_dir(&skills_dir).await {
            Ok(e) => e,
            Err(_) => {
                return Ok("No hay skills instalados. Directorio: ~/.config/lifeos/skills/".into())
            }
        };

        let mut skills = Vec::new();
        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            if path.is_dir() {
                let skill_md = path.join("SKILL.md");
                if skill_md.exists() {
                    let content = tokio::fs::read_to_string(&skill_md)
                        .await
                        .unwrap_or_default();
                    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("?");
                    // Extract description from first non-empty line after "# "
                    let desc = content
                        .lines()
                        .find(|l| !l.starts_with('#') && !l.trim().is_empty())
                        .unwrap_or("Sin descripcion");
                    skills.push(format!("- {} — {}", name, desc.trim()));
                }
            }
        }

        if skills.is_empty() {
            Ok("No hay skills instalados.\n\nPara crear uno:\n1. Crea ~/.config/lifeos/skills/<nombre>/SKILL.md\n2. En SKILL.md define: nombre, descripcion, y comando a ejecutar".into())
        } else {
            Ok(format!(
                "Skills instalados ({}):\n{}",
                skills.len(),
                skills.join("\n")
            ))
        }
    }

    async fn execute_skill_run(args: &serde_json::Value) -> Result<String> {
        let skill_name = args["skill"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'skill'"))?;
        let input = args["input"].as_str().unwrap_or("");

        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
        let skill_dir = format!("{}/.config/lifeos/skills/{}", home, skill_name);
        let skill_md = format!("{}/SKILL.md", skill_dir);

        let content = tokio::fs::read_to_string(&skill_md).await.map_err(|_| {
            anyhow::anyhow!("Skill '{}' no encontrado en {}", skill_name, skill_dir)
        })?;

        // Parse SKILL.md for command
        // Format: lines starting with "command:" contain the shell command
        let command = content
            .lines()
            .find(|l| l.trim().starts_with("command:"))
            .map(|l| l.trim().strip_prefix("command:").unwrap_or("").trim())
            .ok_or_else(|| anyhow::anyhow!("SKILL.md no contiene 'command:' line"))?;

        // Execute the command with input as argument
        let full_cmd = format!("cd '{}' && {} {}", skill_dir, command, shell_escape(input));
        let output = tokio::process::Command::new("sh")
            .arg("-c")
            .arg(&full_cmd)
            .output()
            .await?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);

        if output.status.success() {
            Ok(stdout[..stdout.len().min(4000)].to_string())
        } else {
            Ok(format!(
                "Skill '{}' fallo:\n{}\n{}",
                skill_name,
                &stdout[..stdout.len().min(2000)],
                &stderr[..stderr.len().min(500)]
            ))
        }
    }

    // -----------------------------------------------------------------------
    // NEW: Knowledge graph tools
    // -----------------------------------------------------------------------

    async fn execute_graph_add(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let subject = args["subject"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta 'subject'"))?;
        let predicate = args["predicate"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta 'predicate'"))?;
        let object = args["object"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta 'object'"))?;

        if let Some(memory) = &ctx.memory {
            let mem = memory.read().await;
            mem.add_triple(subject, predicate, object, 1.0, None)
                .await?;
            Ok(format!(
                "Relacion guardada: {} --[{}]--> {}",
                subject, predicate, object
            ))
        } else {
            Ok("Grafo de conocimiento no disponible (sin MemoryPlane)".into())
        }
    }

    async fn execute_graph_query(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let entity = args["entity"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta 'entity'"))?;

        if let Some(memory) = &ctx.memory {
            let mem = memory.read().await;
            let triples = mem.query_graph(entity, 20).await?;
            if triples.is_empty() {
                Ok(format!("No encontre relaciones para '{}'", entity))
            } else {
                let formatted: Vec<String> = triples
                    .iter()
                    .map(|t| {
                        format!(
                            "- {} --[{}]--> {} (confianza: {})",
                            t["subject"].as_str().unwrap_or("?"),
                            t["predicate"].as_str().unwrap_or("?"),
                            t["object"].as_str().unwrap_or("?"),
                            t["confidence"].as_f64().unwrap_or(0.0),
                        )
                    })
                    .collect();
                Ok(format!(
                    "Relaciones de '{}':\n{}",
                    entity,
                    formatted.join("\n")
                ))
            }
        } else {
            Ok("Grafo de conocimiento no disponible".into())
        }
    }

    // -----------------------------------------------------------------------
    // NEW: Procedural memory tools
    // -----------------------------------------------------------------------

    async fn execute_procedure_save(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let name = args["name"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta 'name'"))?;
        let description = args["description"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta 'description'"))?;
        let steps: Vec<String> = args["steps"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();
        let trigger = args["trigger"].as_str();

        if steps.is_empty() {
            anyhow::bail!("Se necesita al menos un paso en 'steps'");
        }

        if let Some(memory) = &ctx.memory {
            let mem = memory.read().await;
            let id = mem
                .save_procedure(name, description, &steps, trigger)
                .await?;
            Ok(format!("Procedimiento '{}' guardado (id: {})", name, id))
        } else {
            Ok("Memoria procedural no disponible".into())
        }
    }

    async fn execute_procedure_find(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let query = args["query"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta 'query'"))?;

        if let Some(memory) = &ctx.memory {
            let mem = memory.read().await;
            let procs = mem.find_procedures(query).await?;
            if procs.is_empty() {
                Ok(format!("No encontre procedimientos para '{}'", query))
            } else {
                let formatted: Vec<String> = procs
                    .iter()
                    .map(|p| {
                        let steps = p["steps"]
                            .as_array()
                            .map(|a| {
                                a.iter()
                                    .enumerate()
                                    .map(|(i, s)| {
                                        format!("  {}. {}", i + 1, s.as_str().unwrap_or("?"))
                                    })
                                    .collect::<Vec<_>>()
                                    .join("\n")
                            })
                            .unwrap_or_default();
                        format!(
                            "- {} (usado {}x)\n  {}\n{}",
                            p["name"].as_str().unwrap_or("?"),
                            p["times_used"].as_i64().unwrap_or(0),
                            p["description"].as_str().unwrap_or(""),
                            steps
                        )
                    })
                    .collect();
                Ok(format!(
                    "Procedimientos encontrados:\n{}",
                    formatted.join("\n\n")
                ))
            }
        } else {
            Ok("Memoria procedural no disponible".into())
        }
    }

    async fn execute_translate(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let text = args["text"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta 'text'"))?;
        let target_lang = args["target_lang"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta 'target_lang'"))?;
        let source_lang = args["source_lang"].as_str().map(|s| s.to_string());

        let engine = crate::translation::TranslationEngine::new(None);
        let req = crate::translation::TranslationRequest {
            text: text.to_string(),
            source_lang,
            target_lang: target_lang.to_string(),
        };

        let router = ctx.router.read().await;
        match engine.translate(&req, Some(&router)).await {
            Ok(result) => Ok(format!(
                "[{} -> {}] ({})\n{}",
                result.source_lang, result.target_lang, result.method, result.translated
            )),
            Err(e) => Ok(format!("Error de traduccion: {}", e)),
        }
    }

    fn shell_escape(s: &str) -> String {
        format!("'{}'", s.replace('\'', "'\\''"))
    }

    // -----------------------------------------------------------------------
    // NEW: SDD Orchestrator (Spec-Driven Development)
    // -----------------------------------------------------------------------

    /// SDD phase definitions: (name, prompt, model)
    fn sdd_phases() -> Vec<(&'static str, &'static str, &'static str)> {
        vec![
            ("Explorar", "Investiga la idea. Lee el codebase si es necesario. Compara enfoques posibles. NO crees archivos, solo analiza.", "groq-llama70b"),
            ("Proponer", "Basado en la exploracion, toma una decision arquitectonica. Explica el enfoque elegido y por que se descartaron las alternativas.", "cerebras-qwen235b"),
            ("Especificar", "Escribe los requisitos estructurados derivados de la propuesta. Lista: inputs, outputs, restricciones, edge cases, criterios de aceptacion.", "groq-llama70b"),
            ("Disenar", "Define la arquitectura de implementacion: archivos a crear/modificar, interfaces, dependencias, patrones a usar. Se especifico.", "cerebras-qwen235b"),
            ("Tareas", "Desglosa el diseno en tareas mecanicas accionables. Cada tarea debe ser implementable en un solo paso. Numera las tareas.", "groq-llama70b"),
            ("Implementar", "Implementa TODAS las tareas del paso anterior. Escribe el codigo completo. Usa run_command para crear archivos y ejecutar comandos.", "groq-llama70b"),
            ("Verificar", "Valida la implementacion contra la especificacion. Ejecuta tests si existen. Reporta: OK, WARNING (funciona pero mejorable), o ERROR (no cumple spec).", "groq-llama70b"),
            ("Archivar", "Resume lo que se hizo: que se creo, que decisiones se tomaron, que se aprendio. Guarda todo en memoria persistente.", "groq-llama8b"),
        ]
    }

    /// Run SDD phases from `start_phase` until a checkpoint or end.
    /// Returns (result_text, paused_at_checkpoint, sdd_session_id).
    pub async fn run_sdd_phases(
        ctx: &ToolContext,
        task: &str,
        chat_id: i64,
        start_phase: usize,
        mut accumulated: String,
        mut prev_output: String,
    ) -> (String, bool, String) {
        let phases = sdd_phases();
        let total = phases.len();
        let sdd_id = format!("sdd-{}-{}", chat_id, chrono::Utc::now().timestamp_millis());

        for (i, (phase_name, phase_prompt, model)) in phases.iter().enumerate().skip(start_phase) {
            info!(
                "[sdd] Phase {}/{}: {} (model: {})",
                i + 1,
                total,
                phase_name,
                model
            );

            let phase_task = format!(
                "## SDD Fase {}/{}: {}\n\nTarea original: {}\n\n{}\n\n{}",
                i + 1,
                total,
                phase_name,
                task,
                phase_prompt,
                if prev_output.is_empty() {
                    String::new()
                } else {
                    format!(
                        "Resultado de la fase anterior:\n{}",
                        &prev_output[..prev_output.len().min(3000)]
                    )
                }
            );

            let request = RouterRequest {
                messages: vec![
                    ChatMessage {
                        role: "system".into(),
                        content: serde_json::Value::String(
                            "Eres un sub-agente SDD de LifeOS. Ejecuta SOLO la fase indicada. Conciso y directo. En espanol.".into(),
                        ),
                    },
                    ChatMessage {
                        role: "user".into(),
                        content: serde_json::Value::String(phase_task),
                    },
                ],
                complexity: Some(TaskComplexity::Complex),
                sensitivity: None,
                preferred_provider: Some(model.to_string()),
                max_tokens: Some(2048),
            };

            let router = ctx.router.read().await;
            match router.chat(&request).await {
                Ok(r) => {
                    prev_output = r.text.clone();
                    accumulated.push_str(&format!(
                        "\n--- Fase {}: {} [{}] ---\n{}\n",
                        i + 1,
                        phase_name,
                        r.provider,
                        r.text
                    ));
                }
                Err(e) => {
                    accumulated.push_str(&format!(
                        "\n--- Fase {}: {} [ERROR] ---\n{}\n",
                        i + 1,
                        phase_name,
                        e
                    ));
                }
            }
            drop(router);

            // Check if this is a checkpoint phase — pause for user approval
            if is_checkpoint_phase(i) && i + 1 < total {
                let session = SddSession {
                    id: sdd_id.clone(),
                    task: task.to_string(),
                    chat_id,
                    current_phase: i + 1, // next phase to run
                    accumulated_result: accumulated.clone(),
                    prev_output: prev_output.clone(),
                    created_at: chrono::Utc::now(),
                };
                ctx.sdd_store.save(session).await;
                return (accumulated, true, sdd_id);
            }
        }

        // All phases done — save to memory
        sdd_save_to_memory(ctx, task, &accumulated).await;
        (accumulated, false, sdd_id)
    }

    async fn sdd_save_to_memory(ctx: &ToolContext, task: &str, result: &str) {
        if let Some(memory) = &ctx.memory {
            let mem = memory.read().await;
            let tags = vec!["sdd".to_string(), "architecture".to_string()];
            let summary = format!(
                "[architecture] SDD: {}\ntopic: sdd:{}\n{}",
                task,
                task.split_whitespace()
                    .take(3)
                    .collect::<Vec<_>>()
                    .join("-"),
                &result[..result.len().min(2000)]
            );
            mem.add_entry("architecture", "user", &tags, Some("sdd"), 80, &summary)
                .await
                .ok();
        }
    }

    async fn execute_sdd_start(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let task = args["task"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'task'"))?;
        let chat_id = args["_chat_id"].as_i64().unwrap_or(0);

        let header = format!("== SDD: {} ==\n", task);
        let (result, paused, sdd_id) =
            run_sdd_phases(ctx, task, chat_id, 0, header, String::new()).await;

        if paused {
            Ok(format!(
                "{}\n\n--- CHECKPOINT ---\nAxi necesita tu aprobacion para continuar.\nSDD ID: {}\n(Se enviaron botones de aprobacion)",
                result, sdd_id
            ))
        } else {
            Ok(result)
        }
    }

    /// Continue an SDD session after user approval.
    pub async fn sdd_continue(
        ctx: &ToolContext,
        sdd_id: &str,
    ) -> Option<(String, bool, String, i64)> {
        let session = ctx.sdd_store.remove(sdd_id).await?;
        let (result, paused, new_id) = run_sdd_phases(
            ctx,
            &session.task,
            session.chat_id,
            session.current_phase,
            session.accumulated_result,
            session.prev_output,
        )
        .await;
        Some((result, paused, new_id, session.chat_id))
    }

    /// Abort an SDD session — save what was done to memory.
    pub async fn sdd_abort(ctx: &ToolContext, sdd_id: &str) -> Option<String> {
        let session = ctx.sdd_store.remove(sdd_id).await?;
        sdd_save_to_memory(ctx, &session.task, &session.accumulated_result).await;
        Some(format!(
            "SDD abortado en fase {}. Resultado parcial guardado en memoria.\n\n{}",
            session.current_phase,
            &session.accumulated_result[..session.accumulated_result.len().min(2000)]
        ))
    }

    // -----------------------------------------------------------------------
    // Session summary — saves conversation context to persistent memory
    // -----------------------------------------------------------------------

    // Auto-save a session summary when conversation is cleared or expires
    pub async fn save_session_summary(ctx: &ToolContext, chat_id: i64, messages: &[ChatMessage]) {
        if messages.is_empty() {
            return;
        }

        // Build a summary prompt from conversation messages
        let mut conversation = String::new();
        for msg in messages.iter().take(20) {
            let role = &msg.role;
            let content = msg.content.as_str().unwrap_or("[media]");
            conversation.push_str(&format!(
                "[{}]: {}\n",
                role,
                &content[..content.len().min(200)]
            ));
        }

        let summary_prompt = format!(
            "Resume esta conversacion en un parrafo conciso. Incluye: objetivo del usuario, que se logro, decisiones tomadas, y proximos pasos si los hay.\n\n{}",
            conversation
        );

        let request = RouterRequest {
            messages: vec![ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(summary_prompt),
            }],
            complexity: Some(TaskComplexity::Simple),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(512),
        };

        let router = ctx.router.read().await;
        let summary_text = match router.chat(&request).await {
            Ok(r) => r.text,
            Err(_) => {
                // Fallback: just save the last few messages
                messages
                    .iter()
                    .rev()
                    .take(5)
                    .filter_map(|m| m.content.as_str())
                    .collect::<Vec<_>>()
                    .join(" | ")
            }
        };
        drop(router);

        // Save to persistent memory
        if let Some(memory) = &ctx.memory {
            let mem = memory.read().await;
            let tags = vec!["session_summary".to_string()];
            let content = format!(
                "[decision] Session summary (chat {})\ntopic: session:chat-{}\n{}",
                chat_id, chat_id, summary_text
            );
            mem.add_entry("decision", "user", &tags, Some("session"), 60, &content)
                .await
                .ok();
            info!("[engram] Session summary saved for chat {}", chat_id);
        }
    }

    // -----------------------------------------------------------------------
    // Helper
    // -----------------------------------------------------------------------

    fn expand_home(path: &str) -> String {
        if path.starts_with('~') {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
            path.replacen('~', &home, 1)
        } else {
            path.to_string()
        }
    }

    use tokio::io::AsyncWriteExt;
}

#[cfg(feature = "telegram")]
pub use inner::*;
