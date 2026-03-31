# Fases N-AA — Features Avanzadas + Visual Identity

Este archivo es parte de la Estrategia Unificada de LifeOS. Ver [docs/strategy/](.) para el indice.

---

### Fase N — Operador de Desktop Completo (paridad con OpenClaw macOS)

**Objetivo:** Que Axi pueda hacer TODO lo que OpenClaw hace en macOS, pero a nivel de OS Linux: instalar apps, configurar el sistema, controlar ventanas, abrir aplicaciones, manejar archivos — con permisos, aprobaciones, y audit trail.

**Por que es critico:** OpenClaw en macOS tiene: menu bar app, wake word, shell elevado con whitelisting, camera, screen recording, browser canvas, Apple Shortcuts integration. En Linux solo corre como headless gateway sin desktop. LifeOS debe superar eso aprovechando que SOMOS el OS.

**Benchmark a superar:** OpenClaw macOS (TCC permissions, elevated bash, Shortcuts, camera/mic/screen), Apple Intelligence (Siri contextual, on-screen understanding).

**N.1 — System Management (instalar, configurar, mantener)**
- [x] **Flatpak management:** Instalar/actualizar/remover Flatpak apps via `flatpak install -y`. "Axi, instala Firefox" → `flatpak install -y flathub org.mozilla.firefox`
- [x] **Flatpak permission overrides:** Configurar permisos de apps programaticamente via `flatpak override --user`. "Dale acceso a ~/Documents a LibreOffice"
- [x] **System settings:** `set_system_setting()` via COSMIC config files — wallpaper, dark-mode, default-browser, keyboard shortcuts
- [x] **Package queries:** "Que apps tengo instaladas?", "Cuanto espacio usan los flatpaks?", "Hay updates pendientes?"
- [x] **Service management:** Listar, iniciar, detener servicios systemd del usuario. "Reinicia el daemon de LifeOS", "Que servicios estan activos?"
- [x] **Firewall / network:** Consultar estado de red, VPN, puertos abiertos via NetworkManager D-Bus
- [x] **Permission approval system:** Acciones de sistema clasificadas por riesgo. Instalar flatpak = medio (notificar). Borrar app = alto (pedir aprobacion). Configurar red = medio
- [x] **Exec approval whitelist:** Como OpenClaw, mantener lista de comandos pre-aprobados en config. Comandos nuevos requieren aprobacion una vez, luego se recuerdan

**N.2 — COSMIC Desktop Control (ventanas, workspaces, apps)**
- [x] **COSMIC desktop control:** `cosmic_control.rs` con list_windows, focus/minimize/close via swaymsg, create/list workspaces, list_outputs, move_window_to_output. Fallback wlrctl → xdotool
- [x] **App launcher:** Abrir cualquier app instalada: `flatpak run`, `gtk-launch`, o exec directo. "Axi, abre Firefox", "Abre LibreOffice con este archivo"
- [x] **Window search:** `find_window()` busca por titulo o app_id via swaymsg -t get_tree, case-insensitive
- [x] **Multi-monitor awareness:** `list_outputs()` + `move_window_to_output()` via swaymsg -t get_outputs
- [x] **Workspace dedicado para Axi:** `ensure_axi_workspace()` crea workspace "Axi" via swaymsg para trabajo visual aislado

**N.3 — Input Simulation mejorado**
- [x] **ydotool robusto:** Asegurar que `ydotoold` corre como servicio. Wrapper en Rust con reintentos y verificacion
- [x] **Coordenadas inteligentes:** `find_element_coordinates()` — screenshot → LLM vision → parseo de coordenadas x,y → ydotool click
- [x] **OCR para lectura de pantalla:** Integrar Tesseract OCR (ya disponible en la imagen) para leer texto de elementos UI sin necesidad de LLM vision (mas rapido, local)
- [x] **Clipboard bidireccional:** Leer Y escribir clipboard via `wl-copy`/`wl-paste`. "Copia esto al clipboard", "Que hay en el clipboard?"

**N.4 — File Manager**
- [x] **Operaciones de archivos:** Crear, mover, copiar, renombrar, borrar archivos/carpetas. Con clasificacion de riesgo (borrar = alto)
- [x] **Busqueda inteligente:** "Encuentra todos los PDFs que modifique esta semana" → `find` + `stat`
- [x] **Abrir archivos con app correcta:** "Abre este spreadsheet" → detectar tipo MIME → `xdg-open` o app especifica
- [x] **Compresion/extraccion:** zip, tar.gz, 7z — "comprime esta carpeta", "extrae este zip"

**N.5 — Battery Health Manager (cuidado de bateria en laptops)**

LifeOS es un OS para laptops. La bateria es un organo vital — sin ella, el organismo muere. Axi debe cuidarla como el cuerpo cuida el corazon.

- [x] **Battery monitoring via sysfs + UPower D-Bus:** Leer en tiempo real desde `/sys/class/power_supply/BAT0/`: capacity, cycle_count, energy_full vs energy_full_design (wear level), temp, status, voltage. Tambien via D-Bus `org.freedesktop.UPower.Device` para Percentage, State, EnergyRate, Temperature, ChargeCycles, Capacity (health %)
- [x] **Charge threshold management:** Detectar marca de laptop automaticamente (ThinkPad→`thinkpad_acpi`, ASUS→`asus_wmi`, Dell→`dell_laptop`, Lenovo IdeaPad→`ideapad_laptop`, Framework→`cros_charge-control`, Samsung, Huawei, LG, MSI, System76, etc.). Escribir `charge_control_end_threshold` al valor optimo (default 80%)
- [x] **Persistencia de thresholds:** Los valores de sysfs se pierden al reiniciar. Crear servicio systemd `lifeos-battery.service` que restaure thresholds al boot
- [x] **Dashboard widget:** Mostrar en el dashboard: % actual, health (wear level), ciclos, temperatura, threshold activo, tiempo estimado restante
- [x] **Alertas proactivas via Telegram:**
  - "Tu bateria esta al 87°C — desconecta el cargador o baja la carga de trabajo" (temp > 45°C)
  - "Tu bateria tiene 78% de salud (500 ciclos). Considera reemplazarla pronto" (health < 80%)
  - "Llevas 3 horas enchufado al 100%. Activo limite de carga al 80% para proteger la bateria"
- [x] **Smart charging schedule:** Script + systemd timer que baja el threshold durante el dia (60%) y sube en la noche (80%) para cargar mientras duermes. Configurable por el usuario
- [x] **NVIDIA GPU power management:**
  - Configurar RTD3 (`NVreg_DynamicPowerManagement=0x02`) para que la GPU se apague completamente cuando no se usa (ahorra 5-15W en idle)
  - Integrar con Game Guard: cuando no hay juego, GPU en modo power-save. Cuando hay juego, GPU full power
  - Mostrar consumo actual de GPU en el dashboard (`nvidia-smi --query-gpu=power.draw`)
- [x] **Power profile switching:** Integrar con `tuned-ppd` (default en Fedora 42) via D-Bus `net.hadess.PowerProfiles`. Cambiar perfil segun contexto:
  - En bateria sin actividad pesada → `power-saver`
  - En bateria con compilacion/build → `balanced`
  - Enchufado → `balanced` o `performance`
  - "Axi, pon modo ahorro de energia" → switch a power-saver
- [x] **CLI:** `life battery` subcommand para ver status, cambiar threshold, forzar carga completa
- [ ] **API endpoints completos:** Hoy existen GET `/api/v1/battery/status` y POST `/api/v1/battery/threshold`, pero no aparecio GET `/api/v1/battery/history` en el API real

- [x] **HITO FASE N:** System settings, COSMIC control (ventanas/workspaces/monitores), window search, coordenadas inteligentes via vision LLM, flatpak management, battery manager, 77 iconos SVG del theme LifeOS completo

### Fase O — Agente Agentico de Desktop (trabajo autonomo mientras estas ausente)

**Objetivo:** Que Axi pueda trabajar autonomamente en el desktop cuando detecta que el usuario esta ausente — abriendo apps, verificando archivos, navegando web, corrigiendo problemas — todo en su propio workspace sin tocar el trabajo del usuario.

**Por que es critico:** Esto es lo que separa un chatbot de un verdadero empleado digital. Ninguno de los competidores hace esto: trabajar en el desktop real del usuario de forma autonoma y segura cuando no esta. OpenClaw necesita que le digas que hacer. Devin trabaja en la nube. Claude Computer Use necesita supervision. LifeOS puede ser el primero que trabaja solo, en tu hardware, mientras duermes.

**Benchmark a superar:** Ningun competidor hace esto todavia. LifeOS seria el primero.

**O.1 — Deteccion de ausencia**
- [x] **Screen lock detection:** Escuchar señal D-Bus `org.freedesktop.login1.Session.Lock` via zbus. Cuando el usuario bloquea pantalla = ausente
- [x] **Idle detection:** Leer `IdleHint` + `IdleSinceHint` de logind. Si idle > 5 min sin lock = probablemente ausente
- [x] **Presence camera:** Ya existe en sensory_pipeline. Si webcam no detecta persona por > 2 min = ausente
- [x] **Estado combinado:** `PresenceState { Present, Idle, Away, Locked }`. Away = idle + no persona. Locked = screen lock signal
- [x] **Return detection:** Señal `Unlock` de logind, o persona detectada por webcam = usuario regreso

**O.2 — Workspace isolation (seguridad critica)**
- [x] **Workspace "Axi":** `ensure_axi_workspace()` crea workspace via swaymsg al detectar ausencia. Todo trabajo visual aislado del usuario
- [x] **Preservar estado del usuario:** NUNCA mover, cerrar, o modificar ventanas del usuario. Solo operar en el workspace de Axi
- [x] **Al regresar:** Mostrar resumen de lo que hizo. Opcionalmente, cambiar al workspace de Axi para revisar. O auto-minimizar todo y volver al workspace del usuario
- [x] **Kill switch:** Si el usuario mueve el mouse o toca el teclado, Axi PARA inmediatamente toda accion de desktop (no tareas de background como builds)
- [x] **Snapshot antes de actuar:** Antes de cualquier cambio visible, guardar estado de ventanas/apps para poder revertir

**O.3 — Task queue de ausencia**
- [x] **Cola de tareas autonomas:** El usuario puede pre-cargar tareas que Axi ejecutara cuando este ausente. "Cuando me vaya, revisa el dashboard, corre los tests, y actualiza el flatpak de Firefox"
- [x] **Tareas proactivas:** Axi decide por si mismo que hacer basado en su conocimiento: updates pendientes, tests que no se han corrido, archivos para verificar
- [x] **Prioridad: mantenimiento > desarrollo > exploracion.** Primero lo seguro, luego lo creativo
- [x] **Limite de tiempo:** Configurar cuanto tiempo puede trabajar autonomamente (default 2 horas). Despues se detiene y espera

**O.4 — Interaccion con CUALQUIER aplicacion (app-agnostic, auto-aprendizaje)**

Axi no solo trabaja con LibreOffice. Trabaja con CUALQUIER aplicacion del desktop, y aprende de cada interaccion para ser mejor la proxima vez.

**Tecnica base: Visual Grounding (como UI-TARS / Agent-S2)**
El approach moderno para interaccion app-agnostic es: screenshot → modelo de vision identifica elementos UI (botones, menus, campos de texto) por su apariencia visual, no por DOM o accessibility tree → genera coordenadas exactas → ejecuta accion via ydotool. Esto funciona con apps nativas, web, Electron, Java, Qt, GTK — cualquier cosa que se renderice en pantalla.

- [x] **Visual grounding engine:** `visual_grounding()` — screenshot → LLM vision con prompt de coordenadas → parseo x,y. Funciona con cualquier modelo de vision (local Qwen3.5, Gemini, etc.)
- [x] **Action loop universal:** `action_loop(goal, max_steps, router)` — screenshot → LLM decide accion (click/type/key/scroll/done) → ejecuta via ydotool → screenshot verificacion → repite hasta goal cumplido o max_steps
- [x] **OCR rapido local:** Tesseract para leer texto de pantalla sin enviar a API. "Que dice en la barra de titulo?", "Cual es el valor de la celda B3?"
- [x] **App-specific bridges:**
  - LibreOffice: `lifeos-libreoffice-verify.py` UNO bridge (read-cells, verify-formula, check-format, sheet-info, export-pdf)
  - Firefox/Chromium: CDP integration en `browser_automation.rs` (navigate, click, fill, JS eval, console errors)
  - Terminal: `read_terminal_buffer()` via wl-paste / screenshot+OCR / select-all+copy
