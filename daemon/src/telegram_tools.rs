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
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use tokio::sync::RwLock;

    use crate::browser_automation::BrowserAutomation;
    use crate::computer_use::{ComputerUseAction, ComputerUseManager};
    use crate::llm_router::{ChatMessage, LlmRouter, RouterRequest, TaskComplexity};
    use crate::memory_plane::{
        extract_entities_from_text, BookStatus, GoalStatus, MemoryPlaneManager,
    };
    use crate::proactive;
    use crate::session_store::{SessionKey, SessionStore, TranscriptTurn};
    use crate::task_queue::TaskQueue;
    use crate::user_model::UserModel;

    /// Maximum tool execution rounds per message to prevent infinite loops.
    const MAX_TOOL_ROUNDS: usize = 5;
    /// Conversation history TTL in seconds (48 hours — long-running sessions).
    const HISTORY_TTL_SECS: i64 = 48 * 3600;
    /// Hard cap for commands triggered remotely from Telegram.
    const TELEGRAM_TOOL_MAX_COMMAND_CHARS: usize = 2048;
    /// Timeout for a single run_command execution.
    const TELEGRAM_RUN_COMMAND_TIMEOUT_SECS: u64 = 60;
    /// Maximum size for a file that Telegram tools may read/write/send directly.
    const TELEGRAM_TOOL_MAX_FILE_BYTES: u64 = 128 * 1024;
    /// Maximum characters returned from a file read.
    const TELEGRAM_TOOL_MAX_READ_CHARS: usize = 6000;
    /// Environment variable with colon-separated allowed paths for Telegram file tools.
    const TELEGRAM_ALLOWED_PATHS_ENV: &str = "LIFEOS_TELEGRAM_ALLOWED_PATHS";
    /// Optional safe working directory for Telegram run_command/write_file relative paths.
    const TELEGRAM_WORKDIR_ENV: &str = "LIFEOS_TELEGRAM_WORKDIR";

    // -----------------------------------------------------------------------
    // Tool definitions (shown to the LLM in the system prompt)
    // -----------------------------------------------------------------------

    const SYSTEM_PROMPT_BASE: &str = r#"Eres Axi, el asistente personal de LifeOS — un ajolote digital amigable, inteligente y protector. Vives dentro del sistema operativo del usuario (LifeOS, un Linux inmutable basado en Fedora) y puedes hacer cosas reales en su computadora.

PERSONALIDAD: Eres amigable y accesible (nunca intimidante), inteligente pero no pretencioso, y protector de la privacidad del usuario. Hablas como un amigo cercano que sabe mucho de tecnologia.

## Identidad
- Mi nombre es Axi, el asistente AI de LifeOS.
- Fui creado y programado por **Hector Martinez Resediz** (hectormr.com).
- LifeOS es un sistema operativo AI-native basado en Fedora bootc.
- Si alguien pregunta quien me creo, quien es mi desarrollador, o quien me programo,
  SIEMPRE respondo: "Fui creado por Hector Martinez Resediz (hectormr.com),
  el fundador y desarrollador de LifeOS."
- NUNCA invento otros creadores ni atribuyo mi creacion a nadie mas.

## Reglas estrictas (CRITICAS — violar estas reglas es inaceptable)
- NUNCA inventes contenido de archivos, carpetas, o resultados de comandos.
- Si no ejecutaste una herramienta para verificar algo, di "no lo he verificado, dejame revisarlo".
- NUNCA adivines la estructura de un proyecto — usa list_files o run_command para verificar.
- Cuando el usuario te pregunte sobre sus archivos, SIEMPRE usa una herramienta primero.

DATOS DEL SISTEMA (REGLA ABSOLUTA):
- NUNCA inventes datos de disco, RAM, CPU, bateria, temperatura o cualquier metrica del sistema.
- Si el usuario pregunta por espacio en disco, memoria RAM, procesos, o estado del sistema, SIEMPRE usa la herramienta system_status o run_command ANTES de responder.
- Si no puedes ejecutar la herramienta por cualquier razon, di EXACTAMENTE: "No puedo verificar eso ahora mismo. Quieres que lo intente con otro metodo?"
- NUNCA respondas con numeros aproximados o inventados. Los datos del sistema deben ser EXACTOS o no darse.
- Es MEJOR decir "no lo se" que inventar un dato incorrecto. Un dato inventado es una mentira.

IMPORTANTE: Responde siempre en español mexicano, de forma natural y concisa. No uses markdown. Tienes memoria de la conversacion — puedes referirte a mensajes anteriores. Nunca respondas con saludos genericos — siempre aporta algo util o pregunta algo especifico.

VISION: Si recibes una imagen, SIEMPRE describela y responde sobre ella. Si no puedes ver la imagen (el modelo no soporta vision), dile al usuario: "No puedo ver imagenes en este momento, ¿me la describes?"

MENSAJES DE VOZ: Cuando recibes un mensaje de voz del usuario, el sistema YA lo transcribio automaticamente usando Whisper. El texto que ves ES la transcripcion del audio. NUNCA digas que no puedes escuchar o analizar audio — ya lo hiciste. Responde directamente al contenido transcrito.

GESTION DE SERVICIOS: Puedes administrar servicios del sistema usando la herramienta service_manage. Si el usuario te pide activar el firewall, usa service=firewalld (es el firewall por defecto de Fedora/LifeOS). Servicios disponibles: nftables, firewalld, llama-server, whisper-stt.

REGLAS DE TIEMPO:
- SIEMPRE usa la hora del [Contexto temporal] mostrado arriba. NUNCA inventes una hora.
- Cuando el usuario diga "manana", "en 2 horas", "el lunes", calcula la fecha/hora EXACTA.
- SIEMPRE confirma la hora calculada: "Te recuerdo el lunes 31 de marzo a las 15:00 (CST)."
- Para programar tareas usa la herramienta cron_add con la hora EXACTA en formato cron.
- Si no estas seguro de la hora que quiere el usuario, PREGUNTA.

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

10. **recall** — Busca en memoria persistente (la memoria activa, lo que esta vivo).
    args: {"query": "preferencias del usuario"}

10b. **recall_archived** — Busca en el ARCHIVO de memoria. El sistema mueve automaticamente al archivo las memorias que dejaron de ser relevantes (poco accedidas + importancia baja + viejas), para que la busqueda activa quede limpia. Pero esas memorias NO se borran: viven en el archivo y se pueden recuperar con esta herramienta. Usala cuando el usuario diga frases como "tenia una idea pero ya no recuerdo cual era", "que paso con aquel proyecto que pause hace meses", "creo que te conte algo importante hace tiempo, ¿que era?", o cuando `recall` no encuentre nada y sospeches que el dato es viejo. Si encuentras algo aqui, MENCIONA explicitamente que es del archivo para que el usuario sepa que es algo que se habia "enfriado".
    args: {"query": "proyecto pausado o idea olvidada"}

## Salud (Vida Plena BI.2)

LifeOS guarda salud medica estructurada con las siguientes herramientas. **Reglas absolutas:** NUNCA diagnostiques, NUNCA prescribas medicamentos, NUNCA reemplazes a un medico real. Solo registras lo que el usuario te dice y le ayudas a llevar su historial. Si el usuario describe sintomas preocupantes, recomienda ver a un medico. Toda esta informacion es PERMANENTE — nunca se borra ni se pierde.

10c. **health_fact_add** — Registra un hecho permanente de salud (alergia, condicion cronica, tipo de sangre, contacto de emergencia). Auto-permanente.
    args: {"fact_type": "allergy", "label": "Penicilina", "severity": "severe", "notes": "Reaccion en 2024"}
    fact_type: allergy, condition, blood_type, emergency_contact, donor, insurance, other
    severity (opcional): mild, moderate, severe, life_threatening

10d. **health_fact_list** — Lista los hechos de salud guardados, opcionalmente filtrados por tipo.
    args: {"fact_type": "allergy"} o {} para ver todos

10e. **medication_start** — Registra que el usuario empieza a tomar un medicamento. Si ya tomaba ese mismo medicamento con otra dosis, primero usa medication_stop con el med_id viejo. Cada cambio de dosis es un row nuevo (history table).
    args: {"name": "Metformina", "dosage": "500mg", "frequency": "cada 12h", "condition": "diabetes tipo 2", "prescribed_by": "Dr. Lopez", "notes": "Con la comida"}

10f. **medication_stop** — Marca que el usuario dejo de tomar un medicamento. Necesitas el med_id (lo obtienes con medication_active).
    args: {"med_id": "hmed-..."}

10g. **medication_active** — Lista los medicamentos que el usuario esta tomando ACTUALMENTE (los que no tienen ended_at).
    args: {}

10h. **vital_record** — Registra una lectura de signo vital. Para presion arterial, registra los DOS valores (sistolica y diastolica) como dos llamadas separadas con el mismo measured_at.
    args: {"vital_type": "glucose", "value_numeric": 110, "unit": "mg/dL", "context": "en ayunas"}
    Tipos comunes: glucose, weight, blood_pressure_systolic, blood_pressure_diastolic, heart_rate_resting, temperature, oxygen_saturation, sleep_hours, mood, pain_intensity, migraine_intensity

10i. **vital_history** — Devuelve la serie temporal de un tipo de vital, mas reciente primero.
    args: {"vital_type": "glucose", "limit": 30}

10j. **lab_add** — Registra el resultado de un analisis de laboratorio.
    args: {"test_name": "HbA1c", "value_numeric": 6.4, "unit": "%", "reference_low": 0, "reference_high": 5.7, "lab_name": "Salud Digna", "notes": "Tomado en ayunas"}

10k. **health_summary** — Devuelve el resumen completo de salud del usuario: hechos permanentes + medicamentos activos + vitales recientes + analisis recientes. Usalo cuando el usuario te pida prepararse para una visita medica o quiera revisar todo su historial.
    args: {}

## Crecimiento personal (Vida Plena BI.7)

LifeOS lleva el registro de lectura, habitos y metas a largo plazo del usuario. **No eres coach certificado**: las recomendaciones son generales, los recursos son sugerencias. Acompañas la disciplina del usuario, no la impones. Toda esta informacion tambien es PERMANENTE.

10l. **book_add** — Registra un libro en el reading log. status: wishlist (quiere leerlo), reading (leyendo ahora), finished (terminado), abandoned (lo dejo).
    args: {"title": "Atomic Habits", "author": "James Clear", "status": "reading", "notes": "Capitulo 4 me hizo click sobre habit stacking"}

10m. **book_status_set** — Cambia el status de un libro. Para terminar uno, usa status=finished y opcionalmente rating de 1 a 5.
    args: {"book_id": "book-...", "status": "finished", "rating_1_5": 5}

10n. **book_list** — Lista los libros del usuario, opcionalmente filtrados por status.
    args: {"status": "reading"} o {} para todos

10o. **habit_add** — Crea un habito que el usuario quiere construir. frequency es texto libre: "daily", "weekly:3", "custom:MO,WE,FR".
    args: {"name": "Meditar 10 minutos", "frequency": "daily", "description": "Por la mañana antes de cafe"}

10p. **habit_checkin** — Registra el check-in de un habito en una fecha especifica. logged_for_date es YYYY-MM-DD en la zona local del usuario. Marcar dos veces el mismo dia simplemente sobreescribe (idempotente).
    args: {"habit_id": "habit-...", "completed": true, "logged_for_date": "2026-04-06", "notes": "Antes de las 7am"}

10q. **habit_active** — Lista los habitos activos del usuario.
    args: {}

10r. **goal_add** — Registra una meta a largo plazo (carrera, finanzas, salud, lo que sea). Empieza con progress 0 y status active.
    args: {"name": "Aprender Rust al nivel de poder contribuir a un proyecto open source", "deadline": "2026-12-31", "description": "Trabajando con LifeOS me esta ayudando"}

10s. **goal_progress** — Actualiza el progreso (0-100) de una meta y opcionalmente cambia el status. Si pones progress=100 sin status explicito, automaticamente queda como achieved.
    args: {"goal_id": "goal-...", "progress_pct": 60}

10t. **growth_summary** — Devuelve el resumen completo de crecimiento personal: libros que esta leyendo + libros recien terminados + habitos activos con su streak de los ultimos 30 dias + metas activas. Usalo cuando el usuario te pida revisar como va con sus metas o cuando quiera reflexionar sobre su progreso.
    args: {"today": "2026-04-06"}

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

33. **audit_query** — Consulta que hizo Axi en un periodo. Muestra tareas, resultados y confiabilidad.
    args: {"period": "24h"}
    Periodos validos: "1h", "6h", "12h", "24h", "7d". Por defecto: "24h".

34. **current_time** — Devuelve la fecha y hora actual exacta con zona horaria. Usar cuando necesites precision.
    args: {} (sin parametros)

35. **search_memories_by_date** — Busca memorias en un rango de fecha/hora.
    args: {"date": "2026-03-28", "time_from": "18:00", "time_to": "23:59"}
    Si no se pone time_from/time_to, busca todo el dia. La fecha se interpreta en tu zona horaria local.

36. **add_provider** — Agrega un nuevo proveedor de LLM. El usuario dice el nombre del provider y modelo.
    args: {"provider_base": "openrouter|cerebras|groq|custom", "model": "nvidia/nemotron-ultra", "api_base": "https://...", "api_key_env": "OPENROUTER_API_KEY"}
    provider_base y model son obligatorios. api_base y api_key_env se infieren si el provider_base es conocido.

37. **list_providers** — Lista todos los proveedores de LLM configurados con su estado.
    args: {}

38. **remove_provider** — Elimina un proveedor de LLM del archivo de configuracion.
    args: {"name": "openrouter-nvidia-nemotron-ultra"}

39. **disable_provider** — Deshabilita (o habilita) un proveedor de LLM sin eliminarlo.
    args: {"name": "openrouter-nvidia-nemotron-ultra", "enable": false}
    Si enable=true, reactiva el proveedor.

40. **send_file** — Envia un archivo al usuario via Telegram.
    args: {"path": "/home/lifeos/documento.pdf"}

41. **export_conversation** — Exporta la conversacion actual como archivo de texto y lo envia al usuario.
    args: {"format": "txt"}
    Formatos: "txt" (por defecto), "json". Genera el archivo y lo envia automaticamente.

42. **windows_list** — Lista todas las ventanas abiertas (titulo, app, posicion).
    args: {} (sin parametros)

43. **windows_focus** — Enfoca una ventana por titulo o app_id.
    args: {"title": "Firefox"} o {"app_id": "org.mozilla.firefox"}

44. **windows_close** — Cierra una ventana por titulo o app_id.
    args: {"title": "Firefox"} o {"app_id": "org.mozilla.firefox"}