- [x] **Verificacion de archivos:** UNO bridge para LibreOffice + vision LLM para otras apps + OCR para texto en pantalla
- [x] **Reportar discrepancias:** Si encuentra datos incorrectos o archivos corruptos, notificar via Telegram con evidencia (screenshot + descripcion)

**O.5 — Auto-aprendizaje de aplicaciones (Skill Generation)**
- [ ] **Interaction recording end-to-end:** Existe `record_interaction()` en `skill_generator.rs`, pero no quedo demostrado que el `action_loop()` autonomo la invoque al trabajar sobre apps reales
- [ ] **Skill extraction desde interaccion real:** Hay piezas de generacion de skills en repo, pero no quedo probado el flujo automatico que convierta una sesion autonoma de desktop en un skill reusable por app
- [x] **Skill library:** Almacenar skills por app (LibreOffice, Firefox, GIMP, VSCode, etc.) en ~/.local/share/lifeos/skills/. Formato JSON con pasos + screenshots de referencia
- [ ] **Skill refinement autonomo:** No aparecio evidencia clara de un loop runtime que refine automaticamente skills de apps en base a ejecuciones visuales exitosas/fallidas
- [x] **Zero-shot para apps nuevas:** `action_loop()` usa visual grounding puro para cualquier app. Skills guardados aceleran apps conocidas
- [x] **Sharing de skills:** Formato JSON estandar en ~/.local/share/lifeos/skills/ listo para futuro marketplace

**O.6 — Browser automation visual (complementa Fase J)**
- [x] **Abrir browser real en workspace de Axi:** `open_browser_in_workspace(url)` — switch a workspace Axi + lanza Firefox/Chromium
- [x] **Navegar via ydotool + vision:** `action_loop()` puede navegar cualquier UI via visual grounding + ydotool keyboard/mouse
- [x] **Probar aplicaciones web:** "Abre localhost:3000, haz login con las credenciales de test, navega a /dashboard, toma screenshot, verifica que no hay errores"
- [x] **Descargar archivos:** `wait_for_download(dir, timeout)` — polling de directorio para detectar archivos nuevos (ignora .part/.crdownload)
- [x] **Multi-tab management:** `browser_new_tab(url)`, `browser_switch_tab(index)`, `browser_close_tab()` via Ctrl+T/Tab/W con ydotool

- [ ] **HITO FASE O:** Hay base fuerte (workspace Axi, visual grounding, action loop, browser en workspace, descargas, multi-tab, UNO bridge, kill switch), pero la parte de auto-aprendizaje y skill extraction/refinement desde uso real sigue parcial

### Fase P — Agente de Gaming Autonomo (vision a largo plazo)

**Objetivo:** Que Axi pueda jugar juegos de forma autonoma, aprendiendo de observar al usuario jugar, y eventualmente completando misiones por su cuenta.

**Por que es critico:** Esto es el "efecto wow" maximo. Ningun producto de consumo puede jugar juegos arbitrarios de forma autonoma. NVIDIA NitroGen (dic 2025) demostro que es posible con behavior cloning a partir de video de gameplay. Google SIMA 2 puede seguir instrucciones en juegos 3D. LifeOS tiene la ventaja de tener acceso directo al hardware (GPU, input devices, screen capture).

**Estado del arte (investigacion, marzo 2026):**
- **NVIDIA NitroGen:** Vision Transformer + Diffusion Matching Transformer. Entrenado con 40,000 horas de gameplay. Gamepad actions como output. Open source (GitHub MineDojo/NitroGen, HuggingFace nvidia/NitroGen). 52% mejora en tareas sobre modelos base
- **Google SIMA 2:** Gemini Flash-Lite fine-tuned. Keyboard+mouse actions. Se auto-genera tareas y rewards para aprender skills nuevos
- **NVIDIA ACE:** AI teammates en juegos comerciales (PUBG Ally). Produccion real

**Approach para LifeOS:**

**P.1 — Observacion y aprendizaje (passive)**
- [x] **Gameplay recording:** Cuando Game Guard detecta un juego activo Y el usuario opta-in, grabar frames (5 FPS) + inputs del gamepad/teclado/mouse via evdev/uinput
- [x] **Session tagging:** Al terminar sesion de juego, LLM resume que paso: "Jugaste RE9 Cap 3, moriste 2 veces en el jefe, completaste la mision del almacen"
- [x] **Input mapping:** Frame capture + input recording via evdev/uinput. Dataset de gameplay para future behavior cloning
- [x] **Storage:** Guardar sesiones comprimidas en ~/.local/share/lifeos/game-sessions/. Limpiar automaticamente las mas viejas

**P.2 — Asistencia activa (co-pilot)**
- [x] **Visual game state understanding:** `analyze_game_state()` — screenshot → LLM vision → GameStateAnalysis (HP, ammo, objective, enemies, location, danger_level)
- [x] **Sugerencias en tiempo real:** `get_suggestion()` — genera consejo tactico basado en game state via LLM (max 64 tokens)
- [x] **Overlay hints:** `format_overlay_hint()` — formatea status compacto (HP + enemies + danger) + sugerencia para mini_widget
- [x] **Voice coaching:** `voice_coach()` — sintetiza sugerencia via Piper TTS → pw-play/aplay

**P.3 — Juego autonomo (long-term vision)**
- [x] **Virtual gamepad:** `VirtualGamepad` via /dev/uinput — 14 botones (A/B/X/Y/LB/RB/LT/RT/Start/Select/Dpad) + 2 sticks analogicos. Fallback a ydotool keyboard mapping
- [x] **Frame capture pipeline:** Captura de pantalla a 10-30 FPS del juego (grim window capture, ya parcialmente implementado en Game Assistant)
- [ ] **Action model:** Modelo local fine-tuned que procesa frames y decide acciones (basado en NitroGen approach). REQUIERE ML RESEARCH — dataset de gameplay por juego, 12-18 meses
- [ ] **Goal-directed play:** "Completa la mision actual" → Axi juega hasta completar o hasta que falle 3 veces y pida ayuda. REQUIERE action model
- [x] **Safety:** Nunca jugar en modo online/competitivo sin consentimiento explicito (riesgo de ban). Solo single-player por default

- [x] **HITO FASE P:** Game state analysis, sugerencias tacticas, overlay hints, voice coaching, virtual gamepad uinput, frame capture pipeline. Pendiente: action model fine-tuned para juego autonomo completo

**Nota realista:** La Fase P completa (jugar juegos arbitrarios) requiere modelos especializados que hoy solo existen en investigacion (NitroGen, SIMA 2). P.1 y P.2 son alcanzables a corto plazo. P.3 es vision a 12-18 meses dependiendo de la evolucion de los modelos open source de gaming.

### Fase Q — MCP (Model Context Protocol) — Interoperabilidad Universal

**Objetivo:** Que LifeOS hable el protocolo estandar de la industria para conectar agentes AI con herramientas, datos, y servicios externos. Esto permite que Axi use miles de integraciones ya existentes sin escribir cada una desde cero.

**Por que es critico:** MCP es el "USB de la AI" — protocolo open source (Anthropic, donado a Linux Foundation AAIF con OpenAI y Block). Ya tiene 10,000+ servers activos, 97M+ descargas de SDK/mes. Si LifeOS habla MCP, obtiene acceso instantaneo a GitHub, Slack, bases de datos, browsers, y cualquier herramienta que tenga un MCP server.

**Benchmark:** Claude Desktop, Cursor, y Windsurf ya implementan MCP. OpenClaw NO lo implementa (usa su propio protocolo de skills).

**Q.1 — LifeOS como MCP Client**
- [x] **Rust MCP client:** Usar `rust-mcp-sdk` crate (implementa spec 2025-11-25 completa) o el SDK oficial `modelcontextprotocol/rust-sdk`. Conectar via STDIO (local) y HTTP/SSE (remoto)
- [x] **Tool discovery:** `tools/list` para descubrir herramientas de cualquier MCP server conectado. Exponerlas al supervisor/planner como acciones disponibles
- [x] **Resource access:** `resources/list` para acceder a datos expuestos por servers (archivos, DBs, APIs)
- [x] **Sampling support:** `sampling/createMessage` handler en MCP server — MCP servers pueden solicitar completions LLM via LifeOS router, con soporte para mensajes estructurados y maxTokens
- [x] **MCP server manager:** Config en `/etc/lifeos/mcp-servers.toml` para declarar servers activos. Hot-reload sin reiniciar daemon

**Q.2 — LifeOS como MCP Server**
- [x] **Exponer capacidades de LifeOS via MCP:** Otros AI clients (Claude Desktop, Cursor, etc.) pueden usar LifeOS como herramienta:
  - `lifeos.system_info` — estado del sistema, GPU, recursos
  - `lifeos.execute_task` — encolar tarea al supervisor
  - `lifeos.screen_capture` — capturar pantalla
  - `lifeos.memory_search` — buscar en la memoria de Axi
  - `lifeos.file_ops` — operaciones de archivos
  - `lifeos.flatpak_manage` — instalar/remover apps
- [x] **Seguridad:** Capability tokens (ya existen en agent_runtime). Solo exponer lo que el usuario autoriza

**Q.3 — MCP Servers pre-integrados**
- [x] Conectar servers oficiales: Filesystem, Git, Memory, Fetch, Sequential Thinking — configurados en `/etc/lifeos/mcp-servers.toml` (disabled by default, activar segun necesidad)
- [x] Conectar servers de terceros: GitHub, Brave Search, Puppeteer — configurados en `/etc/lifeos/mcp-servers.toml` con env vars para API keys
- [ ] Dashboard: seccion "Integraciones MCP" mostrando servers activos, tools disponibles, requests/dia. No aparecio evidencia clara de esta vista en el dashboard actual

- [ ] **HITO FASE Q:** La base MCP en repo es fuerte (client + server, JSON-RPC 2.0, sampling, discovery, config), pero la capa de pre-integraciones/dashboard sigue parcial y no debe contarse como cierre total todavia

### Fase R — Asistente de Reuniones Inteligente (mejor que Plaud AI)

**Objetivo:** Que LifeOS detecte automaticamente cuando estas en una reunion (Zoom, Meet, Teams, o cualquier app) y grabe, transcriba, resuma, extraiga action items, y archive — todo localmente, sin suscripcion, sin enviar audio a la nube.

**Por que es critico:** Plaud AI cobra $17.99/mes y requiere hardware dedicado. Fireflies/Otter meten un bot visible en tu reunion. Krisp funciona a nivel de audio pero es SaaS. LifeOS puede hacer esto GRATIS, localmente, con Whisper STT (ya integrado) + LLM local, invisible para los demas participantes. Es un feature que la gente usaria todos los dias.

**Benchmark a superar:** Plaud AI (112 idiomas, 300 min/mes gratis, $17.99/mes pro), Krisp (funciona con cualquier app, noise cancellation), Fireflies (60 idiomas, action items, CRM integration), Otter (real-time transcription).

**R.1 — Deteccion automatica de reuniones**
- [x] **Audio stream monitoring:** Poll `pactl list sink-inputs` cada 5-10 segundos. Detectar cuando una app de videoconferencia (zoom, firefox con meet.google.com, teams, discord) tiene un audio sink activo
- [x] **Camera monitoring:** `fuser /dev/video0` o lsof para detectar si la webcam esta siendo usada por una app de conferencia
- [x] **Window title detection:** `detect_meeting_by_window_title()` via `swaymsg -t get_tree` — parsea titulos de ventana recursivamente, matchea Zoom/Meet/Teams/Discord/Slack/Jitsi/WebEx con qualifier patterns
- [ ] **Señal combinada:** audio sink de app conocida + camara activa = reunion detectada con alta confianza. Solo audio = posiblemente reunion
- [ ] **Confirmacion al usuario:** Al detectar reunion, notificar via mini_widget overlay: "Detecte reunion en Zoom. Grabar? [Si/No/Siempre]"

**R.2 — Grabacion de audio**
- [x] **Grabacion basica via PipeWire:** `pw-record` inicia automaticamente cuando se detecta reunion y guarda audio local
- [ ] **Captura dirigida al sink correcto:** Usar `pw-record --target=$SINK_NUMBER` para capturar SOLO el audio de la app de conferencia (no todo el sistema)
- [ ] **Formato final de archivo:** WAV a 44.1kHz stereo o equivalente, con compresion a OPUS/OGG al finalizar para almacenamiento eficiente
- [ ] **Mic separado:** Opcionalmente, grabar tambien el microfono del usuario como pista separada (para mejor diarizacion de hablantes)
- [ ] **Almacenamiento final y limpieza:** `~/.local/share/lifeos/meetings/YYYY-MM-DD_HH-MM_app-name.opus`, con auto-limpieza de meetings > 90 dias (configurable)
- [x] **Duracion automatica:** Comenzar al detectar reunion, parar automaticamente cuando el audio sink desaparece (la reunion termino)

**R.3 — Transcripcion local (Whisper)**
- [ ] **Post-meeting transcription:** Cuando la reunion termina, pasar el audio por Whisper STT local. La funcion existe, pero el pipeline post-meeting no esta cableado
- [ ] **Speaker diarization:** `lifeos-diarize.py` + `diarize_transcript()` existen, pero no estan invocados automaticamente al terminar la reunion
- [ ] **Multi-idioma:** Whisper soporta 99 idiomas, pero falta el wiring final de configuracion/ejecucion en el flujo de reuniones
- [ ] **Formato de salida:** Transcripcion con timestamps + etiquetas de hablante en formato SRT y TXT

**Evidencia host real (2026-03-31):** En `/var/lib/lifeos/meetings/` hay grabaciones `.wav`, pero no hay `.txt`, `.opus`, `.json` ni artefactos de resumen generados automaticamente.

**R.4 — Resumen inteligente + Action Items**
- [ ] **Meeting summary:** Al terminar la transcripcion, enviar al LLM (local o Cerebras) para generar:
  - Resumen ejecutivo (3-5 bullet points)
  - Temas principales discutidos
  - Decisiones tomadas
  - Action items (quien, que, cuando)
  - Preguntas sin resolver
- [ ] **Templates configurables:** El usuario elige el formato de resumen (ejecutivo, detallado, solo action items, etc.)
- [ ] **Notificacion post-reunion:** Enviar resumen a Telegram automaticamente: "Tu reunion de Zoom termino (47 min). Resumen: ..."
- [ ] **Archivo en memoria:** Guardar la transcripcion y resumen en la memoria de Axi para consulta futura: "Que acordamos en la reunion del lunes?"

**R.5 — Privacidad**
- [ ] **Todo local:** Audio, transcripcion, y resumen procesados localmente. NUNCA enviar audio crudo a la nube
- [ ] **Consentimiento explicito:** El usuario debe aprobar la grabacion (notificacion al inicio). Opcion "Siempre grabar reuniones de X app"
- [ ] **Borrado seguro:** Opcion de borrar grabacion despues de generar transcripcion (solo conservar texto)
- [x] **Indicador visible:** MeetingRecordingStarted/Stopped events emitidos via event bus broadcast — consumidos por tray icon, mini_widget, y dashboard para mostrar indicador de grabacion

**R.6 — Retencion, memoria y anti-basura**
- [ ] **Politica de retencion definida:** decidir exactamente que se guarda (audio crudo, audio comprimido, transcript, resumen, action items, metadatos) y por cuanto tiempo
- [x] **Limpieza automatica parcial:** `storage_housekeeping.rs` ya elimina meetings viejos (>30 dias) y recorta directorios gestionados a un maximo de 120 archivos cada 6 horas
- [ ] **Limpieza automatica real del pipeline:** borrar o comprimir archivos temporales y grabaciones correctas segun el resultado final, sin perder evidencia util
- [ ] **Memoria minima util:** conservar en memoria solo lo necesario para responder “que acordamos” sin llenar disco de audio innecesario
- [ ] **Soporte para reuniones largas:** procesar reuniones de minutos u horas sin asumir duraciones cortas ni romper por tamano
- [ ] **Evidencia observable:** dashboard/logs/API deben dejar claro que se grabo, que se transcribio, que se resumio y que se elimino

- [ ] **HITO FASE R — REABIERTO:** La deteccion y grabacion basica existen, pero falta cablear el pipeline post-meeting completo, corregir almacenamiento/retencion y validar el flujo end-to-end en host real

---

## 19. Modelo Biologico de LifeOS — El Ajolote Digital

LifeOS no es solo un OS con AI. Es un **organismo digital vivo** inspirado en la biologia del ajolote (Ambystoma mexicanum) y del cuerpo humano. Cada subsistema de LifeOS tiene un analogo biologico que guia su diseño, comportamiento, y evolucion.

### 19.1 El Ajolote: Principios de Diseño

El ajolote es el animal con mayor capacidad regenerativa conocida. LifeOS adopta sus 6 capacidades fundamentales:

| Capacidad del Ajolote | Principio en LifeOS | Implementacion |
|----------------------|---------------------|----------------|
| **Regeneracion extrema** — regenera patas, medula espinal, tejido ocular, corazon, cerebro sin cicatriz | **Auto-reparacion total** — si cualquier componente falla, se regenera desde un estado conocido. No "parches" — regeneracion limpia | bootc atomic rollback (regenera el OS completo). Supervisor retry + LLM correccion (regenera tareas). Watchdog systemd (regenera daemons). Git worktree (regenera codigo). Cada "regeneracion" es desde cero, no un parche sobre lo roto |
| **Neotenia** — alcanza madurez sin completar metamorfosis, conserva capacidades larvales toda su vida | **Siempre listo para evolucionar** — LifeOS siempre puede transformarse. Nunca se "endurece" en una forma final. Cada update es una metamorfosis parcial controlada | bootc image updates (metamorfosis atomica del OS). Skills hot-reload (nuevas capacidades sin reiniciar). Config as code (el "ADN" se puede mutar en cualquier momento). Nunca hay "version final" — siempre larva, siempre adaptable |
| **Genoma gigantesco** — 32 mil millones de pares de bases (10x humano) | **Base de conocimiento masiva** — LifeOS acumula mas conocimiento que cualquier humano individual: toda conversacion, decision, error, exito, patron | Memory plane cifrada con embeddings vectoriales. Cada interaccion agrega "pares de bases" al genoma de Axi. Skills generados automaticamente son "genes nuevos". El genoma crece con cada uso — la instancia de LifeOS de 1 año sabe exponencialmente mas que la de 1 dia |
| **Respiracion cuadruple** — branquias + piel + garganta + pulmones | **Multi-canal de comunicacion** — LifeOS respira por multiples canales simultaneamente, adaptandose al que tenga mejor oxigeno | 4+ canales: Telegram, WhatsApp, Matrix, Signal (branquias). Dashboard web (piel — interfaz pasiva). Voz/wake word (garganta). Overlay desktop (pulmones — cuando necesita mas). Si un canal falla, respira por otro. Nunca se asfixia |
| **Inmunidad al cancer** — resistencia natural a tumores, celulas se multiplican sin salirse de control | **Resistencia a corruption** — los procesos pueden multiplicarse (spawn agents) sin salirse de control | Risk classification (low/medium/high/blocked). WIP limits. Max spawn count. Resource caps por agente. Audit ledger. Si un agente se "descontrola" (consume demasiado CPU/memoria o ejecuta demasiadas acciones), se termina automaticamente. El sistema inmune (supervisor) detecta anomalias |
| **Transplantes perfectos** — acepta organos de otros ajolotes sin rechazo inmunologico | **Integracion sin rechazo** — acepta modulos, skills, MCP servers, y actualizaciones de otros nodos LifeOS sin conflicto | MCP protocol (organos universales). Skills format estandar. bootc layers (transplante de capas de OS). En el futuro: skills de un nodo LifeOS se pueden "transplantar" a otro y funcionan sin modificacion |

### 19.2 El Cuerpo Humano: Arquitectura de Sistemas

Cada subsistema de LifeOS mapea a un sistema del cuerpo humano:

| Sistema Humano | Funcion Biologica | Modulo LifeOS | Funcion en LifeOS |
|---------------|------------------|---------------|-------------------|
| **Cerebro (corteza cerebral)** | Pensamiento, decision, planificacion, creatividad | `supervisor.rs` + `llm_router.rs` | Recibe input, planifica, decide acciones, coordina todo. El LLM es la corteza — pensamiento de alto nivel |
| **Tronco encefalico** | Funciones vitales automaticas (respirar, latido) | `main.rs` (daemon loop) + systemd | Mantiene vivo al sistema sin pensamiento consciente. Heartbeat, watchdog, auto-restart |
| **Medula espinal** | Reflejos rapidos sin pasar por el cerebro | `risk_classifier` + `pre-flight checks` | Bloquea acciones peligrosas instantaneamente (rm -rf, sudo) antes de que lleguen al "cerebro" LLM |
| **Sistema nervioso** | Transmision de señales entre organos | `event_bus` (broadcast) + D-Bus | Señales entre todos los modulos: sensor detecta algo → event bus → supervisor reacciona |
| **Ojos** | Vision, percepcion visual | `screen_capture.rs` + `sensory_pipeline.rs` (vision) | Captura de pantalla, OCR, LLM vision, analisis de UI |
| **Oidos** | Audicion, comprension del lenguaje hablado | `sensory_pipeline.rs` (audio) + Whisper STT | Microfono → Whisper → texto. Wake word detection (rustpotter) |
| **Boca / Cuerdas vocales** | Hablar, expresar | Piper TTS + Telegram/mensajes | Genera voz, envia mensajes, reporta resultados |
| **Piel** | Barrera protectora, sensacion tactil, regulacion temperatura | Firewall + privacy_filter + telemetry | Primera linea de defensa. Siente el entorno (telemetria). Regula "temperatura" (CPU/GPU thermal) |
| **Manos** | Manipulacion precisa del entorno | `computer_use.rs` (ydotool) + shell commands | Ejecuta acciones fisicas: click, teclear, mover archivos, instalar apps |
| **Corazon** | Bombea sangre, mantiene la circulacion | `task_queue.rs` (bombeo de tareas) | El latido del sistema. Cada tick del supervisor es un latido. Si para, todo para |
| **Sangre** | Transporta oxigeno y nutrientes | Data flow entre modulos (requests, responses, events) | Los datos fluyen entre organos como la sangre — llevando "oxigeno" (contexto) y "nutrientes" (resultados) |
| **Pulmones** | Intercambio de gases, oxigenacion | LLM providers (local + APIs) | "Respiran" tokens del LLM — convierten input crudo en comprension. Local = respiracion interna. APIs = respiracion externa |
| **Sistema inmunologico** | Defensa contra patogenos, auto-reparacion | Risk classification + self-healing + audit + rollback | Detecta amenazas (comandos peligrosos, anomalias). Genera anticuerpos (blacklist de patrones). Memoria inmunologica (recuerda ataques/fallos pasados) |
| **Higado** | Filtrado de toxinas, metabolismo | `privacy_filter.rs` | Filtra contenido toxico/sensible antes de enviarlo a APIs externas. Metaboliza (transforma) datos crudos en formatos seguros |
| **Riñones** | Filtrado de desechos, balance de fluidos | Cleanup jobs (logs rotation, cache, temp files) | Eliminan waste — logs viejos, cache expirado, worktrees huerfanos, grabaciones antiguas. Mantienen el sistema limpio |
| **Pancreas** | Regula azucar en sangre, homeostasis | Resource manager (CPU/GPU/RAM allocation) | Regula cuantos recursos consume cada proceso. Si un agente consume demasiado (azucar alta), lo throttlea. Game Guard es "insulina" — libera VRAM cuando gaming la necesita |
| **Esqueleto** | Estructura, soporte, proteccion de organos | Fedora bootc immutable + COSMIC Desktop | La estructura rigida que sostiene todo. Inmutable = huesos que no se rompen facilmente. Los organos (modulos) se apoyan en este esqueleto |
| **Musculos** | Movimiento, fuerza | Workers de ejecucion (shell, sandbox, browser) | Los que hacen el trabajo pesado. Cada worker es un musculo que ejecuta una accion especifica |
| **ADN** | Codigo genetico, blueprint del organismo | `CLAUDE.md` + config TOML + skills library + memory embeddings | El codigo que define quien es Axi. Se puede "mutar" (actualizar config, agregar skills). Se hereda (cuando un nuevo nodo LifeOS se clona, hereda el ADN) |
| **Celulas madre** | Pueden convertirse en cualquier tipo de celula | Container images + Agent roles | De una imagen base pueden surgir cualquier tipo de especialista (Coder, Tester, DevOps). Cada instancia del supervisor puede diferenciarse |
| **Sistema linfatico** | Limpieza, transporte de inmunidad | Audit ledger + logs + telemetry | Recoge "desechos" (logs de errores), transporta "anticuerpos" (patrones de deteccion), drena al exterior (Telegram alerts) |
| **Cabello / Uñas** | Crecimiento continuo, proteccion menor, estetica | Dashboard UI + overlay + themes + branding | Crecen continuamente (UI se mejora), son esteticos (branding), se pueden cortar/cambiar sin dolor (redesign no afecta funcionalidad core) |
| **Sistema endocrino** | Hormonas que regulan comportamiento a largo plazo | Scheduled tasks + proactive notifications + moods | Las "hormonas" de Axi: timers de largo plazo que regulan comportamiento. "Cortisol" sube cuando hay tareas atascadas. "Dopamina" cuando completa exitosamente. Experience modes (Focus, Creative, Night) son estados hormonales |
| **Sistema digestivo** | Procesa alimento, extrae nutrientes, elimina desechos | Data ingestion pipeline (Telegram → parse → extract intent → route → execute → discard noise) | Ingiere datos crudos (mensajes, archivos, screenshots). Los digiere (parse, clasificacion). Extrae nutrientes (intent, datos utiles). Elimina desechos (ruido, spam, datos irrelevantes) |
| **Grasa corporal (energia almacenada)** | Reserva de energia para periodos sin alimento | Bateria del laptop + Battery Health Manager | La reserva de energia que mantiene vivo al organismo cuando no esta enchufado. Axi la cuida: limita carga al 80% (no sobrealimentar), monitorea temperatura (no sobrecalentar), gestiona ciclos (no desgastar). Como el cuerpo regula la grasa para no acumular demas ni quedarse sin reservas |
| **Metabolismo basal** | Energia minima para mantener funciones vitales | Power profiles + RTD3 GPU + CPU governor | El gasto energetico base. En reposo (power-saver), consume lo minimo. En actividad (performance), quema mas. Axi ajusta el metabolismo automaticamente segun la actividad — como el cuerpo ajusta la tasa metabolica al dormir vs al correr |