45. **apps_launch** — Lanza una aplicacion por nombre o archivo .desktop.
    args: {"app": "firefox"} o {"desktop": "org.mozilla.firefox.desktop"}

46. **clipboard_get** — Obtiene el contenido del portapapeles.
    args: {} (sin parametros)

47. **clipboard_set** — Copia texto al portapapeles.
    args: {"content": "texto a copiar"}

48. **volume_get** — Obtiene el volumen actual del audio.
    args: {} (sin parametros)

49. **volume_set** — Ajusta el volumen del audio (0.0 a 1.0).
    args: {"level": 0.75}

50. **brightness_get** — Obtiene el brillo actual de la pantalla.
    args: {} (sin parametros)

51. **brightness_set** — Ajusta el brillo de la pantalla (0-100).
    args: {"level": 80}

52. **workspaces_list** — Lista todos los espacios de trabajo (workspaces) con su nombre y estado.
    args: {} (sin parametros)

53. **workspaces_switch** — Cambia al espacio de trabajo indicado.
    args: {"workspace": "3"} o {"workspace": "coding"}

54. **cosmic_terminal** — Abre la terminal COSMIC, opcionalmente ejecutando un comando.
    args: {"command": "htop"} (opcional)

55. **cosmic_files** — Abre el gestor de archivos COSMIC, opcionalmente en una ruta.
    args: {"path": "/home/lifeos/Documentos"} (opcional)

56. **cosmic_editor** — Abre el editor de texto COSMIC, opcionalmente con un archivo.
    args: {"file": "/home/lifeos/notas.txt"} (opcional)

57. **cosmic_dark_mode** — Activa o desactiva el modo oscuro de COSMIC.
    args: {"enabled": true}

58. **calc_read_cells** — Lee celdas de una hoja de calculo LibreOffice.
    args: {"file": "presupuesto.ods", "range": "A1:D10"}

59. **writer_export_pdf** — Exporta un documento de LibreOffice Writer a PDF.
    args: {"input": "/home/lifeos/doc.odt", "output": "/home/lifeos/doc.pdf"}

60. **a11y_tree** — Obtiene el arbol de accesibilidad de una aplicacion (botones, menus, campos).
    args: {"app": "firefox", "depth": 3}

61. **a11y_find** — Busca elementos UI por rol y/o nombre en el arbol de accesibilidad.
    args: {"app": "firefox", "role": "push button", "name": "Save"}

62. **a11y_activate** — Activa (click/press) un elemento UI por su path de accesibilidad.
    args: {"bus_name": ":1.42", "path": "/org/a11y/atspi/accessible/123"}

63. **a11y_get_text** — Lee el texto de un elemento UI.
    args: {"bus_name": ":1.42", "path": "/org/a11y/atspi/accessible/123"}

64. **a11y_set_text** — Escribe texto en un elemento editable.
    args: {"bus_name": ":1.42", "path": "/org/a11y/atspi/accessible/123", "text": "Hello"}

65. **a11y_apps** — Lista todas las aplicaciones registradas en el bus AT-SPI2.
    args: {}

66. **health_status** — Estado de salud del usuario: tiempo activo, breaks, sesion actual.
    args: {}

67. **calendar_today** — Eventos programados para hoy.
    args: {}

68. **calendar_add** — Agregar evento al calendario.
    args: {"title": "Dialisis suegro", "date": "2026-04-02", "time": "10:00", "reminder_minutes": 30}

69. **current_context** — En que contexto esta el usuario (work, personal, gaming, etc).
    args: {}

70. **current_mode** — Modo de experiencia activo (Simple, Pro, Builder).
    args: {}

71. **learned_patterns** — Patrones de comportamiento detectados por el sistema.
    args: {}

72. **gaming_status** — Estado actual de gaming: jugando?, que juego?, GPU status.
    args: {}

73. **meeting_recall** — Buscar transcripciones o resumenes de reuniones pasadas.
    args: {"query": "reunion de ayer"}

74. **security_status** — Estado de seguridad: amenazas recientes, alertas activas.
    args: {}

75. **activity_summary** — Resumen de actividad: apps usadas, tiempo por app.
    args: {}

76. **screenshot_recall** — Buscar capturas de pantalla recientes por descripcion.
    args: {"query": "firefox gmail"}

77. **memory_cleanup** — Muestra estadisticas de memoria y ejecuta limpieza (garbage filter + decay + dedup).
    args: {}

78. **memory_protect** — Marca una memoria como permanente (nunca se borra ni decae).
    args: {"query": "nombre de mi suegro"}

79. **service_manage** — Gestiona servicios del sistema (firewall, llama-server, whisper, etc).
    args: {"service": "nftables", "action": "start"}
    Servicios permitidos: nftables, firewalld, llama-server, whisper-stt
    Acciones: start, stop, restart, enable, disable, status
    SEGURIDAD: Solo servicios en la lista blanca. Para activar firewall, usa service=firewalld action=start (Fedora usa firewalld por defecto, no nftables directo).

80. **meeting_list** — Lista las reuniones recientes con resumen.
    args: {"limit": 5}

81. **meeting_search** — Busca en las transcripciones de reuniones.
    args: {"query": "presupuesto Q2"}

82. **meeting_start** — Inicia grabacion manual de reunion (presencial o manual).
    args: {"description": "Junta con equipo de desarrollo"}

83. **meeting_stop** — Detiene la grabacion manual de reunion.
    args: {}

84. **agenda** — Muestra tu agenda completa: eventos del calendario, cron jobs y tareas programadas.
    args: {"days": 1}

## Reglas