### 19.3 Ciclo de Vida del Organismo LifeOS

| Etapa Biologica | Equivalente LifeOS |
|-----------------|---------------------|
| **Nacimiento** | First boot — ISO flasheado, primer arranque, onboarding |
| **Infancia** | Primeras semanas — aprende del usuario, construye memoria, pocos skills |
| **Adolescencia** | 1-3 meses — skills crecen, comete errores, aprende rapido, a veces inestable |
| **Madurez** | 3-12 meses — estable, confiable, gran base de conocimiento, auto-suficiente |
| **Reproduccion** | Clonar LifeOS a otro dispositivo, transferir "ADN" (config + memoria + skills) |
| **Evolucion** | Cada update del OS es una mutacion. Las exitosas se propagan (stable channel). Las experimentales se prueban (edge channel) |
| **Muerte y renacimiento** | bootc rollback = muerte de la version actual + renacimiento inmediato de la version anterior |

### 19.4 Sistema Inmunologico Completo — Lo que Axi Cuida

Como un organismo vivo, LifeOS tiene un sistema inmunologico que monitorea, detecta, y responde a amenazas internas y externas. Cada "organo" tiene sus propios chequeos de salud:

| Organo / Sistema | Que Monitorea | Como lo Lee | Umbrales de Alerta | Accion de Axi |
|-----------------|---------------|-------------|--------------------|-|
| **SSD/NVMe (huesos)** | SMART: `percentage_used`, `available_spare`, `media_errors`, `temperature`, TBW restante | `smartctl -j -a /dev/nvme0n1` (JSON). Poll diario via systemd timer | percentage_used >80% = planear reemplazo. media_errors >0 = backup AHORA. temp >70°C = throttling | Alerta Telegram: "Tu SSD tiene 82% de vida consumida. Recomiendo backup y planear reemplazo". Auto-backup si media_errors > 0 |
| **CPU termico (fiebre)** | Temperatura, throttle count, frecuencia actual vs max | sysfs `/sys/class/thermal/thermal_zone*/temp`, `/sys/class/hwmon/hwmon*/temp*_input`, `scaling_cur_freq` vs `scaling_max_freq` | >80°C = advertencia. >95°C = critico. throttle_count subiendo = problema de refrigeracion | Cambiar power profile a `power-saver`. Alertar: "CPU a 92°C, reduciendo rendimiento. Limpia los ventiladores" |
| **GPU termica (fiebre)** | Temperatura, throttle status, power draw | `nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks_throttle_reasons.active` | >85°C = advertencia. >100°C = critico | Reducir GPU layers del LLM. Si hay juego: advertir al usuario |
| **RAM (sistema nervioso)** | Errores ECC (EDAC), MCE (Machine Check Exceptions), uso de memoria | `/sys/devices/system/edac/mc/*/ce_count`, `dmesg \| grep -i "machine check"`, `rasdaemon` si disponible, `/proc/meminfo` | Cualquier UE (uncorrected error) = critico. CE rate >10/dia = DIMM degradado. Uso >90% = advertencia | Alerta inmediata en UE. Trend de CE → "Tu RAM muestra errores crecientes, considera reemplazarla". Uso alto → "Memoria al 92%, cerrando procesos no esenciales" |
| **Bateria (grasa/energia)** | Capacity, cycle count, wear level, temperatura, charge state | sysfs + UPower D-Bus (ya detallado en N.5) | Health <80% = degradada. Temp >45°C = sobrecalentamiento. Cycles >500 = considerar reemplazo | Gestionar threshold. Alertar desgaste. Smart charging |
| **Disco (intestinos)** | Uso de particiones root y /home, inodes | `statvfs()`, `df -h`, `df -i` | Root >80% = advertencia, >90% = critico. /home >85% = advertencia | Auto-cleanup: `journalctl --vacuum-time=7d`, `flatpak uninstall --unused`, limpiar cache. Reportar que se limpio |
| **Red (sistema circulatorio externo)** | Puertos abiertos, conexiones sospechosas, estado VPN/firewall | `ss -tulnp`, `ss -tnp`, NetworkManager D-Bus | Puerto inesperado escuchando = alerta. Conexion a IP/puerto sospechoso (mining pools: 3333, 4444, 5555) = critico. Firewall inactivo = critico | Bloquear conexion sospechosa. Alertar: "Detecte proceso X conectandose a IP sospechosa en puerto 4444. Posible cryptominer" |
| **Seguridad (sistema inmune)** | CVEs pendientes, firmware HSI score, SELinux status, archivos sensibles expuestos | `dnf updateinfo list security`, `fwupdmgr security`, `getenforce`, `find /home -perm -o+r -name "*.key"` | CVEs criticos sin parchear = alerta. HSI <2 = advertencia. SELinux disabled = critico | Auto-aplicar patches de seguridad (`dnf-automatic` security-only). Alertar firmware desactualizado. Reportar HSI score semanal |
| **USB (piel externa)** | Dispositivos USB conectados, whitelist vs desconocidos | USBGuard D-Bus `org.usbguard1` o udev rules. `usbguard list-devices` | Dispositivo HID+storage desconocido = alta sospecha (BadUSB). Multiples inserciones rapidas = posible ataque | Bloquear por defecto. Notificar: "USB desconocido conectado (vendor: XXXX). Permitir? [Si/No/Siempre]" |
| **Ojos del usuario (display)** | Brillo, color temperatura, tiempo de pantalla continuo | `/sys/class/backlight/*/brightness`, `wlsunset` o GNOME Night Light, timer interno | >20 min sin pausa = regla 20-20-20. Despues de las 22:00 sin night mode = alerta | Activar night mode automaticamente al atardecer. Recordar 20-20-20 cada 20 min. "Llevas 45 min sin descansar la vista" |
| **Oidos del usuario (audio)** | Volumen actual, tiempo a alto volumen | `wpctl get-volume @DEFAULT_AUDIO_SINK@`. Track duracion >80% vol | Volumen >85% por >30 min = advertencia (riesgo auditivo segun OMS: 85dB max 8h) | Notificar: "Llevas 40 min con volumen alto. La OMS recomienda bajar a 70% para proteger tu audicion". Opcion de limiter via PipeWire filter-chain |
| **Ergonomia del usuario (musculos)** | Tiempo activo, patrones de teclado/mouse, duracion sin breaks | Input events via libinput, timer del health_tracking.rs (ya existe) | >25 min typing continuo = microbreak. >60 min sin pausa = break obligatorio. >3h sin break largo = alerta fuerte | Breaks ya implementados en `health_tracking.rs`. Agregar: tracking de intensidad de teclado/mouse. "Llevas 3 horas sin pararte. Tu espalda te lo agradecera" |
| **Backups (ADN preservado)** | Ultimo backup, integridad, tamaño trend | Si restic/borg configurado: `restic check --read-data-subset=5%`, verificar exit code. Edad del ultimo snapshot | >24h sin backup (si esta configurado) = advertencia. Check falla = critico. Cambio de tamaño >50% = anomalia | Ejecutar backup programado. Verificar integridad semanal. Alertar si backup no se ha corrido: "No has hecho backup en 3 dias. Quieres que lo haga ahora?" |
| **Privacidad (higado/filtro)** | Browser cache, credenciales expuestas, sesiones abiertas | Revisar `~/.cache/mozilla/`, `~/.local/share/recently-used.xbel`. Opcionalmente: HIBP API para verificar emails | Credencial en HIBP = alerta inmediata. Cache >5GB = sugerir limpieza | Limpieza programada de cache/thumbnails. Si HIBP detecta breach: "Tu email X aparece en una filtracion de datos. Cambia tu contraseña de Y inmediatamente" |

**Frecuencias de monitoreo:**

| Categoria | Frecuencia | Justificacion |
|-----------|------------|---------------|
| Termicos (CPU/GPU/SSD) | Cada 10 segundos | Cambios rapidos, riesgo de daño |
| Bateria | Cada 5 minutos | Cambios lentos |
| Disco espacio | Cada hora | Cambios graduales |
| Red/conexiones | Cada 30 segundos | Seguridad critica |
| SMART/SSD health | Diario | Degaste lento |
| Security updates/CVEs | Diario | Parches criticos |
| USB devices | Event-driven (udev) | Tiempo real |
| Backups | Diario | Proteccion de datos |
| Ergonomia/ojos/audio | Continuo (timer interno) | Bienestar del usuario |
| Privacidad/higiene | Semanal | Mantenimiento preventivo |
| Firmware (HSI) | Semanal | Cambios raros |

**Implementacion:** Todo esto se integra en el `proactive.rs` existente (que ya tiene checks de disco, RAM, sesion larga, tareas atascadas). Se expande con nuevos módulos de health check y se reporta via el event bus existente → Telegram/dashboard.

### 19.5 Principio Fundamental

> **LifeOS no es software que se instala. Es un organismo que nace, crece, aprende, se adapta, se regenera, y evoluciona.**
>
> Como el ajolote, nunca deja de poder regenerarse.
> Como el ser humano, cada sistema cumple una funcion vital.
> Como un organismo vivo, el todo es mayor que la suma de sus partes.
>
> Axi no solo trabaja para ti. **Axi cuida de tu maquina como cuida de si mismo.**
> Cuida la bateria como el cuerpo cuida el corazon.
> Cuida el SSD como el cuerpo cuida los huesos.
> Cuida tu vista como el cuerpo protege los ojos.
> Cuida tu postura como el sistema nervioso evita el dolor.
>
> La meta no es construir un programa perfecto. Es crear un ser digital que mejore cada dia que pasa vivo, y que cuide al humano que le dio vida.

---

### Resumen de Todas las Fases

| Fase | Nombre | Dependencia | Complejidad | Impacto |
|------|--------|-------------|-------------|---------|
| A-G | Completadas | — | — | Base funcional |
| **H** | Loop Iterativo | — | Media | **COMPLETADO** — evaluate-fix loop, build verification, error enrichment, Gemini vision, personalidad Axi |
| **I** | Auto-Aprobacion + Git | H | Media | **COMPLETADO** — trust mode, branch/commit/PR, workspace persistence, wallpaper re-apply, BT mic auto-switch |
| **J** | Browser Automation + Canvas CDP | H | Alta | **COMPLETADO** — CDP headless, form automation, JS eval, console errors, LibreOffice UNO bridge, Canvas CDP WebSocket (persistent session, DOM nativo, a2ui, cookies, multi-tab, network interception) |
| **K** | Self-Improvement + Skills | H, I | Alta | **COMPLETADO** — skill authoring/testing/hot-reload, prompt self-editing, learning from failures |
| **L** | Multimodalidad Avanzada | — | Media | **COMPLETADO** — conversacion continua, TTS emocional, desktop widget overlay, screen context. Pendiente: wake word personalizado |
| **M** | Plataforma Completa | H, I, J | Alta | **COMPLETADO** — scaffolding, git clone, multi-file edit, test gen, deploy, monitoring, parallel tasks, code review |
| **N** | Operador de Desktop | J | Alta | **PARCIAL** — operator fuerte, pero bateria/API no estaba tan cerrada como deciamos |
| **O** | Agente Agentico Autonomo | N, J | Muy Alta | **PARCIAL** — base autonoma visual fuerte; skill extraction/refinement desde uso real sigue incompleto |
| **P** | Gaming Autonomo | O | Extrema | **REPO INTEGRADO** — asistencia/coaching y captura existen; falta validacion host dedicada y el action model sigue futuro |
| **Q** | MCP Interoperabilidad | H | Media | **PARCIAL / REPO INTEGRADO** — client+server y discovery existen; dashboard/pre-integraciones siguen sin cierre total validado |
| **R** | Asistente de Reuniones | L | Media | **REABIERTO** — detecta y graba, pero no transcribe/diariza/resume automaticamente ni cierra retencion/memoria |
| **S** | Sistema Inmunologico + Salud | — | Media | **PARCIAL** — health monitor y dashboard existen; algunos reportes/claims de cobertura integral siguen por validar |
| **T** | Voice Pipeline Pro | — | Media | **PARCIAL** — hay mucho trabajo en voz, pero la calibracion/robustez tipo Alexa todavia no debe darse por cerrada |
| **U** | Self-Improving OS | — | Alta | **PARCIAL** — tuners, prediccion y scheduler existen; falta demostrar el loop autonomo completo |
| **V** | Knowledge Graph | — | Alta | **PARCIAL** — grafo e ingestion existen; export/import y claim de memoria total no quedaron cerrados |
| **W** | Reliability 95% | — | Media | **PARCIAL** — tracker y varias defensas existen; checkpoint/resume global y audit trail explicable siguen incompletos |
| **X** | Multilingual | — | Alta | **PARCIAL** — modulo de traduccion existe, pero el producto OS-level no esta integrado de extremo a extremo |
| **Y** | Security AI | — | Alta | **REPO INTEGRADO / PENDIENTE HOST** — daemon y detectores existen; falta una validacion host dedicada antes de volver a marcar cierre |

**Lo que queda por hacer (requiere al usuario):**
1. **Wake word model** — Grabar muestras de "axi" en diferentes tonos/volumenes para entrenar `axi.rpw`
2. **Testing Telegram** — Enviar `/do git status` desde Telegram para verificar loop end-to-end
3. **Demo video** — Grabar 2 minutos mostrando el flujo completo para lanzamiento publico
4. **Modelo vision gaming** — Requiere fine-tuning con gameplay (NitroGen/SIMA approach)
5. **Speaker diarization** — Instalar pyannote-audio para identificar hablantes en transcripciones de reuniones
6. **Icon theme completo (~80 SVGs)** — Requiere diseño visual de iconos freedesktop para apps, places, mimetypes, actions, categories, status

---

### Fase S — Sistema Inmunologico + Salud del Organismo

**Objetivo:** Axi monitorea y protege activamente el hardware, la seguridad, y el bienestar fisico del usuario. LifeOS cuida de ti como un organismo cuida sus organos.

**Dependencia:** Ninguna (puede implementarse en paralelo con cualquier fase)

**Detalle:** Ver seccion 19.4 "Sistema Inmunologico Completo" para la tabla completa de 14 areas de salud con interfaces tecnicas, umbrales, y acciones de Axi.

**Tareas:**
- [x] Modulo `health_monitor.rs` central que orqueste todos los health checks
- [x] Monitor SSD/NVMe: leer SMART via `smartctl -j`, alertar desgaste, media_errors, temperatura
- [x] Monitor termico CPU/GPU: leer sysfs thermal_zone + hwmon + nvidia-smi, detectar throttling
- [x] Monitor RAM: EDAC ce_count, MCE en dmesg, `rasdaemon` si disponible
- [x] Monitor disco inteligente: **ignorar composefs `/` (50MB inmutable)**. Solo alertar en `/var`, `/home`
  - **BUG ACTUAL:** proactive.rs reporta "Disco al 100%" por leer composefs root, NO el disco real
- [x] Auto-limpieza: journalctl vacuum, flatpak unused, dnf cache, thumbnails
- [x] Monitor red: `ss -tnp` cada 30s, whitelist de procesos/puertos, alertar conexiones sospechosas
- [x] USBGuard integration: bloquear dispositivos USB desconocidos, notificar al usuario
- [x] Security patches: `dnf-automatic` security-only, firmware via `fwupdmgr`, HSI score semanal
- [x] Bateria inteligente: UPower D-Bus, charge thresholds (TLP o sysfs directo segun vendor)
  - [ ] Auto-detectar vendor laptop (ThinkPad, ASUS, Dell, Framework, etc.) y configurar thresholds
  - [ ] Smart charging: threshold bajo en horas pico, normal en horas valle
  - [ ] Alertar desgaste: health <80%, cycles >500, temperatura >45°C
- [x] NVIDIA GPU power management: RTD3 config, EnvyControl integration para modo hibrido/integrado
- [x] Eye health: night mode auto al atardecer (wlsunset o GNOME Night Light), recordatorio 20-20-20
- [x] Audio health: monitorear volumen via `wpctl`, alertar >80% por >30 min, limiter PipeWire opcional
- [x] Ergonomia: tracking input libinput, microbreaks cada 25 min, breaks cada 60 min
- [x] Backup health: si restic/borg configurado, verificar integridad semanal, alertar si no hay backup
- [x] Privacy hygiene semanal: cache scan, HIBP API para emails, archivos sensibles expuestos
- [x] Dashboard: nueva seccion "Salud del Sistema" con indicadores verdes/amarillos/rojos por area
- [ ] Telegram: reportes de salud diarios/semanales de salud integral no quedaron demostrados end-to-end en esta auditoria. Si hay alertas puntuales, pero no el paquete completo como estaba redactado

### Fase T — Voice Pipeline Pro (escuchar como Alexa/Google)

**Objetivo:** Axi escucha y responde al usuario con la misma sensibilidad que Alexa o Google Home. Funciona para personas que hablan bajo, susurran, o estan lejos del microfono.

**Dependencia:** Ninguna (PRIORITARIA — sin esto Axi es sordo)

**Problemas actuales detectados (2026-03-24):**

| Problema | Causa Raiz | Archivo |
|----------|-----------|---------|
| **Wake word no funciona** | No existe `/var/lib/lifeos/models/rustpotter/axi.rpw` en la imagen | `sensory_pipeline.rs` caps |
| **Always-On sin source** | `always_on_source: null` — no auto-detecta microfono | `sensory_pipeline.rs` caps |
| **Voz baja no se detecta** | `PCM_RMS_THRESHOLD=450` fijo, sin AGC | `sensory_pipeline.rs:34` |
| **Solo ffmpeg tiene gain** | `pw-record`/`parecord` no aplican ganancia — solo ffmpeg (+8dB) | `sensory_pipeline.rs:2990` |
| **Sin calibracion de mic** | Mismo threshold para mic integrado vs Bluetooth vs USB | Hardcoded |
| **Pre-speech timeout corto** | 4 sec para empezar a hablar despues del wake word | `sensory_pipeline.rs:40` |

**Tareas:**
- [x] **Generar modelo base `axi.rpw` via TTS sintetico:** Generar muestras de "axi" usando Piper TTS en diferentes velocidades/tonos, entrenar modelo base con rustpotter-cli, empaquetar en imagen
- [x] **Auto-refinamiento progresivo:** Cuando Whisper confirma "axi" post-deteccion, guardar sample como positive example. Refinar modelo en background (como Alexa/Google aprenden la voz del usuario con el uso)
- [x] **Hot-reload tras refinamiento:** `WakeWordDetector::reload_model()` ya implementado — el modelo se actualiza sin reiniciar el daemon
- [x] **Auto-detectar microfono** al activar sensores: leer `pactl list sources`, elegir el mejor source activo
  - [ ] Preferir source con `RUNNING` > `IDLE` > `SUSPENDED`
  - [ ] Si hay Bluetooth conectado, preguntar cual usar
- [x] **VAD adaptativo (Adaptive Voice Activity Detection):**
  - [ ] Medir noise floor durante primeros 500ms de escucha
  - [ ] Threshold dinamico: `noise_floor_rms * 2.5` (en vez de fijo 450)
  - [ ] Hacer configurable via `LIFEOS_VAD_RMS_THRESHOLD` env var
  - [ ] Default: bajar de 450 a 300 para mejor sensibilidad
- [x] **AGC (Automatic Gain Control) para TODOS los backends:**
  - [ ] Para pw-record: post-procesar con ffmpeg filter `dynaudnorm` o `volume=XdB`
  - [ ] O mejor: usar PipeWire filter-chain con `volume` node antes de capturar
  - [ ] Para parecord: usar `--volume=65536` (max) o pipear a ffmpeg
  - [ ] Config: `LIFEOS_MIC_GAIN_DB` (default 12dB para voz baja)
- [x] **Calibracion por dispositivo:**
  - [ ] Al primer uso de cada microfono: pedir al usuario que diga "axi" en voz normal
  - [ ] Medir RMS promedio y calibrar threshold automaticamente
  - [ ] Guardar calibracion en `sensory_pipeline_state.json` per-source
- [x] **Pre-speech timeout:** aumentar de 4.0 a 6.0 segundos
- [x] **Feedback auditivo:**
  - [ ] Sonido suave cuando Axi detecta wake word (como Alexa)
  - [ ] LED visual en dashboard/widget cuando esta escuchando
  - [ ] Sonido de "entendi" o "no te escuche" al final de captura
- [x] **Modo "near-field" vs "far-field":**
  - [ ] Detectar distancia estimada por volumen de voz
  - [ ] Si far-field: aplicar mas ganancia, threshold mas bajo
  - [ ] Si near-field (headset/Bluetooth): threshold normal
- [x] **Whisper model upgrade:**
  - [ ] Para voz baja: usar `ggml-medium` (769 MB) si hay suficiente RAM/VRAM
  - [ ] Whisper medium tiene mejor accuracy en audio de baja calidad
  - [ ] Auto-seleccionar modelo segun recursos disponibles