- Puedes usar MULTIPLES herramientas en una respuesta.
- NUNCA inventes resultados — usa herramientas para datos reales.
- SIEMPRE guarda en memoria decisiones, descubrimientos y preferencias (protocolo obligatorio).
- Cuando descubras RELACIONES entre entidades, usa graph_add para guardarlas (ej: "usuario prefiere X", "proyecto usa Y").
- Cuando aprendas un PROCEDIMIENTO (secuencia de pasos para lograr algo), usa procedure_save.
- Si el usuario dice "y eso?", busca en memoria con recall o refierete al contexto previo.
"#;

    /// Build the full system prompt with live time context and user model prepended.
    /// Must be called fresh for every LLM request (never cache).
    fn build_system_prompt(user_model: Option<&UserModel>) -> String {
        let personalization = user_model
            .map(|m| m.prompt_instructions())
            .unwrap_or_default();
        format!(
            "{}\n\n{}{}\n",
            crate::time_context::time_context(),
            if personalization.is_empty() {
                String::new()
            } else {
                format!("{}\n", personalization)
            },
            SYSTEM_PROMPT_BASE
        )
    }

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
                "{home}/.local/share/lifeos/conversation_history.json"
            ));
            Self::with_persist_path(persist_path)
        }

        fn with_persist_path(persist_path: std::path::PathBuf) -> Self {
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
        /// Returns: [first_message] + [recent_messages]
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

                // 2. Recent messages (verbatim)
                result.extend(entry.messages.clone());

                return result;
            }
            Vec::new()
        }

        pub async fn get_compacted_summary(&self, chat_id: i64) -> Option<String> {
            let chats = self.chats.read().await;
            let entry = chats.get(&chat_id)?;
            let age = chrono::Utc::now()
                .signed_duration_since(entry.last_active)
                .num_seconds();
            if age >= HISTORY_TTL_SECS {
                return None;
            }
            entry.compacted_summary.clone()
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

    #[cfg(test)]
    mod tests {
        use super::*;

        fn history_for_tests(name: &str) -> ConversationHistory {
            let unique = format!(
                "lifeos-telegram-history-{}-{}-{}.json",
                name,
                std::process::id(),
                chrono::Utc::now().timestamp_nanos_opt().unwrap_or_default()
            );
            let path = std::env::temp_dir().join(unique);
            let _ = std::fs::remove_file(&path);
            ConversationHistory::with_persist_path(path)
        }

        #[tokio::test]
        async fn history_get_keeps_system_context_out_of_message_list() {
            let history = history_for_tests("messages-only");
            let chat_id = 42;

            history
                .append(
                    chat_id,
                    &[
                        ChatMessage {
                            role: "user".into(),
                            content: serde_json::Value::String("hola".into()),
                        },
                        ChatMessage {
                            role: "assistant".into(),
                            content: serde_json::Value::String("que onda".into()),
                        },
                    ],
                )
                .await;

            {
                let mut chats = history.chats.write().await;
                if let Some(entry) = chats.get_mut(&chat_id) {
                    entry.compacted_summary = Some("preferencia: respuestas cortas".into());
                }
            }

            let messages = history.get(chat_id).await;
            assert_eq!(messages.len(), 3);
            assert!(messages.iter().all(|msg| msg.role != "system"));
            assert_eq!(
                history.get_compacted_summary(chat_id).await,
                Some("preferencia: respuestas cortas".into())
            );
        }

        #[test]
        fn parse_safe_command_rejects_shell_operators() {
            let roots = vec![PathBuf::from("/tmp/lifeos-telegram-tests")];
            let workdir = roots[0].clone();
            let err = parse_safe_command("rg todo . && rm -rf /", &roots, &workdir)
                .expect_err("shell operators should be rejected");
            assert!(err.to_string().contains("Operador de shell"));
        }

        #[test]
        fn parse_safe_command_rejects_paths_outside_allowed_roots() {
            let roots = vec![PathBuf::from("/tmp/lifeos-telegram-tests")];
            let workdir = roots[0].clone();
            let err = parse_safe_command("cat /etc/passwd", &roots, &workdir)
                .expect_err("reading /etc should be rejected");
            assert!(err.to_string().contains("fuera de las permitidas"));
        }

        #[test]
        fn path_policy_allows_descendants_of_allowed_root() {
            let roots = vec![PathBuf::from("/var/home/lifeos/personalProjects")];
            let resolved = resolve_tool_path(
                "/var/home/lifeos/personalProjects/gama/lifeos/README.md",
                &roots,
            )
            .expect("repo file should be allowed");
            assert!(resolved.starts_with(&roots[0]));
        }

        #[test]
        fn simple_glob_match_supports_basic_wildcards() {
            assert!(simple_glob_match("*.rs", "main.rs"));
            assert!(simple_glob_match("file-??.txt", "file-01.txt"));
            assert!(!simple_glob_match("*.rs", "main.py"));
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
        let alerts = proactive::check_all(None, None).await;

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
        // Check /var only (not / which is composefs overlay, always 100% by design on bootc)
        if let Ok(o) = tokio::process::Command::new("df")
            .args(["-h", "/var"])
            .output()
            .await
        {
            system_data.push_str(&format!(
                "\nDisco (/var — particion principal):\n{}\n",
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
                    Some(format!("Reporte de Axi:\n\n{}\n\n[{}]", text, r.provider))
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
                    text.push_str("\n\n[sistema — sin LLM]");
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
        pub history: Arc<ConversationHistory>,
        pub cron_store: Arc<CronStore>,
        pub sdd_store: Arc<SddStore>,
        /// Persistent session store — parallel to in-memory history for durability.
        pub session_store: Option<Arc<SessionStore>>,
        /// User model for personalized responses (Fase AQ).
        pub user_model: Option<Arc<RwLock<UserModel>>>,
        /// Meeting archive for structured meeting storage and search.
        pub meeting_archive: Option<Arc<crate::meeting_archive::MeetingArchive>>,
        /// Meeting assistant for manual meeting start/stop.
        pub meeting_assistant: Option<Arc<RwLock<crate::meeting_assistant::MeetingAssistant>>>,
        /// Calendar manager for event scheduling and reminders.
        pub calendar: Option<Arc<crate::calendar::CalendarManager>>,
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
            "cuando fue",
            "que comimos",
            "que hicimos",
            "que paso",
            "que decidimos",
            "que me dijiste",
            "que te dije",
            "la ultima vez",
            "hace cuanto",
            "el otro dia",
            "que guardaste",
            "que sabes de",
            "que recuerdas",
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
            "recall_archived" => execute_recall_archived(&call.args, ctx).await,
            // BI.2 — Salud médica estructurada
            "health_fact_add" => execute_health_fact_add(&call.args, ctx).await,
            "health_fact_list" => execute_health_fact_list(&call.args, ctx).await,
            "medication_start" => execute_medication_start(&call.args, ctx).await,
            "medication_stop" => execute_medication_stop(&call.args, ctx).await,
            "medication_active" => execute_medication_active(ctx).await,
            "vital_record" => execute_vital_record(&call.args, ctx).await,
            "vital_history" => execute_vital_history(&call.args, ctx).await,
            "lab_add" => execute_lab_add(&call.args, ctx).await,
            "health_summary" => execute_health_summary(ctx).await,
            // BI.7 — Crecimiento personal
            "book_add" => execute_book_add(&call.args, ctx).await,
            "book_status_set" => execute_book_status_set(&call.args, ctx).await,
            "book_list" => execute_book_list(&call.args, ctx).await,
            "habit_add" => execute_habit_add(&call.args, ctx).await,
            "habit_checkin" => execute_habit_checkin(&call.args, ctx).await,
            "habit_active" => execute_habit_active(ctx).await,
            "goal_add" => execute_goal_add(&call.args, ctx).await,
            "goal_progress" => execute_goal_progress(&call.args, ctx).await,
            "growth_summary" => execute_growth_summary(&call.args, ctx).await,
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
            "audit_query" => execute_audit_query(&call.args).await,
            "current_time" => Ok(crate::time_context::time_context()),
            "search_memories_by_date" => execute_search_memories_by_date(&call.args, ctx).await,
            "add_provider" => execute_add_provider(&call.args, ctx).await,
            "list_providers" => execute_list_providers(ctx).await,
            "remove_provider" => execute_remove_provider(&call.args, ctx).await,
            "disable_provider" => execute_disable_provider(&call.args, ctx).await,
            "send_file" => execute_send_file(&call.args).await,
            "export_conversation" => execute_export_conversation(&call.args, ctx).await,
            // OS Control Plane tools (AY.1) — delegate to MCP server
            "windows_list" | "windows_focus" | "windows_close" | "apps_launch"
            | "clipboard_get" | "clipboard_set" | "volume_get" | "volume_set"
            | "brightness_get" | "brightness_set" | "workspaces_list" | "workspaces_switch"
            | "cosmic_terminal" | "cosmic_files" | "cosmic_editor" | "cosmic_dark_mode"
            | "calc_read_cells" | "writer_export_pdf" | "a11y_tree" | "a11y_find"
            | "a11y_activate" | "a11y_get_text" | "a11y_set_text" | "a11y_apps" => {
                execute_os_control(&call.name, &call.args).await
            }
            // --- Fase BA: Unified Memory tools ---
            "health_status" => execute_health_status().await,
            "calendar_today" => execute_calendar_today(ctx).await,
            "calendar_add" => execute_calendar_add(&call.args, ctx).await,
            "current_context" => execute_current_context().await,
            "current_mode" => execute_current_mode().await,
            "learned_patterns" => execute_learned_patterns().await,
            "gaming_status" => execute_gaming_status().await,
            "meeting_recall" => execute_memory_search(&call.args, ctx, "meeting").await,
            "security_status" => execute_security_status().await,
            "activity_summary" => execute_memory_search_tag(ctx, "context").await,
            "screenshot_recall" => execute_memory_search(&call.args, ctx, "visual").await,
            "memory_cleanup" => execute_memory_cleanup(ctx).await,
            "memory_protect" => execute_memory_protect(&call.args, ctx).await,
            "service_manage" => execute_service_manage(&call.args).await,
            "meeting_list" => execute_meeting_list(&call.args, ctx).await,
            "meeting_search" => execute_meeting_search(&call.args, ctx).await,
            "meeting_start" => execute_meeting_start(&call.args, ctx).await,
            "meeting_stop" => execute_meeting_stop(ctx).await,
            "agenda" => execute_agenda(&call.args, ctx).await,
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
        // AQ.3 — Detect implicit preference feedback and update user model
        if let Some(ref um_arc) = ctx.user_model {
            if let Some((key, value)) = crate::user_model::detect_preference_feedback(user_text) {
                let mut um = um_arc.write().await;
                um.apply_preference(&key, &value);
                info!(
                    "[user_model] Implicit feedback: {} = {} (from: {:?})",
                    key,
                    value,
                    &user_text.chars().take(40).collect::<String>()
                );
                // Persist in background
                let um_snap = um.clone();
                tokio::spawn(async move {
                    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
                    let data_dir =
                        std::path::PathBuf::from(format!("{}/.local/share/lifeos", home));
                    if let Err(e) = um_snap.save(&data_dir).await {
                        warn!("[user_model] Failed to persist after feedback: {}", e);
                    }
                });
            }
        }

        // AQ.7 — Detect frustration from recent messages and achievements
        let emotional_hint = {
            let history_msgs = ctx.history.get(chat_id).await;
            let recent_user: Vec<&str> = history_msgs
                .iter()
                .filter(|m| m.role == "user")
                .rev()
                .take(5)
                .filter_map(|m| m.content.as_str())
                .collect();
            let frustration = crate::user_model::detect_frustration(&recent_user);
            let hint = crate::user_model::emotional_prompt_hint(&frustration);
            let achievement = crate::user_model::detect_achievement(user_text);
            let mut combined = String::new();
            if !hint.is_empty() {
                combined.push_str(hint);
                combined.push('\n');
            }
            if let Some(celebration) = achievement {
                combined.push_str(&celebration);
                combined.push('\n');
            }
            combined
        };

        // Build messages starting with system prompt (fresh time context each call).
        // IMPORTANT: All system-level context MUST go into a single system message
        // at the beginning. LLM chat templates (Jinja2) reject system messages
        // after user/assistant messages.
        let user_model_snapshot = if let Some(ref um) = ctx.user_model {
            Some(um.read().await.clone())
        } else {
            None
        };
        let mut system_prompt = build_system_prompt(user_model_snapshot.as_ref());
        if !emotional_hint.is_empty() {
            system_prompt.push_str(&format!("\n[Estado emocional]\n{}", emotional_hint));
        }
        if let Some(summary) = ctx.history.get_compacted_summary(chat_id).await {
            system_prompt.push_str(&format!(
                "\n\n[Resumen de conversacion anterior]: {}",
                summary
            ));
        }

        // Inject conversation history for multi-turn context
        let history = ctx.history.get(chat_id).await;
        let is_new_session = history.is_empty();

        // Collect session store turns (for restoring context after restart)
        let session_key = SessionKey::telegram_dm(chat_id);
        let mut restored_turns: Vec<ChatMessage> = Vec::new();
        if let Some(ref store) = ctx.session_store {
            if let Ok(_meta) = store.get_or_create(&session_key).await {
                if is_new_session {
                    if let Ok(recent) = store.load_recent_turns(&session_key, 50).await {
                        if !recent.is_empty() {
                            // Append compaction summary to system prompt (not as separate message)
                            if let Some(summary) = store.get_compaction_summary(&session_key).await
                            {
                                system_prompt.push_str(&format!(
                                    "\n\n[Resumen de sesiones anteriores (persistente)]: {}",
                                    summary
                                ));
                            }
                            for turn in &recent {
                                restored_turns.push(ChatMessage {
                                    role: turn.role.clone(),
                                    content: serde_json::Value::String(turn.content.clone()),
                                });
                            }
                            info!(
                                "[session_store] Restored {} turns for chat {} from persistent store",
                                recent.len(),
                                chat_id
                            );
                        }
                    }
                }
            }
        }

        // Proactive context recall: append to system prompt (not as separate message)
        if is_new_session || needs_memory_recall(user_text) {
            if let Some(memory) = &ctx.memory {
                let mem = memory.read().await;
                let recall_queries = [user_text, "session_summary"];
                let mut context_block = String::new();
                for query in &recall_queries {
                    if let Ok(results) = mem.search_entries(query, 3, None).await {
                        for r in &results {
                            let snippet = if r.entry.content.len() > 300 {
                                format!("{}...", &r.entry.content[..300])
                            } else {
                                r.entry.content.clone()
                            };
                            context_block.push_str(&format!(
                                "- [{}] ({}): {}\n",
                                r.entry.kind,
                                r.entry.created_at.format("%Y-%m-%d %H:%M"),
                                snippet
                            ));
                        }
                    }
                }
                if !context_block.is_empty() {
                    system_prompt.push_str(&format!(
                        "\n\n[Contexto recuperado de tu memoria persistente]:\n{}",
                        context_block
                    ));
                }
            }
        }

        // Now build the final messages array: single system message first, then history
        let mut messages = vec![ChatMessage {
            role: "system".into(),
            content: serde_json::Value::String(system_prompt),
        }];

        if !history.is_empty() {
            messages.extend(history);
        } else if !restored_turns.is_empty() {
            messages.extend(restored_turns);
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
                // Always show provider tag so user can debug which model responded
                let tagged = format!("{}\n\n[{}]", final_text.trim(), provider);

                // Save to conversation history
                let assistant_msg = ChatMessage {
                    role: "assistant".into(),
                    content: serde_json::Value::String(final_text.clone()),
                };
                ctx.history
                    .append(chat_id, &[user_msg, assistant_msg])
                    .await;

                // Persist to SessionStore (parallel durable system)
                if let Some(ref store) = ctx.session_store {
                    let store = store.clone();
                    let sk = session_key.clone();
                    let user_content = user_text.to_string();
                    let assistant_content = final_text.clone();
                    let router = ctx.router.clone();
                    tokio::spawn(async move {
                        let now = chrono::Utc::now();
                        // Save user turn
                        if let Err(e) = store
                            .append_turn(
                                &sk,
                                TranscriptTurn {
                                    role: "user".into(),
                                    content: user_content,
                                    channel: "telegram".into(),
                                    timestamp: now,
                                    tool_name: None,
                                    tool_result: None,
                                },
                            )
                            .await
                        {
                            warn!("[session_store] Failed to append user turn: {}", e);
                        }
                        // Save assistant turn
                        if let Err(e) = store
                            .append_turn(
                                &sk,
                                TranscriptTurn {
                                    role: "assistant".into(),
                                    content: assistant_content,
                                    channel: "telegram".into(),
                                    timestamp: now,
                                    tool_name: None,
                                    tool_result: None,
                                },
                            )
                            .await
                        {
                            warn!("[session_store] Failed to append assistant turn: {}", e);
                        }
                        // Trigger compaction if needed
                        if let Err(e) = store.compact_session(&sk, &router).await {
                            warn!("[session_store] Compaction failed: {}", e);
                        }
                    });
                }

                // Trigger LLM compaction in background if summary is long
                let compact_ctx = ctx.clone();
                tokio::spawn(async move {
                    compact_ctx
                        .history
                        .compact_with_llm(chat_id, &compact_ctx.router)
                        .await;
                });

                // Extract entities mentioned by the user (and Axi's reply) into
                // the knowledge graph as `(entity, "is_a", type)` triples plus a
                // `(user, "mentioned", entity)` link. We do NOT create a per-message
                // Conversation entity anymore — that pattern bloated the old
                // JSON-backed graph without adding queryable signal. The message
                // itself is already persisted as a memory entry by other paths.
                if let Some(memory) = &ctx.memory {
                    let mem = memory.clone();
                    let user_text_owned = user_text.to_string();
                    let axi_response_owned = tagged.clone();
                    tokio::spawn(async move {
                        let m = mem.read().await;
                        for (name, etype) in extract_entities_from_text(&user_text_owned) {
                            if let Err(e) = m.add_entity_typed(&name, etype).await {
                                warn!("[memory_plane] Failed to add entity: {}", e);
                            }
                            if let Err(e) =
                                m.add_triple("user", "mentioned", &name, 1.0, None).await
                            {
                                warn!("[memory_plane] Failed to add user→mentioned triple: {}", e);
                            }
                        }
                        for (name, etype) in extract_entities_from_text(&axi_response_owned) {
                            if let Err(e) = m.add_entity_typed(&name, etype).await {
                                warn!("[memory_plane] Failed to add entity: {}", e);
                            }
                            if let Err(e) = m.add_triple("axi", "mentioned", &name, 1.0, None).await
                            {
                                warn!("[memory_plane] Failed to add axi→mentioned triple: {}", e);
                            }
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
        let roots = telegram_allowed_roots();
        let workdir = telegram_tool_workdir(&roots);
        let parsed = parse_safe_command(command, &roots, &workdir)?;

        let output = tokio::time::timeout(
            std::time::Duration::from_secs(TELEGRAM_RUN_COMMAND_TIMEOUT_SECS),
            tokio::process::Command::new(&parsed.program)
                .args(&parsed.args)
                .current_dir(&workdir)
                .output(),
        )
        .await
        .map_err(|_| {
            anyhow::anyhow!(
                "El comando excedio el limite de {}s",
                TELEGRAM_RUN_COMMAND_TIMEOUT_SECS
            )
        })??;

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
        let roots = telegram_allowed_roots();
        let resolved = resolve_tool_path(path, &roots)?;
        let metadata = tokio::fs::metadata(&resolved).await?;
        if metadata.len() > TELEGRAM_TOOL_MAX_FILE_BYTES {
            anyhow::bail!(
                "Archivo demasiado grande para Telegram ({} bytes max)",
                TELEGRAM_TOOL_MAX_FILE_BYTES
            );
        }
        let content = tokio::fs::read(&resolved).await?;
        Ok(String::from_utf8_lossy(&content)
            .chars()
            .take(TELEGRAM_TOOL_MAX_READ_CHARS)
            .collect())
    }

    async fn execute_write_file(args: &serde_json::Value) -> Result<String> {
        let path = args["path"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'path'"))?;
        let content = args["content"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'content'"))?;
        if content.len() as u64 > TELEGRAM_TOOL_MAX_FILE_BYTES {
            anyhow::bail!(
                "Contenido demasiado grande para write_file ({} bytes max)",
                TELEGRAM_TOOL_MAX_FILE_BYTES
            );
        }
        let roots = telegram_allowed_roots();
        let resolved = resolve_tool_path(path, &roots)?;

        if let Some(parent) = resolved.parent() {
            tokio::fs::create_dir_all(parent).await.ok();
        }
        tokio::fs::write(&resolved, content).await?;
        Ok(format!("Archivo guardado: {}", resolved.display()))
    }

    async fn execute_list_files(args: &serde_json::Value) -> Result<String> {
        let path = args["path"].as_str().unwrap_or(".");
        let pattern = args["pattern"].as_str().unwrap_or("*");
        let roots = telegram_allowed_roots();
        let resolved = resolve_tool_path(path, &roots)?;
        let mut entries = tokio::fs::read_dir(&resolved).await?;
        let mut total = 0usize;
        let mut matched = 0usize;
        let mut lines = Vec::new();

        while let Some(entry) = entries.next_entry().await? {
            total += 1;
            let name = entry.file_name().to_string_lossy().to_string();
            if !simple_glob_match(pattern, &name) {
                continue;
            }
            matched += 1;

            let metadata = entry.metadata().await?;
            let kind = if metadata.is_dir() {
                "dir"
            } else if metadata.is_file() {
                "file"
            } else {
                "other"
            };
            let suffix = if metadata.is_dir() { "/" } else { "" };
            lines.push(format!("- [{}] {}{}", kind, name, suffix));
            if lines.len() >= 200 {
                break;
            }
        }

        if matched == 0 {
            return Ok(format!(
                "Ruta: {}\nSin coincidencias para '{}'. Total de entradas: {}",
                resolved.display(),
                pattern,
                total
            ));
        }

        Ok(format!(
            "Ruta: {}\nCoincidencias: {} de {} entradas\n\n{}",
            resolved.display(),
            matched,
            total,
            lines.join("\n")
        ))
    }

    async fn execute_system_status() -> Result<String> {
        let alerts = proactive::check_all(None, None).await;

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
                    // Also register the memory as an entity in the knowledge graph.
                    // Backed by `memory_plane` triples now (see migration in
                    // commit history); the standalone JSON-backed graph that
                    // used to live in `knowledge_graph.rs` was removed because
                    // it did a full file rewrite on every insert.
                    if let Some(memory) = &ctx.memory {
                        let mem = memory.clone();
                        let entity_name = if !title.is_empty() {
                            title.to_string()
                        } else {
                            structured_content.chars().take(60).collect::<String>()
                        };
                        let entity_type = match mem_type {
                            "decision" | "architecture" => "decision",
                            "bugfix" | "discovery" | "pattern" => "topic",
                            "preference" | "config" => "topic",
                            _ => "topic",
                        };
                        tokio::spawn(async move {
                            let m = mem.read().await;
                            if let Err(e) = m.add_entity_typed(&entity_name, entity_type).await {
                                warn!("[memory_plane] Failed to add entity: {}", e);
                            }
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
                            .map(|r| {
                                let snippet = if r.entry.content.len() > 500 {
                                    format!("{}...", &r.entry.content[..500])
                                } else {
                                    r.entry.content.clone()
                                };
                                format!(
                                    "- [{}] ({}): {}",
                                    r.entry.kind,
                                    r.entry.created_at.format("%Y-%m-%d %H:%M"),
                                    snippet
                                )
                            })
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

    /// BI.1 — recall_archived: search the archive tier.
    ///
    /// Same hybrid lexical+semantic search as `recall`, but inverted to
    /// only return entries flagged `archived = 1`. The archive tier is
    /// where memories that fell below the daily decay GC threshold go
    /// — they are out of the live search ranking but still recoverable
    /// when the user says *"tenía una idea pero ya no recuerdo qué era"*
    /// or *"qué pasó con aquel proyecto que pausé hace meses?"*.
    ///
    /// Embeddings are preserved on archive so semantic recall over the
    /// archive works exactly the same as the live tier.
    async fn execute_recall_archived(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let query = args["query"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'query'"))?;

        let memory = match &ctx.memory {
            Some(m) => m,
            None => return Ok("La memoria persistente no esta disponible.".into()),
        };
        let mem = memory.read().await;
        match mem.search_archived(query, 5, None).await {
            Ok(results) => {
                if results.is_empty() {
                    Ok("No encontre nada en el archivo de memoria. Recuerda que el archivo solo contiene memorias que el sistema marco como menos relevantes y movio fuera de la busqueda activa — si lo que buscas es reciente, usa `recall`.".into())
                } else {
                    let formatted: Vec<String> = results
                        .iter()
                        .map(|r| {
                            let snippet = if r.entry.content.len() > 500 {
                                format!("{}...", &r.entry.content[..500])
                            } else {
                                r.entry.content.clone()
                            };
                            format!(
                                "- [archivado] [{}] ({}): {}",
                                r.entry.kind,
                                r.entry.created_at.format("%Y-%m-%d %H:%M"),
                                snippet
                            )
                        })
                        .collect();
                    Ok(format!(
                        "Recuerdos del archivo (cosas que dejaste de mencionar hace tiempo):\n{}",
                        formatted.join("\n")
                    ))
                }
            }
            Err(e) => Ok(format!("Error buscando en el archivo: {}", e)),
        }
    }

    // ========================================================================
    // Fase BI.2 — Salud médica estructurada (Vida Plena)
    // ========================================================================

    /// Helper: pull `&MemoryPlaneManager` out of `ctx.memory` or fail
    /// gracefully with a Spanish error string. Saves the same 5 lines
    /// of boilerplate from each BI.2 tool below.
    async fn require_memory(
        ctx: &ToolContext,
    ) -> Result<tokio::sync::RwLockReadGuard<'_, MemoryPlaneManager>> {
        match &ctx.memory {
            Some(m) => Ok(m.read().await),
            None => Err(anyhow::anyhow!(
                "La memoria persistente no esta disponible (memory_plane no inicializado)"
            )),
        }
    }

    async fn execute_health_fact_add(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let fact_type = args["fact_type"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'fact_type'"))?;
        let label = args["label"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'label'"))?;
        let severity = args["severity"].as_str();
        let notes = args["notes"].as_str().unwrap_or("");
        let mem = require_memory(ctx).await?;
        let fact = mem
            .add_health_fact(fact_type, label, severity, notes, None)
            .await?;
        Ok(format!(
            "Hecho de salud guardado (id: {}, tipo: {}, etiqueta: \"{}\")",
            fact.fact_id, fact.fact_type, fact.label
        ))
    }

    async fn execute_health_fact_list(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let fact_type = args["fact_type"].as_str();
        let mem = require_memory(ctx).await?;
        let facts = mem.list_health_facts(fact_type).await?;
        if facts.is_empty() {
            return Ok("No hay hechos de salud registrados.".into());
        }
        let lines: Vec<String> = facts
            .iter()
            .map(|f| {
                let sev = f
                    .severity
                    .as_deref()
                    .map(|s| format!(" [{}]", s))
                    .unwrap_or_default();
                let notes = if f.notes.is_empty() {
                    String::new()
                } else {
                    format!(" — {}", f.notes)
                };
                format!("- [{}] {}{}{}", f.fact_type, f.label, sev, notes)
            })
            .collect();
        Ok(format!("Hechos de salud:\n{}", lines.join("\n")))
    }

    async fn execute_medication_start(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let name = args["name"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'name'"))?;
        let dosage = args["dosage"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'dosage'"))?;
        let frequency = args["frequency"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'frequency'"))?;
        let condition = args["condition"].as_str();
        let prescribed_by = args["prescribed_by"].as_str();
        let notes = args["notes"].as_str().unwrap_or("");
        let mem = require_memory(ctx).await?;
        let med = mem
            .start_medication(
                name,
                dosage,
                frequency,
                condition,
                prescribed_by,
                notes,
                None,
            )
            .await?;
        Ok(format!(
            "Medicamento iniciado (id: {}): {} {} {}",
            med.med_id, med.name, med.dosage, med.frequency
        ))
    }

    async fn execute_medication_stop(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let med_id = args["med_id"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'med_id'"))?;
        let mem = require_memory(ctx).await?;
        let stopped = mem.stop_medication(med_id).await?;
        if stopped {
            Ok(format!("Medicamento {} marcado como suspendido.", med_id))
        } else {
            Ok(format!(
                "No se encontro un medicamento activo con id {}.",
                med_id
            ))
        }
    }

    async fn execute_medication_active(ctx: &ToolContext) -> Result<String> {
        let mem = require_memory(ctx).await?;
        let meds = mem.list_active_medications().await?;
        if meds.is_empty() {
            return Ok("No hay medicamentos activos.".into());
        }
        let lines: Vec<String> = meds
            .iter()
            .map(|m| {
                let cond = m
                    .condition
                    .as_deref()
                    .map(|c| format!(" para {}", c))
                    .unwrap_or_default();
                format!(
                    "- [{}] {} {} {}{} (desde {})",
                    m.med_id,
                    m.name,
                    m.dosage,
                    m.frequency,
                    cond,
                    m.started_at.format("%Y-%m-%d")
                )
            })
            .collect();
        Ok(format!("Medicamentos activos:\n{}", lines.join("\n")))
    }

    async fn execute_vital_record(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let vital_type = args["vital_type"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'vital_type'"))?;
        let unit = args["unit"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'unit'"))?;
        let value_numeric = args["value_numeric"].as_f64();
        let value_text = args["value_text"].as_str();
        let context = args["context"].as_str();
        let mem = require_memory(ctx).await?;
        let vital = mem
            .record_vital(
                vital_type,
                value_numeric,
                value_text,
                unit,
                None,
                context,
                None,
            )
            .await?;
        let value_display = vital
            .value_numeric
            .map(|v| format!("{}", v))
            .unwrap_or_else(|| vital.value_text.clone().unwrap_or_default());
        Ok(format!(
            "Vital registrado: {} = {} {}",
            vital.vital_type, value_display, vital.unit
        ))
    }

    async fn execute_vital_history(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let vital_type = args["vital_type"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'vital_type'"))?;
        let limit = args["limit"].as_u64().unwrap_or(20) as usize;
        let mem = require_memory(ctx).await?;
        let series = mem.get_vitals_timeseries(vital_type, limit).await?;
        if series.is_empty() {
            return Ok(format!("No hay registros de '{}'.", vital_type));
        }
        let lines: Vec<String> = series
            .iter()
            .map(|v| {
                let value = v
                    .value_numeric
                    .map(|n| format!("{}", n))
                    .unwrap_or_else(|| v.value_text.clone().unwrap_or_default());
                let ctx_str = v
                    .context
                    .as_deref()
                    .map(|c| format!(" ({})", c))
                    .unwrap_or_default();
                format!(
                    "- {}: {} {}{}",
                    v.measured_at.format("%Y-%m-%d %H:%M"),
                    value,
                    v.unit,
                    ctx_str
                )
            })
            .collect();
        Ok(format!(
            "Historial de {} ({} lecturas):\n{}",
            vital_type,
            series.len(),
            lines.join("\n")
        ))
    }

    async fn execute_lab_add(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let test_name = args["test_name"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'test_name'"))?;
        let value_numeric = args["value_numeric"]
            .as_f64()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'value_numeric'"))?;
        let unit = args["unit"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'unit'"))?;
        let reference_low = args["reference_low"].as_f64();
        let reference_high = args["reference_high"].as_f64();
        let lab_name = args["lab_name"].as_str();
        let notes = args["notes"].as_str().unwrap_or("");
        let mem = require_memory(ctx).await?;
        let lab = mem
            .add_lab_result(
                test_name,
                value_numeric,
                unit,
                reference_low,
                reference_high,
                None,
                lab_name,
                notes,
                None,
                None,
            )
            .await?;
        let range = match (lab.reference_low, lab.reference_high) {
            (Some(lo), Some(hi)) => format!(" (referencia {}-{})", lo, hi),
            _ => String::new(),
        };
        Ok(format!(
            "Resultado registrado: {} = {} {}{}",
            lab.test_name, lab.value_numeric, lab.unit, range
        ))
    }

    async fn execute_health_summary(ctx: &ToolContext) -> Result<String> {
        let mem = require_memory(ctx).await?;
        let summary = mem.get_health_summary(5, 20).await?;
        let mut out = String::from("# Resumen de salud\n\n");

        if summary.facts.is_empty() {
            out.push_str("## Hechos permanentes\n(ninguno registrado)\n\n");
        } else {
            out.push_str("## Hechos permanentes\n");
            for f in &summary.facts {
                let sev = f
                    .severity
                    .as_deref()
                    .map(|s| format!(" [{}]", s))
                    .unwrap_or_default();
                out.push_str(&format!("- [{}] {}{}\n", f.fact_type, f.label, sev));
            }
            out.push('\n');
        }

        if summary.active_medications.is_empty() {
            out.push_str("## Medicamentos activos\n(ninguno)\n\n");
        } else {
            out.push_str("## Medicamentos activos\n");
            for m in &summary.active_medications {
                let cond = m
                    .condition
                    .as_deref()
                    .map(|c| format!(" para {}", c))
                    .unwrap_or_default();
                out.push_str(&format!(
                    "- {} {} {}{} (desde {})\n",
                    m.name,
                    m.dosage,
                    m.frequency,
                    cond,
                    m.started_at.format("%Y-%m-%d")
                ));
            }
            out.push('\n');
        }

        if !summary.recent_vitals.is_empty() {
            out.push_str("## Vitales recientes\n");
            for v in summary.recent_vitals.iter().take(15) {
                let value = v
                    .value_numeric
                    .map(|n| format!("{}", n))
                    .unwrap_or_else(|| v.value_text.clone().unwrap_or_default());
                out.push_str(&format!(
                    "- [{}] {}: {} {}\n",
                    v.measured_at.format("%Y-%m-%d"),
                    v.vital_type,
                    value,
                    v.unit
                ));
            }
            out.push('\n');
        }

        if !summary.recent_labs.is_empty() {
            out.push_str("## Análisis recientes\n");
            for l in &summary.recent_labs {
                let range = match (l.reference_low, l.reference_high) {
                    (Some(lo), Some(hi)) => format!(" (ref {}-{})", lo, hi),
                    _ => String::new(),
                };
                out.push_str(&format!(
                    "- [{}] {}: {} {}{}\n",
                    l.measured_at.format("%Y-%m-%d"),
                    l.test_name,
                    l.value_numeric,
                    l.unit,
                    range
                ));
            }
            out.push('\n');
        }

        out.push_str(
            "\n_Generado por LifeOS — para consulta con tu medico, no es diagnostico._\n",
        );
        Ok(out)
    }

    // ========================================================================
    // Fase BI.7 — Crecimiento personal (Vida Plena)
    // ========================================================================

    async fn execute_book_add(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let title = args["title"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'title'"))?;
        let author = args["author"].as_str();
        let isbn = args["isbn"].as_str();
        let status_str = args["status"].as_str().unwrap_or("wishlist");
        let status = BookStatus::parse(status_str)?;
        let rating = args["rating_1_5"].as_u64().map(|n| n as u8);
        let notes = args["notes"].as_str().unwrap_or("");
        let mem = require_memory(ctx).await?;
        let book = mem
            .add_book(title, author, isbn, status, rating, notes, None)
            .await?;
        Ok(format!(
            "Libro guardado (id: {}): \"{}\"{} — status: {}",
            book.book_id,
            book.title,
            book.author
                .as_deref()
                .map(|a| format!(" por {}", a))
                .unwrap_or_default(),
            book.status.as_str()
        ))
    }

    async fn execute_book_status_set(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let book_id = args["book_id"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'book_id'"))?;
        let status_str = args["status"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'status'"))?;
        let status = BookStatus::parse(status_str)?;
        let rating = args["rating_1_5"].as_u64().map(|n| n as u8);
        let mem = require_memory(ctx).await?;
        let updated = mem.update_book_status(book_id, status, rating).await?;
        if updated {
            Ok(format!(
                "Libro {} actualizado a status '{}'.",
                book_id,
                status.as_str()
            ))
        } else {
            Ok(format!("No se encontro libro con id {}.", book_id))
        }
    }

    async fn execute_book_list(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let status = match args["status"].as_str() {
            Some(s) => Some(BookStatus::parse(s)?),
            None => None,
        };
        let mem = require_memory(ctx).await?;
        let books = mem.list_books(status).await?;
        if books.is_empty() {
            return Ok("No hay libros registrados.".into());
        }
        let lines: Vec<String> = books
            .iter()
            .map(|b| {
                let author = b
                    .author
                    .as_deref()
                    .map(|a| format!(" — {}", a))
                    .unwrap_or_default();
                let rating = b
                    .rating_1_5
                    .map(|r| format!(" ★{}/5", r))
                    .unwrap_or_default();
                format!(
                    "- [{}] [{}] \"{}\"{}{}",
                    b.book_id,
                    b.status.as_str(),
                    b.title,
                    author,
                    rating
                )
            })
            .collect();
        Ok(format!("Libros:\n{}", lines.join("\n")))
    }

    async fn execute_habit_add(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let name = args["name"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'name'"))?;
        let description = args["description"].as_str();
        let frequency = args["frequency"].as_str().unwrap_or("daily");
        let notes = args["notes"].as_str().unwrap_or("");
        let mem = require_memory(ctx).await?;
        let habit = mem
            .add_habit(name, description, frequency, notes, None)
            .await?;
        Ok(format!(
            "Habito creado (id: {}): \"{}\" — {}",
            habit.habit_id, habit.name, habit.frequency
        ))
    }

    async fn execute_habit_checkin(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let habit_id = args["habit_id"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'habit_id'"))?;
        let completed = args["completed"].as_bool().unwrap_or(true);
        let logged_for_date = args["logged_for_date"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'logged_for_date' (YYYY-MM-DD)"))?;
        let notes = args["notes"].as_str();
        let mem = require_memory(ctx).await?;
        let _checkin = mem
            .log_habit_checkin(habit_id, completed, logged_for_date, notes)
            .await?;
        let mark = if completed { "✓" } else { "✗" };
        Ok(format!(
            "Check-in registrado: {} {} en {}",
            mark, habit_id, logged_for_date
        ))
    }

    async fn execute_habit_active(ctx: &ToolContext) -> Result<String> {
        let mem = require_memory(ctx).await?;
        let habits = mem.list_habits(true).await?;
        if habits.is_empty() {
            return Ok("No hay habitos activos.".into());
        }
        let lines: Vec<String> = habits
            .iter()
            .map(|h| {
                let desc = h
                    .description
                    .as_deref()
                    .map(|d| format!(" — {}", d))
                    .unwrap_or_default();
                format!(
                    "- [{}] {} ({}) {}",
                    h.habit_id, h.name, h.frequency, desc
                )
            })
            .collect();
        Ok(format!("Habitos activos:\n{}", lines.join("\n")))
    }

    async fn execute_goal_add(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let name = args["name"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'name'"))?;
        let description = args["description"].as_str();
        let deadline = args["deadline"].as_str();
        let notes = args["notes"].as_str().unwrap_or("");
        let mem = require_memory(ctx).await?;
        let goal = mem
            .add_growth_goal(name, description, deadline, notes, None)
            .await?;
        Ok(format!(
            "Meta creada (id: {}): \"{}\" — progreso 0%",
            goal.goal_id, goal.name
        ))
    }

    async fn execute_goal_progress(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let goal_id = args["goal_id"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'goal_id'"))?;
        let progress_pct = args["progress_pct"]
            .as_u64()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'progress_pct' (0-100)"))?
            as u8;
        let new_status = match args["status"].as_str() {
            Some(s) => Some(GoalStatus::parse(s)?),
            None => None,
        };
        let mem = require_memory(ctx).await?;
        let updated = mem
            .update_growth_goal_progress(goal_id, progress_pct, new_status)
            .await?;
        if updated {
            Ok(format!(
                "Meta {} actualizada: progreso {}%{}",
                goal_id,
                progress_pct.min(100),
                if progress_pct >= 100 {
                    " — ¡lograda!"
                } else {
                    ""
                }
            ))
        } else {
            Ok(format!("No se encontro meta con id {}.", goal_id))
        }
    }

    async fn execute_growth_summary(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        // Caller passes today as YYYY-MM-DD; default to UTC today.
        let today = args["today"]
            .as_str()
            .map(|s| s.to_string())
            .unwrap_or_else(|| chrono::Utc::now().format("%Y-%m-%d").to_string());
        let mem = require_memory(ctx).await?;
        let summary = mem.get_growth_summary(5, &today, 30).await?;
        let mut out = String::from("# Resumen de crecimiento personal\n\n");

        if !summary.currently_reading.is_empty() {
            out.push_str("## Leyendo actualmente\n");
            for b in &summary.currently_reading {
                let author = b
                    .author
                    .as_deref()
                    .map(|a| format!(" — {}", a))
                    .unwrap_or_default();
                out.push_str(&format!("- \"{}\"{}\n", b.title, author));
            }
            out.push('\n');
        }

        if !summary.recently_finished.is_empty() {
            out.push_str("## Terminados recientemente\n");
            for b in &summary.recently_finished {
                let rating = b
                    .rating_1_5
                    .map(|r| format!(" ★{}/5", r))
                    .unwrap_or_default();
                let author = b
                    .author
                    .as_deref()
                    .map(|a| format!(" — {}", a))
                    .unwrap_or_default();
                out.push_str(&format!("- \"{}\"{}{}\n", b.title, author, rating));
            }
            out.push('\n');
        }

        if !summary.active_habits.is_empty() {
            out.push_str("## Hábitos activos (últimos 30 días)\n");
            for h in &summary.active_habits {
                let streak = summary
                    .habit_streak_30d
                    .iter()
                    .find(|s| s.habit_id == h.habit_id);
                let streak_str = match streak {
                    Some(s) => format!(
                        " — {}/{} días",
                        s.completed_days, s.total_days
                    ),
                    None => String::new(),
                };
                out.push_str(&format!("- {} ({}){}\n", h.name, h.frequency, streak_str));
            }
            out.push('\n');
        }

        if !summary.active_goals.is_empty() {
            out.push_str("## Metas activas\n");
            for g in &summary.active_goals {
                let deadline = g
                    .deadline
                    .as_deref()
                    .map(|d| format!(" (deadline: {})", d))
                    .unwrap_or_default();
                out.push_str(&format!(
                    "- {} — {}%{}\n",
                    g.name, g.progress_pct, deadline
                ));
            }
            out.push('\n');
        }

        if summary.currently_reading.is_empty()
            && summary.recently_finished.is_empty()
            && summary.active_habits.is_empty()
            && summary.active_goals.is_empty()
        {
            out.push_str(
                "Aun no hay datos de crecimiento personal registrados. \
                 Empieza con `book_add`, `habit_add` o `goal_add`.\n",
            );
        }

        Ok(out)
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
                    content: serde_json::Value::String(format!(
                        "{}\n\nEres un asistente que analiza capturas de paginas web. Describe el contenido de forma concisa en español.",
                        crate::time_context::time_context_short()
                    )),
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
            "{}\n\nEres un sub-agente especializado de LifeOS. Tu nivel de pensamiento es: {}.\n\
             Responde de forma concisa y directa en español.",
            crate::time_context::time_context(),
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
                // Include provider tag so user sees which model the sub-agent used
                Ok(format!("{}\n\n[{}]", r.text.trim(), r.provider))
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

    async fn execute_audit_query(args: &serde_json::Value) -> Result<String> {
        let period = args.get("period").and_then(|v| v.as_str()).unwrap_or("24h");

        // Parse period into hours
        let hours: u64 = match period {
            "1h" => 1,
            "6h" => 6,
            "12h" => 12,
            "24h" => 24,
            "7d" => 168,
            other => {
                // Try to parse as Nh or Nd
                if let Some(h) = other.strip_suffix('h') {
                    h.parse().unwrap_or(24)
                } else if let Some(d) = other.strip_suffix('d') {
                    d.parse::<u64>().unwrap_or(1) * 24
                } else {
                    24
                }
            }
        };

        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
        let db_path =
            std::path::PathBuf::from(format!("{}/.local/share/lifeos/reliability.db", home));

        let mut sections = Vec::new();

        // Query reliability database
        if db_path.exists() {
            match crate::reliability::ReliabilityTracker::new(db_path) {
                Ok(tracker) => {
                    // Success rate for the period
                    match tracker.success_rate_period(hours) {
                        Ok(rate) => {
                            sections.push(format!(
                                "Tasa de exito (ultimas {}): {:.0}%",
                                period,
                                rate * 100.0
                            ));
                        }
                        Err(e) => {
                            sections.push(format!("Error consultando tasa: {}", e));
                        }
                    }

                    // Full report
                    match tracker.get_reliability_report() {
                        Ok(report) => {
                            sections.push(format!(
                                "Total tareas: {} (exitosas: {}, fallidas: {})",
                                report.total_tasks, report.successful, report.failed
                            ));
                            sections.push(format!("Tendencia: {}", report.trend));
                            if report.mtbf_hours > 0.0 {
                                sections.push(format!(
                                    "Tiempo medio entre fallos: {:.1}h",
                                    report.mtbf_hours
                                ));
                            }
                            if !report.top_failures.is_empty() {
                                let failures: Vec<String> = report
                                    .top_failures
                                    .iter()
                                    .take(3)
                                    .map(|f| {
                                        format!(
                                            "  - {} (x{}, ultimo: {})",
                                            f.error_signature, f.count, f.last_seen
                                        )
                                    })
                                    .collect();
                                sections
                                    .push(format!("Fallos frecuentes:\n{}", failures.join("\n")));
                            }
                            sections.push(format!(
                                "Objetivo 95%: {}",
                                if report.meets_target {
                                    "CUMPLIDO"
                                } else {
                                    "NO CUMPLIDO"
                                }
                            ));
                        }
                        Err(e) => {
                            sections.push(format!("Error en reporte: {}", e));
                        }
                    }
                }
                Err(e) => {
                    sections.push(format!("No se pudo abrir reliability.db: {}", e));
                }
            }
        } else {
            sections.push("Sin datos de reliability (aun no hay tareas registradas).".into());
        }

        // Also read supervisor audit log for recent activity
        let log_paths = [
            std::path::PathBuf::from("/var/log/lifeos/supervisor-audit.log"),
            std::path::PathBuf::from("/var/lib/lifeos/supervisor-audit.log"),
        ];
        if let Some(content) = log_paths
            .iter()
            .find_map(|p| std::fs::read_to_string(p).ok())
        {
            let lines: Vec<&str> = content.lines().collect();
            let recent_count = lines.len().min(10);
            if recent_count > 0 {
                sections.push(format!("Ultimas {} entradas del audit log:", recent_count));
                for line in lines.iter().rev().take(recent_count) {
                    sections.push(format!("  {}", line));
                }
            }
        }

        if sections.is_empty() {
            Ok("No hay datos de auditoria disponibles todavia.".into())
        } else {
            Ok(format!(
                "=== Auditoria Axi ({}) ===\n{}",
                period,
                sections.join("\n")
            ))
        }
    }

    /// Search memories by date range. Converts local time to UTC using user timezone.
    async fn execute_search_memories_by_date(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let date = args.get("date").and_then(|v| v.as_str()).unwrap_or("");
        let time_from = args
            .get("time_from")
            .and_then(|v| v.as_str())
            .unwrap_or("00:00");
        let time_to = args
            .get("time_to")
            .and_then(|v| v.as_str())
            .unwrap_or("23:59");

        if date.is_empty() {
            return Ok("Falta el parametro 'date' (formato: YYYY-MM-DD).".into());
        }

        // Get user timezone and convert to UTC range
        let user_tz = crate::time_context::get_user_timezone();
        let (from_utc, to_utc) =
            match crate::time_context::date_time_range_to_utc(date, time_from, time_to, &user_tz) {
                Ok(range) => range,
                Err(e) => return Ok(format!("Error parseando fecha/hora: {}", e)),
            };

        // Query memory plane
        if let Some(memory) = &ctx.memory {
            let mem = memory.read().await;
            match mem.search_by_time_range(&from_utc, &to_utc, 20).await {
                Ok(entries) => {
                    if entries.is_empty() {
                        Ok(format!(
                            "No encontre memorias entre {} {}–{} ({}).",
                            date, time_from, time_to, user_tz
                        ))
                    } else {
                        let formatted: Vec<String> = entries
                            .iter()
                            .map(|e| {
                                let local_time =
                                    crate::time_context::utc_to_local(&e.created_at, &user_tz)
                                        .unwrap_or_else(|_| {
                                            e.created_at.format("%Y-%m-%d %H:%M").to_string()
                                        });
                                format!(
                                    "- [{}] {} — {}",
                                    e.kind,
                                    local_time,
                                    if e.content.len() > 100 {
                                        format!("{}...", &e.content[..100])
                                    } else {
                                        e.content.clone()
                                    }
                                )
                            })
                            .collect();
                        Ok(format!(
                            "Memorias del {} ({}–{}, {}):\n{}",
                            date,
                            time_from,
                            time_to,
                            user_tz,
                            formatted.join("\n")
                        ))
                    }
                }
                Err(e) => Ok(format!("Error buscando en memoria: {}", e)),
            }
        } else {
            Ok("La memoria persistente no esta disponible.".into())
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
                        content: serde_json::Value::String(format!(
                            "{}\n\nEres un sub-agente SDD de LifeOS. Ejecuta SOLO la fase indicada. Conciso y directo. En espanol.",
                            crate::time_context::time_context_short()
                        )),
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
    // AN.1 — LLM Provider management tools
    // -----------------------------------------------------------------------

    async fn execute_add_provider(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let provider_base = args
            .get("provider_base")
            .and_then(|v| v.as_str())
            .unwrap_or("custom");
        let model = args.get("model").and_then(|v| v.as_str()).unwrap_or("");
        if model.is_empty() {
            return Ok("Error: se requiere el campo 'model'.".into());
        }

        // Infer api_base from known providers
        let api_base = args
            .get("api_base")
            .and_then(|v| v.as_str())
            .map(String::from)
            .unwrap_or_else(|| match provider_base {
                "openrouter" => "https://openrouter.ai/api".into(),
                "cerebras" => "https://api.cerebras.ai".into(),
                "groq" => "https://api.groq.com/openai".into(),
                _ => String::new(),
            });
        if api_base.is_empty() {
            return Ok("Error: se requiere 'api_base' para proveedores custom.".into());
        }

        // Infer api_key_env from known providers
        let api_key_env = args
            .get("api_key_env")
            .and_then(|v| v.as_str())
            .map(String::from)
            .unwrap_or_else(|| match provider_base {
                "openrouter" => "OPENROUTER_API_KEY".into(),
                "cerebras" => "CEREBRAS_API_KEY".into(),
                "groq" => "GROQ_API_KEY".into(),
                _ => String::new(),
            });

        // SSRF guard
        if let Err(e) = crate::llm_router::validate_endpoint_safe(&api_base) {
            return Ok(format!("Error SSRF: endpoint bloqueado — {}", e));
        }

        // Build a safe provider name from base + model
        let provider_name = format!("{}-{}", provider_base, model.replace(['/', ' '], "-"));

        // Build TOML entry
        let toml_entry = format!(
            r#"

[[providers]]
name = "{name}"
api_base = "{api_base}"
api_key_env = "{api_key_env}"
model = "{model}"
api_format = "open_ai_compatible"
tier = "free"
privacy = "standard"
max_context = 128000
"#,
            name = provider_name,
            api_base = api_base,
            api_key_env = api_key_env,
            model = model,
        );

        // Determine TOML path (prefer user config, writable)
        let toml_path = dirs_home()
            .map(|h| h.join(".config/lifeos/llm-providers.toml"))
            .unwrap_or_else(|| std::path::PathBuf::from("/etc/lifeos/llm-providers.toml"));

        // Ensure parent directory exists
        if let Some(parent) = toml_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }

        // If file doesn't exist yet, create it with a header
        if !toml_path.exists() {
            if let Err(e) = std::fs::write(&toml_path, "# LifeOS LLM Providers — auto-generated\n")
            {
                return Ok(format!("Error creando archivo de providers: {}", e));
            }
        }

        // Append entry
        use std::io::Write;
        let mut file = match std::fs::OpenOptions::new().append(true).open(&toml_path) {
            Ok(f) => f,
            Err(e) => return Ok(format!("Error abriendo {}: {}", toml_path.display(), e)),
        };
        if let Err(e) = file.write_all(toml_entry.as_bytes()) {
            return Ok(format!("Error escribiendo provider: {}", e));
        }

        // Trigger reload
        let mut router = ctx.router.write().await;
        let count = router.reload_providers().unwrap_or(0);

        Ok(format!(
            "Proveedor agregado: {} (modelo: {})\nArchivo: {}\nProveedores activos tras recarga: {}",
            provider_name,
            model,
            toml_path.display(),
            count,
        ))
    }

    fn dirs_home() -> Option<std::path::PathBuf> {
        std::env::var("HOME").ok().map(std::path::PathBuf::from)
    }

    async fn execute_list_providers(ctx: &ToolContext) -> Result<String> {
        let router = ctx.router.read().await;
        let configs = router.provider_configs();
        if configs.is_empty() {
            return Ok("No hay proveedores configurados.".into());
        }

        let summary = router.cost_summary();
        let summary_map: std::collections::HashMap<String, (u64, u64, u64)> = summary
            .into_iter()
            .map(|(name, reqs, toks, fails)| (name, (reqs, toks, fails)))
            .collect();

        let mut lines = Vec::with_capacity(configs.len() + 1);
        lines.push(format!("Proveedores LLM activos: {}", configs.len()));
        for cfg in configs {
            let stats = summary_map.get(&cfg.name);
            let (reqs, _toks, fails) = stats.copied().unwrap_or((0, 0, 0));
            lines.push(format!(
                "• {} — modelo: {}, tier: {:?}, reqs: {}, fails: {}",
                cfg.name, cfg.model, cfg.tier, reqs, fails,
            ));
        }
        Ok(lines.join("\n"))
    }

    // -----------------------------------------------------------------------
    // Provider management tools (remove / disable)
    // -----------------------------------------------------------------------

    /// Read the providers TOML file and split into (header_lines, provider_blocks).
    /// Each provider block starts with `[[providers]]` and includes all subsequent
    /// lines until the next `[[providers]]` or end-of-file.
    fn parse_provider_blocks(content: &str) -> (String, Vec<String>) {
        let mut header = String::new();
        let mut blocks: Vec<String> = Vec::new();
        let mut current_block = String::new();
        let mut in_providers = false;

        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed == "[[providers]]" {
                if in_providers && !current_block.is_empty() {
                    blocks.push(current_block.clone());
                    current_block.clear();
                }
                in_providers = true;
                current_block.push_str(line);
                current_block.push('\n');
            } else if in_providers {
                current_block.push_str(line);
                current_block.push('\n');
            } else {
                header.push_str(line);
                header.push('\n');
            }
        }
        if in_providers && !current_block.is_empty() {
            blocks.push(current_block);
        }
        (header, blocks)
    }

    /// Extract the `name = "..."` value from a provider block.
    fn block_provider_name(block: &str) -> Option<String> {
        for line in block.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with("name") {
                if let Some(val) = trimmed.split('=').nth(1) {
                    return Some(val.trim().trim_matches('"').trim_matches('\'').to_string());
                }
            }
        }
        None
    }

    fn providers_toml_path() -> std::path::PathBuf {
        dirs_home()
            .map(|h| h.join(".config/lifeos/llm-providers.toml"))
            .unwrap_or_else(|| std::path::PathBuf::from("/etc/lifeos/llm-providers.toml"))
    }

    async fn execute_remove_provider(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let name = args.get("name").and_then(|v| v.as_str()).unwrap_or("");
        if name.is_empty() {
            return Ok("Error: se requiere el campo 'name'.".into());
        }

        let toml_path = providers_toml_path();
        if !toml_path.exists() {
            return Ok(format!(
                "Archivo de providers no encontrado: {}",
                toml_path.display()
            ));
        }

        let content = std::fs::read_to_string(&toml_path)?;
        let (header, blocks) = parse_provider_blocks(&content);

        let original_count = blocks.len();
        let remaining: Vec<String> = blocks
            .into_iter()
            .filter(|b| block_provider_name(b).map(|n| n != name).unwrap_or(true))
            .collect();

        if remaining.len() == original_count {
            return Ok(format!(
                "Proveedor '{}' no encontrado en {}",
                name,
                toml_path.display()
            ));
        }

        // Rewrite file
        let mut output = header;
        for block in &remaining {
            output.push_str(block);
        }
        std::fs::write(&toml_path, &output)?;

        // Trigger reload
        let mut router = ctx.router.write().await;
        let count = router.reload_providers().unwrap_or(0);

        Ok(format!(
            "Proveedor '{}' eliminado.\nArchivo: {}\nProveedores activos tras recarga: {}",
            name,
            toml_path.display(),
            count,
        ))
    }

    async fn execute_disable_provider(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let name = args.get("name").and_then(|v| v.as_str()).unwrap_or("");
        if name.is_empty() {
            return Ok("Error: se requiere el campo 'name'.".into());
        }

        let enable = args
            .get("enable")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        let toml_path = providers_toml_path();
        if !toml_path.exists() {
            return Ok(format!(
                "Archivo de providers no encontrado: {}",
                toml_path.display()
            ));
        }

        let content = std::fs::read_to_string(&toml_path)?;
        let (header, blocks) = parse_provider_blocks(&content);

        let mut found = false;
        let mut new_blocks = Vec::with_capacity(blocks.len());

        for block in &blocks {
            let block_name = block_provider_name(block).unwrap_or_default();
            if block_name == name {
                found = true;
                // Remove any existing `enabled = ...` line, then add the new value
                let mut lines: Vec<&str> = block
                    .lines()
                    .filter(|l| !l.trim().starts_with("enabled"))
                    .collect();

                if !enable {
                    // Insert `enabled = false` after the `[[providers]]` header
                    lines.insert(1, "enabled = false");
                }
                // else: removing the `enabled` line defaults to enabled=true

                let mut new_block = lines.join("\n");
                new_block.push('\n');
                new_blocks.push(new_block);
            } else {
                new_blocks.push(block.clone());
            }
        }

        if !found {
            return Ok(format!(
                "Proveedor '{}' no encontrado en {}",
                name,
                toml_path.display()
            ));
        }

        // Rewrite file
        let mut output = header;
        for block in &new_blocks {
            output.push_str(block);
        }
        std::fs::write(&toml_path, &output)?;

        // Trigger reload
        let mut router = ctx.router.write().await;
        let count = router.reload_providers().unwrap_or(0);

        let action = if enable {
            "habilitado"
        } else {
            "deshabilitado"
        };
        Ok(format!(
            "Proveedor '{}' {}.\nArchivo: {}\nProveedores activos tras recarga: {}",
            name,
            action,
            toml_path.display(),
            count,
        ))
    }

    async fn execute_send_file(args: &serde_json::Value) -> Result<String> {
        let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
        if path.is_empty() {
            return Ok("Error: se requiere el campo 'path'.".into());
        }
        let roots = telegram_allowed_roots();
        let resolved = resolve_tool_path(path, &roots)?;
        if resolved.exists() {
            let metadata = std::fs::metadata(&resolved)?;
            if metadata.len() > TELEGRAM_TOOL_MAX_FILE_BYTES {
                anyhow::bail!(
                    "Archivo demasiado grande para enviar por Telegram ({} bytes max)",
                    TELEGRAM_TOOL_MAX_FILE_BYTES
                );
            }
            Ok(format!("__SEND_FILE__:{}", resolved.display()))
        } else {
            Ok(format!("Archivo no encontrado: {}", resolved.display()))
        }
    }

    async fn execute_export_conversation(
        args: &serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<String> {
        let format = args.get("format").and_then(|v| v.as_str()).unwrap_or("txt");

        // Collect messages from all chats in conversation history
        let chats = ctx.history.chats.read().await;
        if chats.is_empty() {
            return Ok("No hay conversacion activa para exportar.".into());
        }

        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
        let export_dir = format!("{}/.local/share/lifeos/exports", home);
        std::fs::create_dir_all(&export_dir)?;

        let timestamp = chrono::Utc::now().format("%Y%m%d_%H%M%S");
        let extension = if format == "json" { "json" } else { "txt" };
        let file_path = format!("{}/conversation_{}.{}", export_dir, timestamp, extension);

        if format == "json" {
            // Export as JSON array of messages per chat
            let mut export = serde_json::Map::new();
            for (chat_id, entry) in chats.iter() {
                let msgs: Vec<serde_json::Value> = entry
                    .messages
                    .iter()
                    .map(|m| {
                        serde_json::json!({
                            "role": m.role,
                            "content": m.content,
                        })
                    })
                    .collect();
                export.insert(chat_id.to_string(), serde_json::json!(msgs));
            }
            std::fs::write(&file_path, serde_json::to_string_pretty(&export)?)?;
        } else {
            // Export as plain text
            let mut output = String::new();
            for (chat_id, entry) in chats.iter() {
                output.push_str(&format!("=== Chat {} ===\n\n", chat_id));
                if let Some(ref summary) = entry.compacted_summary {
                    output.push_str(&format!("[Resumen]: {}\n\n", summary));
                }
                for msg in &entry.messages {
                    let role_label = match msg.role.as_str() {
                        "user" => "Usuario",
                        "assistant" => "Axi",
                        "system" => "Sistema",
                        other => other,
                    };
                    let content = match &msg.content {
                        serde_json::Value::String(s) => s.clone(),
                        other => other.to_string(),
                    };
                    output.push_str(&format!("{}: {}\n\n", role_label, content));
                }
            }
            std::fs::write(&file_path, &output)?;
        }

        info!("[telegram_tools] Exported conversation to {}", file_path);

        // Return __SEND_FILE__ marker so telegram_bridge sends it to the user
        Ok(format!("__SEND_FILE__:{}", file_path))
    }

    // -----------------------------------------------------------------------
    // Helper
    // -----------------------------------------------------------------------

    #[derive(Debug, Clone)]
    struct ParsedToolCommand {
        program: String,
        args: Vec<String>,
    }

    fn telegram_allowed_roots() -> Vec<PathBuf> {
        if let Ok(configured) = std::env::var(TELEGRAM_ALLOWED_PATHS_ENV) {
            let roots = configured
                .split(':')
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(|value| normalize_path(&resolve_input_path(value, None)))
                .collect::<Vec<_>>();
            if !roots.is_empty() {
                return roots;
            }
        }

        default_telegram_allowed_roots()
    }

    fn default_telegram_allowed_roots() -> Vec<PathBuf> {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
        let mut roots = vec![
            PathBuf::from(format!("{home}/personalProjects")),
            PathBuf::from(format!("{home}/Documents")),
            PathBuf::from(format!("{home}/Downloads")),
            PathBuf::from(format!("{home}/.local/share/lifeos")),
            PathBuf::from(format!("{home}/.config/lifeos")),
            std::env::temp_dir().join("lifeos-telegram"),
        ];
        roots.sort();
        roots.dedup();
        roots
            .into_iter()
            .map(|path| normalize_path(&path))
            .collect()
    }

    fn telegram_tool_workdir(roots: &[PathBuf]) -> PathBuf {
        if let Ok(configured) = std::env::var(TELEGRAM_WORKDIR_ENV) {
            let configured = resolve_input_path(&configured, None);
            if path_is_allowed(&configured, roots) {
                return configured;
            }
        }

        if let Ok(current) = std::env::current_dir() {
            let current = normalize_path(&current);
            if path_is_allowed(&current, roots) {
                return current;
            }
        }

        roots
            .iter()
            .find(|path| path.exists())
            .cloned()
            .unwrap_or_else(|| PathBuf::from("/tmp"))
    }

    fn resolve_tool_path(path: &str, roots: &[PathBuf]) -> Result<PathBuf> {
        let workdir = telegram_tool_workdir(roots);
        let resolved = resolve_input_path(path, Some(&workdir));
        let resolved = canonicalize_for_policy(&resolved).unwrap_or(resolved);
        if path_is_allowed(&resolved, roots) {
            Ok(resolved)
        } else {
            anyhow::bail!(
                "Ruta fuera de las permitidas para Telegram. Ajusta {} si necesitas otra raiz.",
                TELEGRAM_ALLOWED_PATHS_ENV
            );
        }
    }

    fn resolve_input_path(path: &str, base_dir: Option<&Path>) -> PathBuf {
        let expanded = PathBuf::from(expand_home(path));
        let absolute = if expanded.is_absolute() {
            expanded
        } else {
            base_dir
                .map(Path::to_path_buf)
                .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/")))
                .join(expanded)
        };
        normalize_path(&absolute)
    }

    fn normalize_path(path: &Path) -> PathBuf {
        let mut normalized = if path.is_absolute() {
            PathBuf::from("/")
        } else {
            PathBuf::new()
        };

        for component in path.components() {
            match component {
                std::path::Component::RootDir => {}
                std::path::Component::CurDir => {}
                std::path::Component::ParentDir => {
                    normalized.pop();
                }
                std::path::Component::Normal(part) => normalized.push(part),
                std::path::Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            }
        }

        normalized
    }

    fn path_is_allowed(path: &Path, roots: &[PathBuf]) -> bool {
        let candidate = canonicalize_for_policy(path).unwrap_or_else(|_| normalize_path(path));
        roots
            .iter()
            .map(|root| canonicalize_for_policy(root).unwrap_or_else(|_| normalize_path(root)))
            .any(|root| candidate == root || candidate.starts_with(&root))
    }

    fn canonicalize_for_policy(path: &Path) -> Result<PathBuf> {
        let normalized = normalize_path(path);
        let mut current = normalized.clone();
        let mut missing: Vec<std::ffi::OsString> = Vec::new();

        while !current.exists() {
            let name = current
                .file_name()
                .ok_or_else(|| anyhow::anyhow!("Ruta invalida: {}", normalized.display()))?
                .to_os_string();
            missing.push(name);
            current = current
                .parent()
                .ok_or_else(|| anyhow::anyhow!("Ruta invalida: {}", normalized.display()))?
                .to_path_buf();
        }

        let mut resolved = std::fs::canonicalize(&current)?;
        for component in missing.iter().rev() {
            resolved.push(component);
        }
        Ok(normalize_path(&resolved))
    }

    fn parse_safe_command(
        command: &str,
        roots: &[PathBuf],
        workdir: &Path,
    ) -> Result<ParsedToolCommand> {
        let trimmed = command.trim();
        if trimmed.is_empty() {
            anyhow::bail!("El comando esta vacio");
        }
        if trimmed.len() > TELEGRAM_TOOL_MAX_COMMAND_CHARS {
            anyhow::bail!(
                "Comando demasiado largo (max {} caracteres)",
                TELEGRAM_TOOL_MAX_COMMAND_CHARS
            );
        }

        let blocked_fragments = ["\n", "\r", "&&", "||", ";", "|", ">", "<", "`", "$("];
        if let Some(fragment) = blocked_fragments
            .iter()
            .find(|fragment| trimmed.contains(**fragment))
        {
            anyhow::bail!("Operador de shell no permitido en Telegram: {}", fragment);
        }

        let parts = shell_words::split(trimmed)
            .map_err(|err| anyhow::anyhow!("No pude interpretar el comando: {}", err))?;
        if parts.is_empty() {
            anyhow::bail!("El comando esta vacio");
        }

        let program_token = &parts[0];
        let args = parts[1..].to_vec();
        validate_command_arguments(program_token, &args)?;
        validate_path_like_args(&args, roots, workdir)?;

        let program = if program_token.contains('/')
            || program_token.starts_with('.')
            || program_token.starts_with('~')
        {
            let resolved = resolve_input_path(program_token, Some(workdir));
            let resolved = canonicalize_for_policy(&resolved).unwrap_or(resolved);
            if !path_is_allowed(&resolved, roots) {
                anyhow::bail!(
                    "El ejecutable '{}' esta fuera de las permitidas para Telegram",
                    program_token
                );
            }
            if !resolved.exists() {
                anyhow::bail!("El ejecutable no existe: {}", resolved.display());
            }
            resolved.display().to_string()
        } else {
            validate_allowed_program(program_token)?;
            program_token.to_string()
        };

        Ok(ParsedToolCommand { program, args })
    }

    fn validate_allowed_program(program: &str) -> Result<()> {
        let allowed = [
            "pwd",
            "ls",
            "cat",
            "sed",
            "rg",
            "find",
            "git",
            "cargo",
            "make",
            "just",
            "npm",
            "pnpm",
            "yarn",
            "node",
            "python",
            "python3",
            "pytest",
            "uv",
            "go",
            "rustc",
            "rustfmt",
            "journalctl",
            "systemctl",
            "ps",
            "df",
            "du",
            "free",
            "uptime",
            "uname",
            "whoami",
            "id",
            "nvidia-smi",
            "flatpak",
            "podman",
            "docker",
            "ffmpeg",
            "whisper-cli",
            "sqlite3",
            "stat",
            "head",
            "tail",
            "wc",
            "cut",
            "sort",
            "uniq",
            "tr",
            "date",
        ];

        if allowed.contains(&program) {
            Ok(())
        } else {
            anyhow::bail!(
                "El comando '{}' no esta permitido desde Telegram. Usa herramientas dedicadas o ajusta el bridge.",
                program
            )
        }
    }

    fn validate_command_arguments(program: &str, args: &[String]) -> Result<()> {
        let lower_args: Vec<String> = args.iter().map(|arg| arg.to_lowercase()).collect();

        match program {
            "git" => {
                let blocked = [
                    "add",
                    "am",
                    "apply",
                    "bisect",
                    "checkout",
                    "cherry-pick",
                    "clean",
                    "clone",
                    "commit",
                    "fetch",
                    "merge",
                    "pull",
                    "push",
                    "rebase",
                    "reset",
                    "restore",
                    "revert",
                    "stash",
                    "submodule",
                    "switch",
                    "tag",
                    "worktree",
                ];
                if let Some(subcommand) = lower_args.first() {
                    if blocked.contains(&subcommand.as_str()) {
                        anyhow::bail!("Subcomando git no permitido desde Telegram: {}", subcommand);
                    }
                }
            }
            "systemctl" => {
                let allowed = [
                    "status",
                    "is-active",
                    "is-enabled",
                    "show",
                    "list-units",
                    "list-unit-files",
                    "cat",
                ];
                if let Some(subcommand) = lower_args.first() {
                    if !allowed.contains(&subcommand.as_str()) {
                        anyhow::bail!("Usa service_manage para mutar servicios. systemctl '{}' no esta permitido.", subcommand);
                    }
                }
            }
            "podman" | "docker" => {
                let blocked = [
                    "build", "compose", "cp", "exec", "kill", "pull", "push", "restart", "rm",
                    "rmi", "run", "start", "stop",
                ];
                if let Some(subcommand) = lower_args.first() {
                    if blocked.contains(&subcommand.as_str()) {
                        anyhow::bail!(
                            "Subcomando {} no permitido desde Telegram: {}",
                            program,
                            subcommand
                        );
                    }
                }
            }
            "flatpak" => {
                let allowed = ["list", "info", "ps", "search", "remotes"];
                if let Some(subcommand) = lower_args.first() {
                    if !allowed.contains(&subcommand.as_str()) {
                        anyhow::bail!(
                            "Subcomando flatpak no permitido desde Telegram: {}",
                            subcommand
                        );
                    }
                }
            }
            "cargo" => {
                let blocked = [
                    "add",
                    "clean",
                    "doc",
                    "init",
                    "install",
                    "login",
                    "new",
                    "owner",
                    "package",
                    "publish",
                    "remove",
                    "uninstall",
                ];
                if let Some(subcommand) = lower_args.first() {
                    if blocked.contains(&subcommand.as_str()) {
                        anyhow::bail!(
                            "Subcomando cargo no permitido desde Telegram: {}",
                            subcommand
                        );
                    }
                }
            }
            "npm" | "pnpm" | "yarn" => {
                let blocked = [
                    "add",
                    "create",
                    "dlx",
                    "exec",
                    "global",
                    "install",
                    "link",
                    "login",
                    "publish",
                    "remove",
                    "uninstall",
                    "update",
                ];
                if let Some(subcommand) = lower_args.first() {
                    if blocked.contains(&subcommand.as_str()) {
                        anyhow::bail!(
                            "Subcomando {} no permitido desde Telegram: {}",
                            program,
                            subcommand
                        );
                    }
                }
            }
            "python" | "python3" => {
                if lower_args.first().map(|arg| arg.as_str()) == Some("-c") {
                    anyhow::bail!("python -c no esta permitido desde Telegram");
                }
            }
            "node" => {
                if matches!(
                    lower_args.first().map(|arg| arg.as_str()),
                    Some("-e" | "--eval")
                ) {
                    anyhow::bail!("node --eval no esta permitido desde Telegram");
                }
            }
            _ => {}
        }

        Ok(())
    }

    fn validate_path_like_args(args: &[String], roots: &[PathBuf], workdir: &Path) -> Result<()> {
        for arg in args {
            if !looks_like_path_argument(arg) {
                continue;
            }
            let resolved = resolve_input_path(arg, Some(workdir));
            if !path_is_allowed(&resolved, roots) {
                anyhow::bail!(
                    "La ruta '{}' esta fuera de las permitidas para Telegram",
                    arg
                );
            }
        }
        Ok(())
    }

    fn looks_like_path_argument(arg: &str) -> bool {
        !arg.starts_with('-')
            && (arg.starts_with('/')
                || arg.starts_with("./")
                || arg.starts_with("../")
                || arg.starts_with("~/")
                || arg.contains('/'))
    }

    fn simple_glob_match(pattern: &str, text: &str) -> bool {
        let pattern = if pattern.is_empty() { "*" } else { pattern };
        let pattern = pattern.as_bytes();
        let text = text.as_bytes();

        let (mut p, mut t) = (0usize, 0usize);
        let (mut star_idx, mut match_idx) = (None, 0usize);

        while t < text.len() {
            if p < pattern.len() && (pattern[p] == b'?' || pattern[p] == text[t]) {
                p += 1;
                t += 1;
            } else if p < pattern.len() && pattern[p] == b'*' {
                star_idx = Some(p);
                match_idx = t;
                p += 1;
            } else if let Some(star) = star_idx {
                p = star + 1;
                match_idx += 1;
                t = match_idx;
            } else {
                return false;
            }
        }

        while p < pattern.len() && pattern[p] == b'*' {
            p += 1;
        }

        p == pattern.len()
    }

    fn expand_home(path: &str) -> String {
        if path.starts_with('~') {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
            path.replacen('~', &home, 1)
        } else {
            path.to_string()
        }
    }

    use tokio::io::AsyncWriteExt;

    // -----------------------------------------------------------------------
    // OS Control Plane — delegates to MCP server tool handlers (AY.1)
    // -----------------------------------------------------------------------

    /// Execute OS control plane tools by delegating to the MCP server's `call_tool`.
    /// Maps short Telegram tool names to their `lifeos_*` MCP counterparts.
    async fn execute_os_control(tool_name: &str, args: &serde_json::Value) -> Result<String> {
        let mcp_name = format!("lifeos_{}", tool_name);
        match crate::mcp_server::call_tool(&mcp_name, args).await {
            Ok(val) => Ok(serde_json::to_string_pretty(&val).unwrap_or_else(|_| val.to_string())),
            Err(e) => Ok(format!("Error: {}", e)),
        }
    }

    // -----------------------------------------------------------------------
    // Fase BA — Unified Memory: tools connecting all data sources to Axi
    // -----------------------------------------------------------------------

    /// BA.1 — Health status: active session, breaks, work time.
    async fn execute_health_status() -> Result<String> {
        let uptime = tokio::fs::read_to_string("/proc/uptime")
            .await
            .unwrap_or_default();
        let secs: f64 = uptime
            .split_whitespace()
            .next()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0.0);
        let hours = secs / 3600.0;
        Ok(format!(
            "Sesion activa: {:.1} horas.\nRecomendacion: {} descanso cada 2 horas.",
            hours,
            if hours > 2.0 {
                "Toma un"
            } else {
                "Aun no necesitas"
            }
        ))
    }

    /// BA.2 — Calendar today: read today's events from CalendarManager (SQLite).
    async fn execute_calendar_today(ctx: &ToolContext) -> Result<String> {
        if let Some(ref cal) = ctx.calendar {
            match cal.today() {
                Ok(events) => {
                    if events.is_empty() {
                        Ok("No tienes eventos programados para hoy.".into())
                    } else {
                        let formatted: Vec<String> = events
                            .iter()
                            .map(|e| {
                                let reminder_note = e
                                    .reminder_minutes
                                    .map(|m| format!(" (recordatorio {}min antes)", m))
                                    .unwrap_or_default();
                                format!("- {} — {}{}", e.start_time, e.title, reminder_note)
                            })
                            .collect();
                        Ok(format!("Eventos de hoy:\n{}", formatted.join("\n")))
                    }
                }
                Err(e) => Ok(format!("Error leyendo calendario: {}", e)),
            }
        } else {
            Ok("Calendario no disponible.".into())
        }
    }

    /// BD.9 — Unified agenda: calendar events + cron jobs in a single view.
    async fn execute_agenda(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let days = args.get("days").and_then(|v| v.as_u64()).unwrap_or(1) as u32;
        let days = days.clamp(1, 7);

        let spanish_months = [
            "enero",
            "febrero",
            "marzo",
            "abril",
            "mayo",
            "junio",
            "julio",
            "agosto",
            "septiembre",
            "octubre",
            "noviembre",
            "diciembre",
        ];

        let now = chrono::Local::now();
        let mut output = String::new();

        for day_offset in 0..days {
            let target_date = now + chrono::Duration::days(day_offset as i64);
            let day_num = target_date.format("%d").to_string();
            // Remove leading zero for natural Spanish formatting
            let day_num = day_num.trim_start_matches('0');
            let month_idx = target_date
                .format("%m")
                .to_string()
                .parse::<usize>()
                .unwrap_or(1)
                - 1;
            let month_name = spanish_months.get(month_idx).unwrap_or(&"???");
            let year = target_date.format("%Y");

            let label = if day_offset == 0 {
                "hoy".to_string()
            } else if day_offset == 1 {
                "manana".to_string()
            } else {
                target_date.format("%A").to_string()
            };

            output.push_str(&format!(
                "\u{1F4C5} Agenda de {} ({} de {} {}):\n\n",
                label, day_num, month_name, year
            ));

            // Calendar events for this specific day
            let target_date_str = target_date.format("%Y-%m-%d").to_string();
            let mut day_events = Vec::new();

            if let Some(ref cal) = ctx.calendar {
                // For day 0, use today(); for other days, use upcoming() and filter
                let events = if day_offset == 0 {
                    cal.today().unwrap_or_default()
                } else {
                    cal.upcoming(days)
                        .unwrap_or_default()
                        .into_iter()
                        .filter(|e| {
                            chrono::DateTime::parse_from_rfc3339(&e.start_time)
                                .map(|dt| {
                                    dt.with_timezone(&chrono::Local)
                                        .format("%Y-%m-%d")
                                        .to_string()
                                        == target_date_str
                                })
                                .unwrap_or(false)
                        })
                        .collect::<Vec<_>>()
                };

                for event in &events {
                    let time_str = chrono::DateTime::parse_from_rfc3339(&event.start_time)
                        .map(|dt| dt.with_timezone(&chrono::Local).format("%H:%M").to_string())
                        .unwrap_or_else(|_| "??:??".into());
                    let reminder_note = event
                        .reminder_minutes
                        .map(|m| format!(" (recordatorio {}min antes)", m))
                        .unwrap_or_default();
                    day_events.push(format!("  - {} {}{}", time_str, event.title, reminder_note));
                }
            }

            if day_events.is_empty() {
                output.push_str("Eventos:\n  Sin eventos.\n\n");
            } else {
                output.push_str("Eventos:\n");
                for line in &day_events {
                    output.push_str(line);
                    output.push('\n');
                }
                output.push('\n');
            }

            // Cron jobs (show on every day since they are recurring)
            if day_offset == 0 {
                let cron_jobs = ctx.cron_store.list().await;
                if cron_jobs.is_empty() {
                    output.push_str("Tareas programadas:\n  Sin tareas cron.\n\n");
                } else {
                    output.push_str("Tareas programadas:\n");
                    for job in &cron_jobs {
                        output.push_str(&format!("  - {} (cron: {})\n", job.name, job.cron_expr));
                    }
                    output.push('\n');
                }
            }
        }

        // If looking at just today, also hint about tomorrow
        if days == 1 {
            if let Some(ref cal) = ctx.calendar {
                let tomorrow_str = (now + chrono::Duration::days(1))
                    .format("%Y-%m-%d")
                    .to_string();
                let tomorrow_events: Vec<_> = cal
                    .upcoming(2)
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|e| {
                        chrono::DateTime::parse_from_rfc3339(&e.start_time)
                            .map(|dt| {
                                dt.with_timezone(&chrono::Local)
                                    .format("%Y-%m-%d")
                                    .to_string()
                                    == tomorrow_str
                            })
                            .unwrap_or(false)
                    })
                    .collect();

                if tomorrow_events.is_empty() {
                    output.push_str("Sin eventos para manana.");
                } else {
                    output.push_str(&format!("{} evento(s) para manana.", tomorrow_events.len()));
                }
            }
        }

        Ok(output)
    }

    /// BA.2 — Calendar add event via CalendarManager (SQLite + reminders).
    async fn execute_calendar_add(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let title = args["title"].as_str().unwrap_or("Sin titulo");
        let date = args["date"].as_str().unwrap_or("");
        let time = args["time"].as_str().unwrap_or("00:00");
        let reminder = args["reminder_minutes"].as_i64().unwrap_or(15) as i32;

        if date.is_empty() {
            return Ok(
                "Necesito al menos la fecha. Ejemplo: {\"title\": \"Cita medico\", \"date\": \"2026-04-05\", \"time\": \"10:00\", \"reminder_minutes\": 30}"
                    .into(),
            );
        }

        // Build start_time string for CalendarManager: "YYYY-MM-DD HH:MM"
        let start_time = format!("{} {}", date, time);

        if let Some(ref cal) = ctx.calendar {
            match cal.add_event(title, &start_time, None, "", Some(reminder), None, None) {
                Ok(event) => Ok(format!(
                    "Evento creado: {} el {} a las {}\nRecordatorio: {} minutos antes\nID: {}",
                    title, date, time, reminder, event.id
                )),
                Err(e) => Ok(format!("Error creando evento: {}", e)),
            }
        } else {
            Ok("Calendario no disponible.".into())
        }
    }

    /// BA.3 — Current context (work/personal/gaming/etc).
    async fn execute_current_context() -> Result<String> {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
        let ctx_path = format!("{}/.local/share/lifeos/current_context.json", home);
        match tokio::fs::read_to_string(&ctx_path).await {
            Ok(content) => Ok(format!("Contexto actual: {}", content.trim())),
            Err(_) => {
                Ok("Contexto actual: general (no se ha detectado un contexto especifico).".into())
            }
        }
    }

    /// BA.3 — Current experience mode.
    async fn execute_current_mode() -> Result<String> {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
        let mode_path = format!("{}/.local/share/lifeos/experience_mode.json", home);
        match tokio::fs::read_to_string(&mode_path).await {
            Ok(content) => Ok(format!("Modo activo: {}", content.trim())),
            Err(_) => Ok("Modo activo: Pro (default).".into()),
        }
    }

    /// BA.4 — Learned patterns from WorkflowLearner.
    async fn execute_learned_patterns() -> Result<String> {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
        let actions_path = format!("{}/.local/share/lifeos/workflow_actions.json", home);
        match tokio::fs::read_to_string(&actions_path).await {
            Ok(content) => {
                let count = content.lines().count();
                Ok(format!(
                    "Tengo {} acciones registradas en el workflow learner.\n\
                     El sistema detecta patrones automaticamente cuando una secuencia se repite 3+ veces.",
                    count
                ))
            }
            Err(_) => {
                Ok("Aun no he detectado patrones — necesito mas acciones registradas.".into())
            }
        }
    }

    /// BA.5 — Gaming status from nvidia-smi.
    async fn execute_gaming_status() -> Result<String> {
        let output = tokio::process::Command::new("nvidia-smi")
            .args([
                "--query-compute-apps=pid,name,used_gpu_memory",
                "--format=csv,noheader,nounits",
            ])
            .output()
            .await;
        match output {
            Ok(o) => {
                let text = String::from_utf8_lossy(&o.stdout);
                let gpu_procs: Vec<&str> = text
                    .lines()
                    .filter(|l| !l.contains("llama-server"))
                    .collect();
                if gpu_procs.is_empty() {
                    Ok("No hay juegos corriendo. GPU libre para IA.".into())
                } else {
                    Ok(format!(
                        "Procesos GPU activos (posible juego):\n{}",
                        gpu_procs.join("\n")
                    ))
                }
            }
            Err(_) => Ok("No se pudo consultar nvidia-smi.".into()),
        }
    }

    /// BA.7 — Security status: run proactive security checks.
    async fn execute_security_status() -> Result<String> {
        let alerts = crate::proactive::check_all(None, None).await;
        let security: Vec<&crate::proactive::ProactiveAlert> = alerts
            .iter()
            .filter(|a| {
                matches!(
                    a.category,
                    crate::proactive::AlertCategory::SecurityUpdate
                        | crate::proactive::AlertCategory::SystemHealth
                )
            })
            .collect();
        if security.is_empty() {
            Ok("Sistema seguro. No hay alertas de seguridad activas.".into())
        } else {
            let formatted: Vec<String> = security
                .iter()
                .map(|a| format!("- [{:?}] {}", a.severity, a.message))
                .collect();
            Ok(format!("Alertas de seguridad:\n{}", formatted.join("\n")))
        }
    }

    /// BA.6/BA.8/BA.9 — Search memory_plane by query filtered by tag.
    async fn execute_memory_search(
        args: &serde_json::Value,
        ctx: &ToolContext,
        tag_filter: &str,
    ) -> Result<String> {
        let query = args
            .get("query")
            .and_then(|v| v.as_str())
            .unwrap_or(tag_filter);
        if let Some(memory) = &ctx.memory {
            let mem = memory.read().await;
            match mem.search_entries(query, 5, Some(tag_filter)).await {
                Ok(results) => {
                    if results.is_empty() {
                        Ok(format!(
                            "No encontre nada sobre '{}' en mis registros de {}.",
                            query, tag_filter
                        ))
                    } else {
                        let formatted: Vec<String> = results
                            .iter()
                            .map(|r| {
                                let snippet = if r.entry.content.len() > 400 {
                                    format!("{}...", &r.entry.content[..400])
                                } else {
                                    r.entry.content.clone()
                                };
                                format!(
                                    "- ({}): {}",
                                    r.entry.created_at.format("%Y-%m-%d %H:%M"),
                                    snippet
                                )
                            })
                            .collect();
                        Ok(format!(
                            "Resultados ({}):\n{}",
                            tag_filter,
                            formatted.join("\n")
                        ))
                    }
                }
                Err(e) => Ok(format!("Error buscando: {}", e)),
            }
        } else {
            Ok("Memoria no disponible.".into())
        }
    }

    /// BA.8 — Activity summary from memory_plane context entries.
    async fn execute_memory_search_tag(ctx: &ToolContext, tag: &str) -> Result<String> {
        if let Some(memory) = &ctx.memory {
            let mem = memory.read().await;
            match mem
                .search_entries("app activity today", 10, Some(tag))
                .await
            {
                Ok(results) => {
                    if results.is_empty() {
                        Ok("No tengo registros de actividad reciente.".into())
                    } else {
                        let formatted: Vec<String> = results
                            .iter()
                            .map(|r| {
                                format!(
                                    "- ({}): {}",
                                    r.entry.created_at.format("%H:%M"),
                                    r.entry.content
                                )
                            })
                            .collect();
                        Ok(format!("Actividad reciente:\n{}", formatted.join("\n")))
                    }
                }
                Err(e) => Ok(format!("Error: {}", e)),
            }
        } else {
            Ok("Memoria no disponible.".into())
        }
    }

    /// Memory cleanup: run garbage filter + decay + dedup and report stats.
    ///
    /// This is the manual `/memory_cleanup` Telegram command. The same
    /// three functions also run automatically every day from the daemon
    /// housekeeping loop in `main.rs`, so calling this is normally only
    /// useful right after importing data or when investigating issues.
    async fn execute_memory_cleanup(ctx: &ToolContext) -> Result<String> {
        if let Some(memory) = &ctx.memory {
            let mem = memory.read().await;
            let garbage = mem.filter_garbage().await.unwrap_or(0);
            // apply_decay returns DecayReport { decayed, deleted }; we
            // surface decayed count here to match the previous output.
            let decay_report = mem.apply_decay().await.ok();
            let decayed = decay_report.as_ref().map(|r| r.decayed).unwrap_or(0);
            let deleted_by_decay = decay_report.as_ref().map(|r| r.deleted).unwrap_or(0);
            let deduped = mem.dedup_similar(0.90).await.unwrap_or(0);
            let stats = mem
                .health_stats()
                .await
                .unwrap_or_else(|_| serde_json::json!({}));
            Ok(format!(
                "Limpieza completada:\n\
                 - Basura eliminada: {}\n\
                 - Entradas con decay aplicado: {}\n\
                 - Entradas borradas por decay: {}\n\
                 - Duplicados fusionados: {}\n\n\
                 Estado actual:\n{}",
                garbage,
                decayed,
                deleted_by_decay,
                deduped,
                serde_json::to_string_pretty(&stats).unwrap_or_default()
            ))
        } else {
            Ok("Memoria no disponible.".into())
        }
    }

    /// Memory protect: find a memory by query and mark it permanent.
    async fn execute_memory_protect(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let query = args["query"].as_str().unwrap_or("");
        if query.is_empty() {
            return Ok("Necesito un query para buscar la memoria a proteger. Ejemplo: {\"query\": \"nombre suegro\"}".into());
        }
        if let Some(memory) = &ctx.memory {
            let mem = memory.read().await;
            match mem.search_entries(query, 1, None).await {
                Ok(results) => {
                    if let Some(r) = results.first() {
                        mem.mark_permanent(&r.entry.entry_id).await?;
                        let snippet = if r.entry.content.len() > 100 {
                            format!("{}...", &r.entry.content[..100])
                        } else {
                            r.entry.content.clone()
                        };
                        Ok(format!(
                            "Memoria protegida permanentemente:\n- [{}] {}\nEsta memoria nunca se borrara ni decaera.",
                            r.entry.kind, snippet
                        ))
                    } else {
                        Ok(format!(
                            "No encontre ninguna memoria que coincida con '{}'.",
                            query
                        ))
                    }
                }
                Err(e) => Ok(format!("Error buscando: {}", e)),
            }
        } else {
            Ok("Memoria no disponible.".into())
        }
    }

    /// Tool #79 — Manage whitelisted system services (firewall, LLM, STT).
    /// Only allows specific services and actions for security.
    async fn execute_service_manage(args: &serde_json::Value) -> Result<String> {
        let service = args["service"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'service'"))?;
        let action = args["action"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'action'"))?;

        // Whitelist of allowed services
        let allowed_services = ["nftables", "firewalld", "llama-server", "whisper-stt"];

        // Normalize service name to systemd unit
        let unit = if service.ends_with(".service") {
            service.to_string()
        } else {
            format!("{}.service", service)
        };

        let base_name = unit.trim_end_matches(".service");
        if !allowed_services.contains(&base_name) {
            return Ok(format!(
                "Servicio '{}' no esta en la lista permitida. Servicios disponibles: {}",
                service,
                allowed_services.join(", ")
            ));
        }

        let allowed_actions = [
            "start",
            "stop",
            "restart",
            "enable",
            "disable",
            "status",
            "is-active",
        ];
        if !allowed_actions.contains(&action) {
            return Ok(format!(
                "Accion '{}' no permitida. Acciones disponibles: {}",
                action,
                allowed_actions.join(", ")
            ));
        }

        // status/is-active don't need sudo
        let output = if action == "status" || action == "is-active" {
            tokio::process::Command::new("systemctl")
                .args([action, &unit])
                .output()
                .await?
        } else {
            // start/stop/restart/enable/disable need sudo
            tokio::process::Command::new("sudo")
                .args(["systemctl", action, &unit])
                .output()
                .await?
        };

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        let exit = output.status.code().unwrap_or(-1);

        if output.status.success() {
            if action == "status" {
                Ok(format!("Estado de {}:\n{}", service, stdout))
            } else {
                Ok(format!(
                    "Servicio {} — accion '{}' ejecutada correctamente.\n{}",
                    service, action, stdout
                ))
            }
        } else {
            Ok(format!(
                "Error al ejecutar '{}' en {}: exit={}\n{}{}",
                action, service, exit, stdout, stderr
            ))
        }
    }

    // -----------------------------------------------------------------------
    // Meeting management tools
    // -----------------------------------------------------------------------

    async fn execute_meeting_list(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let archive = ctx
            .meeting_archive
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Meeting archive no disponible"))?;

        let limit = args["limit"].as_u64().unwrap_or(5) as usize;
        let meetings = archive.list_meetings(limit, 0).await?;

        if meetings.is_empty() {
            return Ok("No hay reuniones registradas.".to_string());
        }

        let mut output = format!("Ultimas {} reuniones:\n\n", meetings.len());
        for m in &meetings {
            let duration_min = m.duration_secs / 60;
            let summary_preview = if m.summary.len() > 120 {
                format!("{}...", &m.summary[..120])
            } else if m.summary.is_empty() {
                "(sin resumen)".to_string()
            } else {
                m.summary.clone()
            };
            output.push_str(&format!(
                "- {} | {} | {}min | {}\n",
                &m.started_at[..10.min(m.started_at.len())],
                m.app_name,
                duration_min,
                summary_preview,
            ));
        }
        Ok(output)
    }

    async fn execute_meeting_search(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let archive = ctx
            .meeting_archive
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Meeting archive no disponible"))?;

        let query = args["query"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Falta parametro 'query'"))?;

        let limit = args["limit"].as_u64().unwrap_or(5) as usize;
        let meetings = archive.search_meetings(query, limit).await?;

        if meetings.is_empty() {
            return Ok(format!(
                "No se encontraron reuniones con '{}' en transcripcion o resumen.",
                query
            ));
        }

        let mut output = format!(
            "Encontradas {} reuniones para '{}':\n\n",
            meetings.len(),
            query
        );
        for m in &meetings {
            let duration_min = m.duration_secs / 60;
            let summary_preview = if m.summary.len() > 200 {
                format!("{}...", &m.summary[..200])
            } else if m.summary.is_empty() {
                "(sin resumen)".to_string()
            } else {
                m.summary.clone()
            };
            output.push_str(&format!(
                "## {} | {} | {}min\n{}\n\n",
                &m.started_at[..10.min(m.started_at.len())],
                m.app_name,
                duration_min,
                summary_preview,
            ));
        }
        Ok(output)
    }

    async fn execute_meeting_start(args: &serde_json::Value, ctx: &ToolContext) -> Result<String> {
        let assistant = ctx
            .meeting_assistant
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Meeting assistant no disponible"))?;

        let description = args["description"].as_str().unwrap_or("Reunion manual");

        let mut ma = assistant.write().await;
        ma.start_manual_meeting(description).await?;

        Ok(format!(
            "Grabacion de reunion iniciada: {}. Usa meeting_stop para detenerla.",
            description
        ))
    }

    async fn execute_meeting_stop(ctx: &ToolContext) -> Result<String> {
        let assistant = ctx
            .meeting_assistant
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Meeting assistant no disponible"))?;

        let mut ma = assistant.write().await;
        ma.stop_manual_meeting().await?;

        Ok("Reunion detenida. Procesando transcripcion y resumen...".to_string())
    }
}

#[cfg(feature = "telegram")]
pub use inner::*;