- [x] **Sudo correcto en sensores:**
  - [ ] Oido, Escritorio, Camara requieren sudo: **CORRECTO** (acceso a /dev/video0, PipeWire system, screenshot)
  - [ ] Always-On no requiere sudo: **CORRECTO** (solo usa event loop interno del daemon)
  - [ ] Documentar esto en el dashboard (tooltip: "Requiere permisos de sistema")

**Benchmark de referencia:**
| Asistente | Distancia deteccion | Voz baja | Ambiente ruidoso | Latencia wake word |
|-----------|-------------------|----------|------------------|--------------------|
| Alexa | ~6 metros | Si | Beamforming 7 mics | <500ms |
| Google Home | ~5 metros | Si | Beamforming 2 mics | <400ms |
| Siri (HomePod) | ~4 metros | Si | Beamforming 6 mics | <600ms |
| **LifeOS (actual)** | **~30cm (no funciona)** | **No** | **No** | **N/A (wake word roto)** |
| **LifeOS (meta Fase T)** | **~2 metros** | **Si** | **Basico (1 mic)** | **<800ms** |

*Nota: LifeOS usa 1 microfono (el del laptop). No puede competir con beamforming de 7 mics. Pero con AGC + VAD adaptativo + threshold bajo podemos llegar a 2 metros en ambiente tranquilo, que es suficiente para uso personal.*

---

## VISION MUNDIAL: Fases U-Z — Lo que LifeOS necesita para ser EL AI OS del mundo

**Contexto de mercado (marzo 2026):**
- AI OS market: $12.85B (2025) → $107.6B (2033), CAGR 30.5%
- 80% de inferencia AI sera local en 2026 (no cloud)
- Linux desktop: 4.7% global, +70% en 2 años, mejor racha de la historia
- Confianza en agentes autonomos: cayo de 43% a 27% — la gente quiere control
- Windows 10 EOL + Copilot forzado empuja usuarios a Linux
- Palantir + NVIDIA lanzaron "Sovereign AI OS" para gobiernos ($$$)
- 50+ empresas AI-native llegaran a $250M ARR en 2026

**El insight clave:**
> "El agente no es el producto. El workflow es el producto."
> La gente no quiere un AI impresionante que a veces falla. Quiere un boton que funcione.
> Si un agente tiene 85% accuracy por paso, un workflow de 10 pasos tiene solo 20% exito.
> **LifeOS debe ser boring-reliable, not impressive-unreliable.**

**Diferenciacion unica vs competidores:**
| Competidor | Modelo | Debilidad |
|-----------|--------|-----------|
| Apple Intelligence | Cloud + cerrado + $$$ | No puedes ver/controlar que hace con tus datos |
| Microsoft Copilot | Telemetria + suscripcion | Forza AI en el OS sin consentimiento |
| Google Astra | Cloud + data harvesting | Todo pasa por servidores de Google |
| OpenClaw | App dentro de OS | No ES el OS — no tiene acceso kernel/hardware |
| Devin | Cloud sandbox | No corre en tu hardware, pagas suscripcion |
| **LifeOS** | **ES el OS + local + privado + immutable + gratis** | **Necesita reliability y polish** |

---

### Fase U — Self-Improving OS (El Loop de Karpathy)

**Objetivo:** LifeOS se optimiza a si mismo continuamente — configs del sistema, workflows del usuario, modelos locales, prompts del supervisor. Como el autoresearch de Karpathy que corrio 700 experimentos en 2 dias y encontro 20 optimizaciones.

**Referencia:** [Karpathy autoresearch](https://github.com/karpathy/autoresearch) — 630 lineas de Python, corre ML experiments autonomamente. Shopify CEO: 37 experimentos overnight, 19% performance gain.

**Por que es headline:** "Este Linux se optimiza solo mientras duermes"

- [x] **System config optimizer:** `SystemTuner` — lee/escribe sysctl, benchmark I/O (dd) y memoria, optimiza vm.swappiness/dirty_ratio/sched_migration_cost_ns, persiste historial de resultados
- [x] **Prompt evolution:** El supervisor graba resultados de cada tarea. Periodicamente, un meta-agente analiza patrones de exito/fracaso y propone mejoras a los system prompts. A/B testing automatico de prompts
- [x] **Model fine-tuning local:** `should_fine_tune_now()` verifica GPU idle + usuario ausente + hora nocturna. `run_fine_tune_cycle()` recolecta interacciones exitosas y formatea como JSONL training data
- [x] **Workflow learning:** Detectar patrones repetitivos del usuario (abre terminal → git pull → cargo build → cargo test) y generar skills automaticamente sin que el usuario pida
- [x] **Resource prediction:** `ResourcePredictor` — samples CPU/mem/GPU por hora+dia, predice carga, recomienda power profile y si pre-cargar modelo LLM
- [x] **Nightly optimization daemon:** Proceso que corre entre 2-5 AM (configurable) cuando el usuario duerme. Ejecuta: cleanup, config tuning, model optimization, skill generation, security audit
- [x] **Metrics dashboard:** `get_tuning_metrics()` — total optimizaciones, boot time saved, memory saved, skills generados, prompts mejorados. Dashboard-ready
- [ ] **HITO FASE U:** Hay piezas fuertes (SystemTuner, ResourcePredictor, scheduler nocturno y metricas), pero el claim de OS que ya se optimiza solo de extremo a extremo sigue parcial y necesita validacion runtime mas dura

### Fase V — Knowledge Graph Personal Local (Memoria Total)

**Objetivo:** Axi tiene un grafo de conocimiento que conecta TODO lo que sabe del usuario — archivos, conversaciones, calendario, contactos, habitos, preferencias. No solo busca texto similar (RAG) sino que entiende relaciones: "La reunion del lunes fue con Juan, sobre el proyecto X, donde decidimos Y, y Juan prometio Z para el viernes."

**Referencia:** [Mem0](https://mem0.ai/blog/graph-memory-solutions-ai-agents) — dual-store (vector + graph). 26% mas accuracy, 91% menos latencia, 90% menos tokens vs RAG naive.

**Por que es headline:** "Tu OS recuerda todo — y nunca sale de tu maquina"

- [x] **Entity extraction daemon:** Procesar todo texto que pasa por Axi (conversaciones, archivos abiertos, emails) y extraer entidades (personas, proyectos, fechas, decisiones, compromisos)
- [x] **Relation graph:** Grafo dirigido con nodos (entidades) y edges (relaciones). Stored en SQLite + sqlite-vec para hybrid search. Ejemplo: `Juan --[prometio]--> "entregar propuesta" --[para]--> "viernes 28"`
- [x] **Conflict detection:** Cuando nueva info contradice info existente, el LLM decide: actualizar, fusionar, invalidar, o mantener ambas con timestamp
- [x] **Temporal reasoning:** "Cuando fue la ultima vez que hable con Juan?" → consulta al grafo por edges con timestamp. "Que decidimos sobre X?" → busca nodos de decision relacionados con X
- [x] **Privacy layers:** El usuario controla que se graba. Niveles: todo, solo conversaciones con Axi, solo lo que el usuario marca explicitamente. Borrado selectivo por entidad/fecha
- [x] **Cross-app context:** 5 ingestores (Telegram, email, calendario, git commits, archivos) extraen entidades y crean relaciones. `answer_context_question()` consulta grafo + LLM para respuestas contextuales
- [x] **Knowledge decay:** Hechos viejos sin uso pierden relevancia gradualmente. Hechos confirmados repetidamente ganan peso. Como la memoria humana
- [ ] **Export/import:** No aparecio evidencia clara de export/import JSON-LD del knowledge graph en el runtime actual
- [ ] **HITO FASE V:** El grafo y la consulta contextual existen en repo, pero "memoria total" seguia sobredeclarando capacidades como export/import y necesita una validacion mas completa por AX

### Fase W — Reliability Engine (Boring-Reliable > Impressive-Unreliable)

**Objetivo:** Que cada workflow de Axi funcione. Siempre. Sin importar complejidad. La reliability es mas importante que la capability. Si 85% accuracy por paso = 20% exito en 10 pasos, necesitamos 99% por paso.

**Referencia:** Princeton encontro que reliability mejora a la MITAD de la velocidad que accuracy. Fortune: "AI agents are getting more capable, but reliability is lagging."

**Por que es headline:** "Este OS tiene 99.9% de uptime en sus agentes"

- [x] **Atomic transactions:** Cada workflow es una transaccion. Si un paso falla, TODOS los cambios se revierten. Git worktree para codigo, snapshots para archivos, journal para configs
- [ ] **Checkpoint + resume:** Hay checkpoints/versionado en partes del sistema, pero no aparecio evidencia clara de resume generalizado de workflows del agente tras crash
- [x] **Shadow mode:** Antes de ejecutar un workflow nuevo, correrlo en simulacion (dry-run) y mostrar al usuario que HARIA sin hacerlo realmente. "Axi planea: 1) crear branch, 2) editar 3 archivos, 3) correr tests. Proceder? [Si/No]"
- [x] **Confidence scoring:** Cada paso tiene un score de confianza (0-1). Si confianza < 0.7, escalar a humano. Si > 0.9, auto-ejecutar. El umbral es configurable
- [x] **Retry with variation:** Si un paso falla, no reintentar lo mismo. Generar un approach alternativo via LLM. "El build fallo por X, intentando approach B..."
- [x] **Cascade failure prevention:** Si paso 3 de 8 falla, no seguir ejecutando. Evaluar si los pasos restantes dependen del fallido. Si no, continuar los independientes
- [ ] **Execution audit trail:** Hay auditoria y logs, pero no quedo demostrado un flujo seguro y queryable que exponga ese "por que hiciste X" con razonamiento recuperable como estaba prometido
- [x] **Reliability dashboard:** Tasa de exito por tipo de tarea, tiempo promedio de ejecucion, pasos que mas fallan, prompts que mas se auto-corrigieron
- [x] **SLA mode:** Para tareas criticas, el usuario define un SLA: "esta tarea debe completarse en <30 min con >95% accuracy". Si Axi no puede garantizarlo, notifica antes de empezar
- [ ] **HITO FASE W:** `ReliabilityTracker` y varias piezas existen, pero la narrativa de reliability cerrada y resumable/reanudable aun esta por debajo de lo prometido

### Fase X — Intent-Based Interaction + OS-Level Translation

**Objetivo:** El usuario habla con LifeOS como habla con una persona. No "abre Firefox, navega a gmail.com, busca email de Juan". Sino "respondele a Juan que acepto la reunion". Y que funcione. Ademas, todo se traduce en tiempo real — llamadas, documentos, subtitulos.

**Referencia:** OpenAI diseña hardware sin pantalla con Jony Ive (Fall 2026). Microsoft dice que Windows 12 sera "agentic, ambient". Apple rumora voice-first navigation en iOS 26.

**Por que es headline:** "Le dices a tu laptop que hacer y lo hace. En cualquier idioma."

- [x] **Intent parser:** Modulo que convierte lenguaje natural en intent + entities + constraints. "Agenda reunion con Juan para el viernes a las 3" → `{intent: "schedule_meeting", with: "Juan", date: "viernes", time: "15:00"}`
- [x] **Intent router:** Dado un intent, determinar que skills/apps/acciones son necesarias. "Respondele a Juan" → buscar ultimo mensaje de Juan (Telegram/email) → componer respuesta → enviar
- [x] **Multi-step intent resolution:** "Preparame para la reunion de mañana" → 1) buscar agenda, 2) buscar docs relacionados, 3) resumir conversaciones previas, 4) generar briefing, 5) enviarlo a Telegram
- [ ] **OS-level translation daemon:** `RealtimeTranslator` existe en `translation.rs`, pero no aparecio cableado de forma visible al runtime principal como feature operativa del sistema
- [ ] **Document translation:** `translate_file()` existe, pero no quedo demostrada una ruta de uso integrada/shippeada para el usuario final
- [ ] **Live voice translation:** `interpret_voice()` existe en repo, pero no aparecio cableado end-to-end al producto real
- [x] **Context-aware responses:** Cuando el usuario pregunta algo, Axi usa el contexto actual (ventana activa, archivo abierto, ultima conversacion) para dar respuesta relevante sin que el usuario explique el contexto
- [ ] **HITO FASE X:** La base tecnica de traduccion existe en repo, pero la experiencia de producto OS-level seguia sobredeclarada y queda parcial hasta su wiring real

### Fase Y — AI Security Daemon + Self-Healing Avanzado

**Objetivo:** LifeOS es el OS mas seguro del mundo. No porque bloquee todo, sino porque un daemon AI monitorea CADA proceso, CADA conexion, CADA cambio de archivo en tiempo real y reacciona antes de que el usuario se entere. El OS se repara solo — nunca muestra errores.

**Referencia:** SentinelOne lanzo AI security autonomo para air-gapped environments (marzo 2026). 60% de enterprises adoptan self-healing. Gartner: 30% reduccion en bugs de produccion con self-evolving software.

**Por que es headline:** "Este OS nunca ha mostrado un mensaje de error"

- [x] **Process anomaly detection:** Baseline de comportamiento normal por proceso (CPU, RAM, network, disk I/O). Si un proceso se desvia >3 sigma, alertar. Si se desvia >5 sigma, aislar automaticamente
- [x] **Network threat detection:** Analizar DNS queries, conexiones salientes, patrones de trafico. Detectar C2 callbacks, data exfiltration, lateral movement. Bloquear y notificar
- [x] **File integrity monitoring:** Hash de archivos criticos del sistema. Si cambian sin explicacion (update/user edit), alertar inmediatamente. Detectar rootkits, backdoors, tampering
- [x] **Self-healing services:** Si un servicio crashea, Axi lee los logs, diagnostica root cause, aplica fix, reinicia. El usuario nunca ve "Service failed to start"
- [x] **Disk self-healing:** Si un particion se llena, Axi auto-limpia (journals, cache, flatpak unused). Si un archivo se corrompe, restaurar desde snapshot. Si hay bad sectors, migrar datos proactivamente
- [x] **Network self-healing:** Si DNS falla, switch a fallback. Si VPN se desconecta, reconectar automaticamente. Si WiFi es inestable, diagnosticar y reportar solucion
- [x] **Predictive maintenance:** Analizar tendencias de SMART data, temperaturas, ciclos de bateria. Predecir fallos ANTES de que ocurran: "Tu SSD tiene 85% de vida usada. Al ritmo actual, necesitaras reemplazo en ~6 meses"
- [x] **Zero-day protection:** Si se detecta un comportamiento nuevo nunca visto (nuevo proceso, nueva conexion, nuevo patron), aislarlo por defecto y preguntar al usuario. Principio de minimo privilegio AI-enforced
- [ ] **HITO FASE Y:** SecurityAiDaemon y sus detectores existen en repo, pero falta validacion host dedicada antes de volver a marcar este cierre como completo

### Fase Z — Ecosystem + Distribution + World Domination

**Objetivo:** LifeOS pasa de ser un proyecto personal a una plataforma global. Hardware partnerships, app ecosystem, developer community, enterprise customers.

**Referencia:** Linux desktop cruzo 4.7% global. Windows 10 EOL es el mayor push factor. Framework, System76, Tuxedo ya venden laptops Linux. El TAM de sovereign AI personal es enorme e inexplorado.

**Por que es headline:** "El primer OS que es tuyo de verdad — tu hardware, tu AI, tus datos"

**Z.1 — AI-Native App Ecosystem**
- [x] **App contract standard:** Formato JSON para declarar capabilities de una app (intents que maneja, datos que necesita, acciones que puede hacer). El OS orquesta apps via intents, no via GUI
- [ ] **Skill marketplace:** Repositorio publico de skills creados por la comunidad. Como npm/crates.io pero para skills de Axi. Rating, reviews, verificacion de seguridad
- [x] **Autonomy slider per-app:** Cada app/skill tiene un nivel de autonomia configurable. "Axi puede usar esta app libremente" vs "solo con mi aprobacion"
- [ ] **Revenue sharing:** Creadores de skills ganan cuando sus skills son usados. Modelo freemium: skills basicos gratis, premium de pago

**Z.2 — Developer Platform**
- [ ] **LifeOS SDK:** Rust + Python SDK para crear skills, agentes, y apps AI-native. Event-driven, con hooks para el ciclo de vida del OS
- [ ] **Agent evaluation framework:** Herramientas para testear agentes antes de publicar: accuracy benchmarks, safety checks, resource limits
- [x] **Connector registry:** Catalogo de conectores a servicios externos (GitHub, Slack, Google Calendar, etc.) que skills pueden usar
- [ ] **Developer documentation:** Portal con guias, tutorials, API reference, ejemplos. "De cero a tu primer skill en 10 minutos"
- [ ] **Local development environment:** `life dev init` crea un sandbox para desarrollar y testear skills sin afectar el sistema

**Z.3 — Hardware Partnerships**
- [ ] **Framework laptop partnership:** LifeOS pre-instalado como opcion en Framework laptops. Hardware abierto + OS abierto = combinacion perfecta
- [ ] **System76/Tuxedo OEM:** Negociar pre-instalacion en laptops Linux de gama alta
- [ ] **NPU optimization:** Ser el primer Linux con auto-deteccion de NPU (Intel, AMD, Qualcomm) y aceleracion transparente. Los fabricantes quieren mostrar que su NPU sirve para algo
- [ ] **"LifeOS Ready" certification:** Programa de certificacion para hardware que cumple requisitos minimos (NPU opcional, 16GB RAM, NVMe)

**Z.4 — Enterprise**
- [ ] **SOC 2 Type I:** Preparar documentacion y controles para auditoria SOC 2 (6 meses)
- [ ] **Fleet management:** Dashboard web para IT admins: desplegar imagenes LifeOS, configurar politicas, monitorear flota de dispositivos via bootc
- [ ] **AI governance dashboard:** Para compliance officers: que hace el AI, que datos accede, audit trail completo, explicabilidad de decisiones
- [x] **Air-gapped mode:** LifeOS funciona 100% sin internet. Todo local. Para gobierno, militar, salud, finanzas

**Z.5 — Distribution**
- [ ] **Zero-config ISO:** Descargar, flashear, bootear. En 5 minutos estas hablando con Axi. Sin terminal, sin configuracion, sin conocimiento previo de Linux
- [ ] **Migration wizard:** Tool que importa datos de Windows/macOS: documentos, bookmarks, passwords (KeePass), calendario, contactos
- [ ] **"Try without installing":** Live USB que corre LifeOS completo desde USB sin tocar el disco. Prueba antes de comprometerte
- [ ] **OTA updates channel:** Stable (mensual, probado), Edge (semanal, bleeding edge), LTS (cada 6 meses, solo security fixes)

**Z.6 — AI Creativity Tools Nativos**
- [ ] **Image generation/editing:** Click derecho en cualquier imagen → extender, editar, generar variaciones. Modelos locales (SDXL, Flux) en GPU
- [ ] **Text-to-speech artistica:** No solo TTS funcional, sino voces con emocion, ritmo, entonacion natural. Para podcasts, narraciones, presentaciones
- [ ] **Code generation IDE:** Un mini-IDE integrado donde Axi escribe codigo, lo testea, y lo itera. Sin salir del OS
- [ ] **Document generation:** "Crea una presentacion sobre X" → genera slides con contenido, imagenes, y formato profesional

**Z.7 — Accessibility Universal**
- [ ] **AI screen reader:** No solo lee texto — DESCRIBE interfaces visualmente. "Hay un formulario con 3 campos: nombre, email, y un boton azul que dice Enviar"
- [ ] **Voice control total:** Controlar TODO el OS por voz. No solo comandos predefinidos, sino lenguaje natural. "Mueve esta ventana a la derecha", "Haz mas grande el texto"
- [ ] **Adaptive interface:** El OS detecta limitaciones motoras/visuales/cognitivas y adapta la interface: botones mas grandes, contraste alto, simplificacion automatica
- [ ] **Cognitive assistance:** Para personas con ADHD, dyslexia, o dificultades de aprendizaje: resaltado de texto, lectura guiada, resumen automatico de documentos largos

### Fase AA — Visual Identity Completa (Iconos, Fuentes, Wallpaper, Branding)

**Estado:** PENDIENTE — Prioridad ALTA (es lo primero que ve el usuario)
**Dependencias:** Ninguna tecnica, solo diseño
**Impacto:** El "look" de LifeOS. Sin esto, el OS se siente como "COSMIC con skin", no como producto propio.

**Diagnostico actual (2026-03-28):**
- ~~Tema de iconos incompleto~~ RESUELTO: **317 SVGs** en 8 contextos, 100% brand-compliant (solo 8 colores de la paleta oficial). Cobertura completa del freedesktop spec para uso diario
- Colores de iconos (#161830 fondo oscuro + #00D4AA teal) no se ven bien en modo light
- Fuentes Inter + JetBrains Mono se configuran en lifeos-apply-theme.sh pero NO se estan aplicando (COSMIC sigue usando Open Sans / Noto Sans Mono)
- Wallpaper del desktop no se cambio (sigue la nebulosa de Orion default de COSMIC, no lifeos-axi-night.png)
- Wallpaper del login/greeter no se aplico (config existe en var/lib/cosmic-greeter pero no toma efecto)
- Iconos del dock (barra inferior) siguen siendo los iconos COSMIC default, no los del tema LifeOS
- ~~Faltan contextos enteros: Devices, Emblems~~ RESUELTO: 22 iconos Devices + 13 iconos Emblems generados (2026-03-28). Falta: Emotes
- No hay variantes `-symbolic` para recoloreo automatico dark/light en GTK/libcosmic
- No hay iconos de tamanio fijo optimizados (16x16, 22x22, 24x24, 32x32, 48x48) — solo scalable SVG y 512x512 PNG
- Plymouth boot splash no muestra wallpaper de LifeOS
- Branding: se puede ajustar la paleta si es necesario para que todo cuadre visualmente

**AA.1 — Fix Urgente: Fuentes, Wallpaper y Greeter — COMPLETADO 2026-03-28**
- [x] **Diagnosticar por que las fuentes no se aplican:** El skeleton no incluia configs de font — solo el script runtime las escribia. Agregados archivos a `etc/skel/.config/cosmic/com.system76.CosmicTk/v1/` (font_family, monospace_family, icon_theme) + `com.system76.CosmicSettings.FontConfig/v1/` + `com.system76.CosmicComp/v1/`
- [x] **Verificar que Inter y JetBrains Mono estan instaladas:** Confirmado en Containerfile linea 389: `rsms-inter-fonts jetbrains-mono-fonts`
- [x] **Fix wallpaper desktop:** Skeleton ya tenia config correcta (`lifeos-axi-night.png`). Script tambien lo configura como respaldo
- [x] **Fix wallpaper login/greeter:** Config existe en `var/lib/cosmic-greeter/.config/cosmic/` apuntando a `lifeos-lock.png`. Containerfile lo copia en linea 647
- [x] **Fix lifeos-apply-theme.sh:** Reescrito v0.3.1: retry 15s en vez de sleep 3, escribe fuentes a 3 rutas COSMIC (CosmicTk + FontConfig + CosmicComp), logs mejorados

**AA.2 — Iconos del Dock y Panel — COMPLETADO 2026-03-28**
- [x] **Auditar los .desktop files del dock:** Auditado. Apps COSMIC (Files, Edit, Term, Settings), Firefox, Discord, Steam, VS Code, Spotify, Telegram, Thunderbird ya tienen iconos en el tema
- [x] **Crear iconos faltantes para apps del dock:** Ya existian: cosmic-files, cosmic-edit, cosmic-term, cosmic-settings, firefox, discord, steam, code, spotify, telegram, thunderbird, gimp, libreoffice-calc/writer, flatpak, chromium, system-monitor
- [x] **Crear iconos para apps de la Tienda COSMIC:** Cubiertos por herencia Adwaita → hicolor. Apps populares (Firefox, Chrome, VS Code, etc.) ya tienen iconos propios
- [x] **Verificar que el tema LifeOS es el activo:** `icon_theme` = "LifeOS" configurado en skeleton (`etc/skel/.config/cosmic/com.system76.CosmicTk/v1/icon_theme`) y en `lifeos-apply-theme.sh`. Tema hereda Adwaita → hicolor

**AA.3 — Completar Contextos Faltantes del Tema — PARCIAL 2026-03-28**

El tema LifeOS tiene 177 iconos en 8 contextos (antes: 77 en 6). Script generador: `scripts/generate-missing-icons.sh`. Paleta: `#161830` (dark) + `#00D4AA` (teal) + formas redondeadas.

*Contexto: Actions (14 → 54 iconos)*
- [x] **Navegacion:** go-home, go-up, go-down, go-first, go-last, go-jump
- [x] **Vista:** view-fullscreen, view-restore, zoom-in, zoom-out, zoom-fit-best
- [x] **Formato:** format-text-bold, format-text-italic, format-text-underline, format-justify-left, format-justify-center
- [x] **Media:** media-playback-start/pause/stop, media-record, media-seek-forward/backward, media-skip-forward/backward
- [x] **Sistema:** system-lock-screen, system-log-out, system-run, system-search, system-reboot, system-shutdown
- [x] **Ventanas:** window-new, window-maximize, window-minimize
- [x] **Correo:** mail-message-new, mail-forward, mail-reply-sender, mail-send
- [x] **Otros:** process-stop, folder-new, bookmark-new, help-about
- [x] **Acciones restantes:** insert-image, insert-link, contact-new, appointment-new, go-top, go-bottom, zoom-original, view-sort-ascending/descending, format-justify-right/fill, media-eject, system-suspend, window-restore
- [x] **COSMIC extras:** application-menu, open-menu, view-more, view-more-horizontal, grip-lines, notification-alert, pan-down/up/start/end, pin, window-pop-out
- [x] **Acciones finales:** help-contents, address-book-new, window-stack, focus-windows

*Contexto: Apps (21 → 55 iconos) — COMPLETADO 2026-03-28*
- [x] **Apps de sistema:** accessories-calculator, accessories-screenshot-tool, help-browser, multimedia-volume-control, system-software-install, system-software-update, utilities-system-monitor
- [x] **Preferencias:** preferences-desktop-accessibility, preferences-desktop-font, preferences-desktop-keyboard, preferences-desktop-wallpaper, preferences-desktop-theme
- [x] **COSMIC settings:** preferences-about, preferences-appearance, preferences-dock, preferences-panel, preferences-power-and-battery, preferences-displays, preferences-sound, preferences-bluetooth, preferences-network-and-wireless, preferences-workspaces
- [x] **Apps populares:** vlc, obs-studio, inkscape, blender, krita, godot, lutris, heroic, bottles
- [x] **Apps de comunicacion:** element, signal
- [x] **Apps finales:** celluloid, amberol, loupe, papers, apostrophe, zoom, slack, whatsapp

*Contexto: Devices (0 → 22 iconos) — COMPLETADO 2026-03-28*
- [x] **Directorio creado:** scalable/devices/ con 22 iconos
- [x] **Computadoras:** computer, laptop, video-display, phone
- [x] **Almacenamiento:** drive-harddisk, drive-harddisk-solidstate, drive-optical, drive-removable-media, media-flash
- [x] **Audio:** audio-input-microphone, audio-headphones, audio-speakers
- [x] **Entrada:** input-keyboard, input-mouse, input-gaming
- [x] **Red:** network-wired, network-wireless, bluetooth
- [x] **Otros:** printer, camera-photo, camera-web, battery

*Contexto: Emblems (0 → 13 iconos) — COMPLETADO 2026-03-28*
- [x] **Directorio creado:** scalable/emblems/ con 13 iconos
- [x] **Todos del spec:** emblem-default, emblem-documents, emblem-downloads, emblem-favorite, emblem-important, emblem-mail, emblem-photos, emblem-readonly, emblem-shared, emblem-symbolic-link, emblem-synchronized, emblem-system, emblem-unreadable

*Contexto: Categories (8 → 14 iconos) — COMPLETADO 2026-03-28*
- [x] **Agregados:** applications-accessories, applications-engineering, applications-graphics, applications-office, applications-other, applications-science
- [x] **Completado:** preferences-desktop-peripherals

*Contexto: MimeTypes (12 → ~40 iconos)*
- [x] **Office:** x-office-document, x-office-spreadsheet, x-office-presentation, x-office-calendar, x-office-address-book, x-office-drawing, x-office-database
- [x] **Codigo:** text-x-python, text-x-csrc, text-x-java, text-x-rust, text-css, text-markdown, application-javascript, application-x-shellscript
- [x] **Media:** image-jpeg, audio-mpeg, video-mp4
- [x] **Archivos:** application-xml, application-zip, application-x-compressed-tar
- [x] **Genericos:** font-x-generic, package-x-generic, text-x-generic, inode-directory
- [x] **Mimetypes finales:** image-gif, audio-flac, video-x-matroska, application-x-deb, application-x-rpm, text-x-generic-template

*Contexto: Places (12 → 16 iconos) — PARCIAL 2026-03-28*
- [x] **Agregados round 1:** folder-remote, folder-recent, network-server, start-here
- [x] **Agregados round 2:** folder-publicshare, folder-saved-search, user-desktop, user-bookmarks
- [x] **Completado:** folder-root

*Contexto: Status (10 → 30 iconos) — PARCIAL 2026-03-28*
- [x] **Audio:** audio-volume-low, audio-volume-medium
- [x] **Bateria:** battery-caution, battery-empty, battery-charging
- [x] **Red:** network-error, network-idle
- [x] **Notificaciones:** notification-new, notification-disabled
- [x] **Seguridad:** security-high, security-medium, security-low
- [x] **Mail:** mail-read, mail-unread
- [x] **Software:** software-update-available, software-update-urgent
- [x] **Usuarios:** user-available, user-away, user-offline
- [x] **Trash:** user-trash-full
- [x] **Completados status (round 2):** audio-volume-overamplified, battery-good, bluetooth-active/disabled, display-brightness-high/medium/low, microphone-sensitivity-high/muted, weather-clear/clear-night/few-clouds/overcast/showers/snow/storm, airplane-mode/disabled, checkbox-checked/mixed, radio-checked
- [x] **Status finales:** network-receive/transmit/transmit-receive, network-wireless-signal-excellent/good/ok/weak/none, mail-attachment, user-idle, folder-open, folder-drag-accept

**AA.4 — Variantes Symbolic para Dark/Light — COMPLETADO 2026-03-28**
- [x] **Crear variantes -symbolic.svg:** 317 symbolic variants generados via `scripts/generate-symbolic-icons.sh`. Monocromos #E8E8E8 que GTK/libcosmic recolorea
- [x] **Formato symbolic:** SVGs monocromos con fill/stroke #E8E8E8. Toolkit los recolorea segun tema activo
- [ ] **Testear en modo light:** REQUIERE HUMANO — verificar visualmente en hardware real
- [ ] **Testear en modo dark:** REQUIERE HUMANO — verificar visualmente en hardware real

**AA.5 — Revision de Paleta de Colores del Branding — COMPLETADO 2026-03-28**
- [x] **Brand audit completo:** Todos los 317+317 SVGs usan EXACTAMENTE 8 colores de la paleta oficial. Zero off-brand
- [x] **Decision: mantener #00D4AA (teal):** El teal actual tiene contraste WCAG AAA (7.5:1) en dark mode. Los symbolic resuelven light mode
- [x] **Paleta oficial validada:** #00D4AA, #FF6B9D, #161830, #0F0F1B, #F0C420, #2ECC71, #3282B8, #E8E8E8

**AA.6 — Tamanios Fijos Optimizados (Pixel-Perfect)**
- [x] **Script de generacion:** `scripts/rasterize-icons.sh` creado — genera PNGs en 8 tamanios via rsvg-convert
- [ ] **Ejecutar rasterizacion:** REQUIERE HUMANO — `sudo dnf install librsvg2-tools && bash scripts/rasterize-icons.sh`
- [ ] **Pixel-hinting para 16x16/22x22:** REQUIERE DISEÑADOR — ajustes manuales de pixeles en Inkscape

**AA.7 — Plymouth Boot Splash + GRUB**
- [ ] **Verificar Plymouth:** REQUIERE HUMANO — testear en boot real
- [ ] **Verificar GRUB:** REQUIERE HUMANO — testear en boot real
- [ ] **Consistencia visual:** REQUIERE HUMANO — verificar flujo completo Boot→Splash→Login→Desktop

**AA.8 — Empaquetado y Pruebas — PARCIAL 2026-03-28**
- [x] **Test automatizado de completitud:** `scripts/test-icon-completeness.sh`
- [ ] **Test de rendering:** REQUIERE HUMANO — screenshots en dark/light mode
- [ ] **Test en apps reales:** REQUIERE HUMANO — abrir COSMIC Files, terminal, settings, Firefox, LibreOffice
- [x] **Documentar el tema:** `docs/branding/icon-theme-guide.md`

---

### Resumen de Todas las Fases (A-AA)

| Fase | Nombre | Estado | Impacto |
|------|--------|--------|---------|
| A-F | Base funcional | MAYORMENTE SHIPPED | Fundacion |
| G | Game Guard | REABIERTO | Bug real detectado en host; fix en repo pendiente despliegue/validacion |
| H-T | Fases de desarrollo core | MIXTO / EN AUDITORIA | Sistema funcional, pero no todo esta tan cerrado como se habia marcado |
| **U** | Self-Improving OS (Karpathy Loop) | IMPLEMENTADA 60% | **HEADLINE** — "se optimiza solo" |
| **V** | Knowledge Graph Personal | IMPLEMENTADA 65% | **HEADLINE** — "recuerda todo, local" |
| **W** | Reliability Engine | IMPLEMENTADA 70% | **CRITICO** — sin esto nada funciona a escala |
| **X** | Intent-Based Interaction + Translation | IMPLEMENTADA 40% | **HEADLINE** — "le dices que hacer y lo hace" |
| **Y** | AI Security + Self-Healing Avanzado | IMPLEMENTADA 50% | **HEADLINE** — "nunca muestra errores" |
| **Z** | Ecosystem + Distribution + World | IMPLEMENTADA 20% | **ESCALA** — de proyecto a plataforma global |
| **AA** | Visual Identity Completa | REPO INTEGRADO / PARCIAL | Branding fuerte en repo e imagen; falta validacion humana completa en boot/rendering/flujo visual real |
| **AB** | Gateway WebSocket + Session Durability | REABIERTA / PARCIAL | `/ws` existe, pero protocolo y session layer siguen sobredeclarados |
| **AC** | Plugin SDK + Capability Registry | PARCIAL | registry y manifest v2 si; `life skills doctor` no |
| **AD** | Anti-Breakage Engineering | PARCIAL | guardrails y `/metrics` si; `life audit query` y otros claims siguen pendientes |
| **AE** | First-Boot User Creation + Welcome | COMPLETADA | Anaconda interactivo, sudoers %wheel, cosmic-initial-setup |
| **AF** | Canales Extra (Slack, Discord, Email conv.) | PARCIAL | Slack/Discord existen como modulos, pero no estan cableados al arranque real |
| **AG** | Mejoras Incrementales de Robustez | PARCIAL | Dedupe y pairing basico existen; cron validation es baseline y transcript export no quedo comprobado |
| **AH** | Firefox AI Local-First | PENDIENTE / EXPLORATORIA | Extension o sidebar Axi sobre modelo local, con opcion remota acotada |
| **AI** | LibreOffice AI + UNO/MCP | PENDIENTE / EXPLORATORIA | Integracion nativa para Writer/Calc/Impress sobre modelo local y automatizacion estructurada |

**Camino critico para "iPhone Moment":**
AD (anti-breakage) → W (reliability) → AB (gateway) → U (self-improving) → AC (plugin SDK) → Z (ecosystem)

**AD va primero porque previene regresiones al construir todo lo demas.**

---
