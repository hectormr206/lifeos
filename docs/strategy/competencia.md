# LifeOS Analisis Competitivo

> Este archivo es parte de la Estrategia Unificada de LifeOS. Ver [docs/strategy/](../strategy/) para el indice completo.

---

## Competencia Real al 23 de Marzo de 2026

### Competencia directa: nadie ha ganado la categoria

| Competidor | Estado | Amenaza | Ventaja de LifeOS |
|------------|--------|---------|-------------------|
| **OpenClaw** | Open-source, viral. Peter Steinberger (PSPDFKit). 21+ canales messaging. 13,729+ community skills en ClawHub. Browser headless, cron, self-improvement (escribe sus propios skills). macOS menu bar app con wake word | **ALTA** — es el benchmark inmediato | Tu ERES el OS. OpenClaw es app dentro de OS. En Linux solo corre como headless gateway (sin desktop). LifeOS tiene desktop overlay, computer use, GPU management |
| **Devin AI** | $20/mes (bajo de $500). 67% PR merge rate. Compro Windsurf por $250M. Goldman Sachs lo usa (20% efficiency gains). Sandbox cloud con IDE+terminal+browser propio | **ALTA** para coding | Solo coding. No es asistente de vida. Cloud-only. Sin privacidad |
| **Replit Agent 3** | 10x mas autonomo que v2. 200 min ejecucion continua. Auto-abre apps en browser, encuentra bugs, los corrige. Deploy con 1 click | **MEDIA** para webapps | Solo web apps. Cloud-only. No es OS. Sin privacidad local |
| **AthenaOS** (kyegomez) | Concepto de OS con millones de agentes swarm. Rust + C++. 1700+ contribuidores de Agora | Baja hoy, potencial en 12-18 meses | Tu tienes producto funcional corriendo en hardware real |
| **MAGI OS** | Distro experimental AI + Debian/MATE. Descargable como ISO | Baja. Proyecto de investigacion | Mucho mas limitado que LifeOS en todo |
| **RHEL AI** | Red Hat enterprise con InstructLab. Produccion | Baja para personal, alta para enterprise | Enfocado en servidor, no desktop personal |
| **deepin 25 AI** | Dos agentes AI nuevos (writing/data), OCR mejorado | Media en Asia | LifeOS tiene multimodalidad completa, no solo writing/OCR |

### Competencia indirecta: herramientas que compiten por tu tiempo

| Competidor | Estado | Diferencia clave |
|------------|--------|-----------------|
| **Claude Computer Use** | Produccion macOS (marzo 2026). Anthropic compro Vercept. Ve pantalla pixel a pixel, controla mouse/keyboard en cualquier app | Es API cloud, no OS. LifeOS ya tiene computer_use local + puede usar Claude API como cerebro premium |
| **Cursor / Windsurf** | Cursor: 50%+ Fortune 500. Background Agents autonomos. Windsurf: #1 en rankings AI dev tools 2026, adquirido por Cognition (Devin) | Son IDEs, no OS. Solo coding. LifeOS puede ser la plataforma donde corren |
| **Open Interpreter** | Open source. 01 Light hardware (ESP32, voice-controlled). Experimental OS mode (screen+mouse). Ejecuta Python/bash local | Es framework, no OS. Menos robusto que LifeOS. Pero la vision es similar |
| **CrewAI** | $18M funding. 100K+ devs certificados. 60% Fortune 500. 60M+ agent executions/mes | Son librerias Python. LifeOS puede usarlas como motor interno |
| **AutoGPT** | 167K+ GitHub stars. Pionero de agentes autonomos | Requiere mucho human oversight. No production-ready |
| **Screenpipe** | Open source MIT, $400 lifetime, graba pantalla/audio 24/7 | Es app no OS. Tu sensory_pipeline hace lo mismo a nivel kernel |

### Lo que los gigantes estan haciendo

| Gigante | Estado Marzo 2026 | Implicacion para LifeOS |
|---------|-------------------|------------------------|
| **Microsoft Copilot+** | Agents como "digital teammates" en M365. Computer Use en Copilot Studio (preview). Work IQ layer con memoria entre sesiones. Pero: RETROCEDIERON en Windows 11 (cancelaron Copilot en Photos/Widgets/Notepad). Recall sigue con problemas de seguridad | Ventana abierta. El mercado rechaza AI invasiva mal hecha. Pero el enterprise se mueve rapido |
| **Apple Intelligence** | Foundation Models framework (Swift API). Visual Intelligence. Siri 2.0 agentico esperado junio 2026. Private Cloud Compute. Partnership con Google para Gemini | No competira con autonomia real por años. Pero la barra de UX sube |
| **Google Project Astra** | Universal AI assistant. Video real-time con latencia ~cero. Project Mariner para tareas web complejas. Android XR smart glasses con Samsung | Solo movil/cloud. Desktop Linux no es target. Pero la calidad multimodal es el benchmark |
| **Samsung/Google Gemini** | Agresivo en movil. Gemini controla apps en Galaxy S26. 800M dispositivos | Solo movil. Desktop Linux es diferente |
| **Limitless (ex-Rewind)** | **MUERTO.** Meta lo compro, servidores apagandose, Pendant descontinuado | Oportunidad: el espacio de "memoria personal AI" quedo huerfano |
| **Humane AI Pin** | **MUERTO.** Discontinuado. HP compro restos por $116M. Overheating + $24/mo subscription fail | Hardware AI dedicado fracaso |
| **Rabbit R1** | Sobrevive con R1 OS 2.0 (card UI, community skills via SDK). $199, sin suscripcion | Leccion: hardware AI necesita software ecosystem fuerte |

### Veredicto competitivo (actualizado 2026-03-24)

**La categoria "AI-first OS funcional, abierto, con agente autonomo" NO TIENE GANADOR.**

- OpenClaw es la amenaza mas seria pero NO es un OS — en Linux solo corre headless
- Devin/Replit son autonomos pero solo para coding, cloud-only, sin privacidad
- Los gigantes avanzan (Apple Foundation Models, Microsoft Copilot Studio, Google Astra) pero en ecosistemas cerrados
- Los dispositivos AI dedicados fracasaron (Humane muerto, Rabbit apenas sobrevive)
- Los frameworks de agentes (CrewAI, LangGraph) son librerias, no productos de usuario final
- El mercado de AI agents crece: $14.89B en 2025, proyectado $35.74B en 2030, 72% de enterprises planean deployment en 2026

**Tu ventaja unica que nadie puede replicar facil:**
1. ERES el OS (acceso a kernel, systemd, bootc, hardware)
2. Inmutabilidad + rollback (si la AI rompe algo, bootc te salva)
3. Full sensory stack a nivel de sistema (no una app sandboxeada)
4. Open source + privacidad real (todo local por default)
5. GPU management nativo (Game Guard libera VRAM, ningun competidor hace esto)

**Lo que nos falta para el "efecto wow" (Fases H-M):**
1. Loop iterativo de desarrollo (Fase H) — OpenClaw y Devin ya lo tienen
2. Browser automation real (Fase J) — OpenClaw y Claude Computer Use ya lo tienen
3. Self-improvement (Fase K) — Solo OpenClaw lo tiene, es lo que lo hace viral
4. Plataforma de desarrollo completa (Fase M) — El differentiator final

### Analisis verificado: LifeOS vs OpenClaw macOS (2026-03-27)

Verificado contra el repo actual de LifeOS y la documentacion oficial de OpenClaw.

| Capacidad | OpenClaw macOS | LifeOS hoy | Veredicto |
|-----------|---------------|-------------|-----------|
| Wake word + voz | No nativo (no hay STT/TTS en docs) | Si (wake word "axi", VAD, TTS, voice loop completo) | **LifeOS adelante** |
| STT/TTS local | No nativo | Si (llama-server + Whisper + pipeline de voz) | **LifeOS adelante** |
| Screenshot + OCR | Solo canvas snapshot, no OCR nativo | Si (grim/scrot + Tesseract multilingue) | **LifeOS adelante** |
| Control mouse/teclado | Via Peekaboo (UI automation), no raw input | Si (ydotool/xdotool, 14 funciones, dry-run) | **Paridad** |
| Browser automation | Si (canvas navigate/eval/a2ui, DOM interaction) | Solo CLI + vision (no DOM interaction) | **OpenClaw adelante** |
| Canvas interactivo | Si (navigate, eval, snapshot, a2ui tools) | No hay equivalente | **OpenClaw adelante** |
| screen.record video | Si | Solo screenshots periodicos + meeting audio, no video continuo | **OpenClaw adelante** |
| Camara como tool | Si (snap/clip) | Presencia + vision + scene description + people counting | **Diferente pero comparable** |
| Presencia/contexto fisico | No documentado como fortaleza | Si (fatiga, postura, people counting, away-tracking) | **LifeOS muy adelante** |
| Permisos/companion app | Si (TCC nativo macOS, code signing) | Si (broker D-Bus + zenity + portal con audit log JSON) | **Paridad funcional** |
| system.run con approvals | Si | Si (risk levels, auto-approve medium, shadow mode, SLA parsing, parallel tasks) | **Paridad — supervisor robusto** |
| Menu bar / overlay | Si (companion app madura) | Tray activo (ksni), GTK4 widget real pero deshabilitado | **OpenClaw adelante en UX** |
| UI automation broker (Peekaboo) | Si (AT-SPI via UNIX socket, TCC perms) | No hay equivalente AT-SPI2 | **OpenClaw adelante** |
| Shortcuts / deep links | Si (openclaw:// protocol) | Solo 3 shortcuts hardcoded, no lifeos:// protocol | **OpenClaw adelante** |
| Notificaciones nativas | Si | Si (notify-rust + D-Bus) | **Paridad** |

**Contra OpenClaw Linux:** LifeOS va MUY por delante. OpenClaw Linux es solo gateway backend — no hay companion app, no hay Peekaboo, no hay screen recording, no hay canvas. Sus docs dicen: native Linux companion apps "planned" sin timeline.

**Resumen:** ~70% paridad funcional con OpenClaw macOS, con ventajas claras en voz, OCR, presencia y supervisor. LifeOS es la implementacion mas completa de un AI companion en Linux hoy.

#### 5 huecos a cerrar (prioridad para fases futuras)

| # | Hueco | Gravedad | Solucion propuesta | Fase sugerida |
|---|-------|----------|-------------------|---------------|
| 1 | **Canvas interactivo / DOM interaction** | Alta | Integrar Playwright o CDP para browser automation real (click, fill, navigate DOM) | Fase J (Browser Operator) |
| 2 | **UI automation broker (tipo Peekaboo)** | Alta | Implementar bridge AT-SPI2 para leer/controlar elementos UI de apps nativas | Post Fase M |
| 3 | **screen.record como tool general** | Media | Exponer pw-record + wf-recorder como tool del supervisor (ya hay audio recording en meetings) | Fase H-I |
| 4 | **Shortcuts / deep links (lifeos://)** | Media | Registrar xdg-open handler para lifeos:// protocol + desktop entry con MimeType | Fase I |
| 5 | **Companion UX madura** | Media | Re-habilitar mini_widget GTK4 (ya esta implementado, solo deshabilitado) o migrar a panel applet COSMIC | Fase I-J |

#### Deuda visual y branding pendiente (2026-03-27)

**Fuentes:** Inter y JetBrains Mono estan instaladas (Containerfile:386) pero COSMIC muestra Open Sans / Noto Sans Mono. `lifeos-apply-theme.sh` NO escribe los archivos de configuracion de fuentes de COSMIC. Falta crear:
- `~/.config/cosmic/com.system76.CosmicSettings.FontConfig/v1/font_family` → `"Inter"`
- `~/.config/cosmic/com.system76.CosmicSettings.FontConfig/v1/monospace_family` → `"JetBrains Mono"`

**Icon theme LifeOS:** Seleccionado en COSMIC pero incompleto (~16 iconos). Un theme usable necesita ~80+ iconos. Iconos faltantes criticos:

| Categoria | Iconos necesarios (nombre freedesktop) |
|-----------|---------------------------------------|
| apps | firefox, cosmic-files, cosmic-edit, cosmic-term, cosmic-settings, flatpak, steam, discord, telegram, code (VSCode), spotify, thunderbird, lifeos-dashboard, lifeos-axi |
| places | folder, folder-documents, folder-download, folder-music, folder-pictures, folder-videos, folder-home, user-home, user-trash, network-workgroup |
| mimetypes | text-plain, text-x-script, image-png, image-svg, audio-x-generic, video-x-generic, application-pdf, application-x-compressed, application-json |
| actions | document-open, document-save, edit-copy, edit-paste, edit-delete, list-add, list-remove, view-refresh, go-next, go-previous, window-close |
| categories | preferences-system, preferences-desktop, system-file-manager, utilities-terminal, applications-internet, applications-multimedia |
| status | dialog-information, dialog-warning, dialog-error, network-online, network-offline, battery-full, audio-volume-high |

**Estilo segun Brand Guide:** Flat design, sin sombras, dos tonos (base #161830 + acento #00D4AA/#FF6B9D), esquinas redondeadas, fondo transparente, SVG escalable.

#### Bugs conocidos y mejoras de UX detectadas (2026-03-27)

| # | Issue | Severidad | Causa raiz | Solucion propuesta | Fase |
|---|-------|-----------|------------|-------------------|------|
| 1 | **Tray icon de Axi tarda en aparecer tras boot** | Alta | El daemon arranca antes que el compositor COSMIC setee `WAYLAND_DISPLAY`. El check en `main.rs:782` es one-shot sin retry. La funcion `ensure_graphical_environment()` existe pero esta deshabilitada (dead code) | Habilitar `ensure_graphical_environment()` con retry loop (poll cada 2s, max 30s) o usar D-Bus signal para detectar display ready | Fase I |
| 2 | **Tray icon desaparece y reaparece** | Alta | `service.spawn()` no tiene error handling. No hay health monitoring del tray task. Si D-Bus session se reinicia o event bus cierra (`RecvError::Closed`), el tray muere sin re-spawn | Agregar health monitor: si el tray task termina, re-spawnearlo con backoff exponencial. Envolver `service.spawn()` en error handling | Fase I |
| 3 | **Iconos del dock se ven mal (PNG sin transparencia)** | Media | Los iconos actuales en la imagen son PNG rasterizados. El script `generate_brand_assets.sh` genera SVGs con transparencia pero aun no se integro al build pipeline | Integrar SVGs al Containerfile: copiar a `/usr/share/icons/LifeOS/scalable/apps/`, registrar icon theme, generar PNGs multi-resolucion con rsvg-convert | Fase I |
| 4 | **Wallpaper default no se aplica tras update** | Baja | `lifeos-apply-theme.sh` solo corre una vez por version (marker file). Si el usuario ya tiene una version aplicada, no re-aplica. El wallpaper Orion nebula es el default de COSMIC, no de LifeOS | Agregar opcion de re-aplicar theme en el dashboard. O bump el marker si hay cambios de wallpaper significativos. Wallpapers custom estan en `/usr/share/backgrounds/lifeos/` | Fase I |
| 6 | **Game Guard no puede offloadear LLM a CPU** | Alta | `/etc/lifeos/llama-server.env` es owned by root, lifeosd corre como uid 1000. `persist_gpu_layers()` falla con "failed to write". Fix en Containerfile: `chown 1000:1000`. Fix inmediato: `sudo chown lifeos:lifeos /etc/lifeos/llama-server.env` | Ya corregido en Containerfile (chown tras COPY). Para fix temporal: `sudo chown lifeos:lifeos /etc/lifeos/llama-server.env` | Inmediato |
| 7 | **Fuentes Inter/JetBrains Mono no aplicadas en COSMIC** | Media | Fonts estan instaladas pero `lifeos-apply-theme.sh` no escribe los archivos de config de COSMIC para fuentes. COSMIC muestra Open Sans y Noto Sans Mono por default | Agregar a `lifeos-apply-theme.sh`: escribir `~/.config/cosmic/com.system76.CosmicSettings.FontConfig/v1/` con `font_family=Inter` y `monospace_family=JetBrains Mono` | Fase I |
| 5 | **Script generate_brand_assets.sh apunta a directorio incorrecto** | Baja | TARGET_DIR es `/var/home/lifeos/Music/LifeOS_Brand` en vez de `image/files/usr/share/` | Refactorizar script: output a `image/files/usr/share/icons/LifeOS/scalable/apps/` y `image/files/usr/share/backgrounds/lifeos/`. Agregar paso al Makefile | Fase I |
| 8 | **Game Guard: llama-server tarda ~90s en morir** | Media | llama-server no responde a SIGTERM rapido cuando tiene modelo cargado en GPU. Systemd espera TimeoutStopSec (default 90s) antes de SIGKILL. Offload funciona pero con retraso | Agregar `TimeoutStopSec=10` al service o usar SIGKILL directamente en `restart_llama_server()`. Tambien considerar `ExecStop=/bin/kill -9 $MAINPID` en el unit | Fase I |
| 9 | **Audifonos Bluetooth: mic no se usa automaticamente** | Media | HUAWEI FreeClip se conecta en A2DP (audio alta calidad) pero el mic queda en SUSPENDED y COSMIC usa el mic interno. El usuario espera que al conectar BT headset, tanto audio como mic cambien automaticamente | Investigar wireplumber policy para auto-switch input device cuando BT headset con mic se conecta. Posible solucion: wireplumber rule o script en udev/BT connect hook | Fase I |
| 10 | **Bluetooth: 2 volumenes desincronizados (panel vs real) + blast de audio en reuniones** | Alta | Bug confirmado upstream en WirePlumber 0.5.13 (Fedora 43 actual). Ver seccion detallada abajo | Ver seccion "Analisis BT volume desync" abajo | Inmediato (workaround) + esperando WirePlumber 0.5.14 |
| 11 | **Boot/shutdown screen sin mensajes de progreso** | Media | Plymouth mostraba logo de LifeOS estatico sin indicacion de progreso ni mensajes de systemd. El usuario piensa que el sistema se trabo, especialmente durante reinicios post-actualizacion | **IMPLEMENTADO:** Plymouth theme `lifeos` con spinner animado (8 dots rotando alrededor del orb), mensajes de estado de systemd visibles al fondo de pantalla, deteccion de actualizaciones (ostree/bootc) con texto "Aplicando actualizacion...", y mensajes contextuales de shutdown ("Apagando..."/"Reiniciando...") | Fase I |

#### Analisis detallado: Bluetooth volume desync (bug #10)

**Sintoma:** COSMIC panel/OSD muestra 100% pero el volumen real del sink BT es 40%. Al entrar a Google Meet, Chrome/WebRTC setea volumen a 100% (blast de audio en audifonos), y al salir lo restaura a 40%.

**Causa raiz:** WirePlumber 0.5.13 crea "sink loopback" nodes (`bluez5.sink-loopback=true`) para soportar auto-switch entre A2DP y HSP/HFP. Esto crea 2 capas de volumen:
- Nodo loopback (lo que COSMIC lee): vol=1.0 (100%)
- Sink real BT (`bluez_output.F0:FA:C7:6E:C2:BE`): vol=0.40 (40%)

COSMIC lee el volumen del nodo equivocado. Issues upstream: `pop-os/cosmic-epoch#3094`, `pop-os/cosmic-panel#566`.

**Fix definitivo:** WirePlumber 0.5.14 elimino el sink-loopback por completo (MR !794). Fedora 43 aun no lo tiene. Monitorear: `dnf info wireplumber --available`.

**Workarounds inmediatos para aplicar en image/Containerfile o lifeos-apply-theme.sh:**

**Fix A — Deshabilitar BT autoswitch (recomendado):**
```
# ~/.config/wireplumber/wireplumber.conf.d/11-bluetooth-policy.conf
wireplumber.settings = {
  bluetooth.autoswitch-to-headset-profile = false
}
```
Trade-off: no cambia auto a HSP/HFP al usar mic. Hay que cambiar perfil manualmente.

**Fix B — Bloquear que Chrome ajuste volumen del sistema:**
```
# chrome://flags/#enable-webrtc-allow-input-volume-adjustment → Disabled
```

**Fix C — Deshabilitar hardware volume para FreeClip:**
```
# ~/.config/wireplumber/wireplumber.conf.d/80-bluez-properties.conf
monitor.bluez.rules = [
  {
    matches = [{ device.name = "~bluez_card.F0_FA_C7_6E_C2_BE" }]
    actions = { update-props = { bluez5.hw-volume = [] } }
  }
]
```

**Accion para LifeOS:** Instalar Fix A como default del sistema en `/etc/wireplumber/wireplumber.conf.d/11-bluetooth-policy.conf` via Containerfile. Cuando WirePlumber 0.5.14 llegue a Fedora, remover el workaround.

#### Analisis detallado: Telegram bot incoherente (2026-03-27)

**Sintoma:** Axi por Telegram da respuestas genericas ("Que necesitas hoy?"), ignora imagenes enviadas, y muestra tags de modelos diferentes ([cerebras-qwen235b] vs [local]) sin coherencia.

**Problemas encontrados (codigo verificado en telegram_bridge.rs, telegram_tools.rs, llm_router.rs):**

| # | Problema | Donde | Impacto |
|---|---------|-------|---------|
| 1 | **Imagenes enviadas a modelos sin vision** | `llm_router.rs:304-315` — Vision scoring filtra providers sin vision (score=0), pero el fallback cascade los permite. Cuando local no esta o Gemini key falta, cae a cerebras-qwen235b que NO soporta vision. La imagen se envia pero se ignora silenciosamente | Critico: el usuario manda foto + "que ves?" y recibe saludo generico |
| 2 | **System prompt generico sin personalidad Axi** | `telegram_tools.rs:39-178` — SYSTEM_PROMPT dice "Responde en espanol de forma natural" pero NO menciona ser Axi, NO tiene personalidad, NO tiene contexto de LifeOS, NO tiene instrucciones de fallback | Alto: las respuestas se sienten como un chatbot generico, no como el asistente AI personal de LifeOS |
| 3 | **Fallback silencioso cuando vision no disponible** | `telegram_tools.rs:882-940` — Si ningún provider de vision esta disponible, el bot envia la imagen a un modelo de texto que la ignora. No avisa al usuario "no puedo ver imagenes ahora" | Alto: el usuario cree que Axi "vio" la imagen pero la ignoro |
| 4 | **Tags de modelo visibles al usuario** | `telegram_bridge.rs` — La respuesta incluye `[cerebras-qwen235b]` o `[local]` como suffix. El usuario no deberia ver internals del routing | Bajo: cosmético pero rompe la ilusion de un asistente unificado |
| 5 | **Modelo local (Qwen3.5-2B) es demasiado pequeno para conversacion rica** | El modelo local es Qwen3.5-2B Q4_K_M — suficiente para tareas simples pero NO para conversacion contextual rica como OpenClaw (que usa modelos 70B+ via cloud) | Medio: las respuestas locales seran siempre limitadas vs cloud |

**Flujo actual vs flujo correcto:**

```
ACTUAL (roto):
  User: [foto] "Que ves aqui?"
  → detect Vision complexity
  → local down? → fallback cerebras (no vision)
  → cerebras ignora imagen, procesa solo texto
  → responde: "Hola! Que necesitas?" [cerebras-qwen235b]

CORRECTO (objetivo):
  User: [foto] "Que ves aqui?"
  → detect Vision complexity
  → filtrar SOLO providers con vision (local, gemini-flash, anthropic-haiku)
  → si NINGUNO disponible: responder "No puedo analizar imagenes ahora, ¿me lo describes?"
  → si disponible: enviar multimodal, obtener descripcion de la imagen
  → responder con personalidad Axi: "Veo tu pantalla de bloqueo de LifeOS..."
```

**Fixes necesarios (prioridad para Fase H):**

1. **Strict vision filtering**: Si `TaskComplexity::Vision`, NUNCA caer a provider sin vision. Si no hay provider de vision, responder con mensaje claro al usuario
2. **System prompt con personalidad Axi**: Incluir nombre, personalidad (amigable, inteligente, protector), contexto LifeOS, idioma espanol, instrucciones de fallback
3. **Ocultar tags de modelo**: No mostrar `[provider]` al usuario. Si se quiere debug, enviarlo como mensaje separado o en logs
4. **Configurar Gemini API key como vision fallback gratis**: Es gratis y soporta vision. Asi cuando local no esta (ej: Game Guard lo offloadeo), hay fallback de vision real
5. **Mejorar system prompt con contexto del sistema**: Incluir hora, modo actual, estado de sensores, ultima actividad — para que Axi responda con contexto real

---

## Analisis Competitivo Actualizado (Marzo 2026)

**OpenClaw vs LifeOS — donde estamos y que nos falta:**

| Capacidad | OpenClaw | LifeOS | Gap |
|-----------|----------|--------|-----|
| Messaging channels | 21+ (WhatsApp, Telegram, Slack, Discord, Signal, iMessage, Teams, Matrix, IRC, LINE, Twitch, Nostr...) | 4 (Telegram, WhatsApp, Matrix, Signal) | **Medio** — tenemos los principales, faltan Slack/Discord/iMessage |
| Skills ecosystem | 13,729+ community skills en ClawHub | Skill generator + auto-learning (Fase K implementada) | **Medio** — sistema funcional, falta contenido |
| Browser automation | Headless browser completo, OAuth, forms, scraping | Canvas CDP WebSocket: sesion persistente, DOM nativo, a2ui, cookies, multi-tab, JS eval en pagina real (Fase J) | **Paridad** — CDP WebSocket completo con interaccion DOM nativa |
| Self-improvement | Escribe sus propios skills, edita prompts, hot-reload | Skill generation + lookup before planning (Fase K) | **Paridad basica** — genera skills, hot-reload |
| Voice | Wake word macOS/iOS, push-to-talk, ElevenLabs | Wake word rustpotter + Whisper STT + Piper TTS | **Paridad** — funcional |
| Desktop integration | Solo macOS menu bar. Linux = headless gateway | COSMIC overlay + widget + systemd nativo | **VENTAJA LifeOS** |
| Privacy | Local-first, BYOK | Local-first, BYOK, privacy filter, sensitivity routing | **VENTAJA LifeOS** |
| OS-level access | App dentro de OS | **ES** el OS (kernel, systemd, bootc, hardware) | **VENTAJA UNICA LifeOS** |
| Immutability/rollback | No | bootc atomic updates + rollback | **VENTAJA UNICA LifeOS** |
| Cron/scheduling | Si, robusto | Si, SQLite + supervisor | **Paridad** |
| Computer use | No nativo | ydotool/xdotool mouse/keyboard | **VENTAJA LifeOS** |
| Phone calls | Si (ElevenLabs voice synthesis) | No | **Gap** — baja prioridad |
| IoT/Smart home | Si (luces, purificadores) | Si (Home Assistant API) | **Paridad** |
| Iterative coding loop | Via skills autoescribidos | Supervisor con retry (max_attempts=3) + skill lookup (Fase H) | **Paridad** — funcional |
| Git workflow automatico | Limitado | Auto-approve medium-risk + shell git (Fase I) | **Paridad basica** — git push auto-aprobado |
| Meeting recording | No | Auto-detect + pw-record + Whisper transcribe (Fase R) | **VENTAJA LifeOS** |
| Desktop automation | No nativo en Linux | Desktop operator + autonomous agent (Fases N, O) | **VENTAJA LifeOS** |
| MCP protocol | No | 7 tools + JSON-RPC 2.0 transport (Fase Q) | **VENTAJA LifeOS** |
| Health monitoring | No | 12 checks: CPU/GPU/SSD/battery/disk/net/SELinux (Fase S) | **VENTAJA UNICA LifeOS** |
| Gaming agent | No | Frame capture + input + Game Guard VRAM offload (Fase P) | **VENTAJA UNICA LifeOS** |

### Ventajas de LifeOS sobre OpenClaw (17 capacidades unicas)

| Capacidad | Detalle |
|-----------|---------|
| **ES el OS** | Acceso a kernel, systemd, bootc, hardware — irreplicable |
| **Immutabilidad + rollback** | bootc atomic updates, 3 canales |
| **GPU Game Guard** | Auto-offload LLM a CPU cuando detecta juego |
| **Meeting assistant** | Auto-detect triple, transcripcion, diarization, resumen |
| **Health monitoring** | 12 checks (CPU/GPU/SSD/battery/ergonomia/audio/privacy) |
| **Security AI daemon** | 4 detectores, auto-isolation, forensic reports |
| **Voz local completa** | Wake word + Whisper + Piper + TTS emocional + conversacion continua |
| **Computer use real** | ydotool/xdotool, 14 funciones, vision-guided |
| **Desktop automation** | Visual grounding, action loop, workspace aislado, kill switch |
| **Gaming agent** | Game state analysis, sugerencias, virtual gamepad uinput |
| **Knowledge graph local** | Entity graph, 5 ingestores, temporal reasoning, privacy layers |
| **Battery manager** | sysfs + UPower, charge thresholds, NVIDIA RTD3 |
| **Privacy filter** | 4 niveles sensibilidad, routing por proveedor, audit |
| **Translation engine** | Argos + LLM, subtitulos, voice interpreter |
| **MCP (estandar industria)** | 9 tools, client Y server — OpenClaw usa protocolo propietario |
| **OCR local** | Tesseract multilingue sin API |
| **Presencia/biometricas** | Fatiga, postura, breaks, hidratacion, vista 20-20-20 |

### Gaps criticos a cerrar (de OpenClaw)

| Gap | Severidad | En OpenClaw | En LifeOS | Fase |
|-----|-----------|-------------|-----------|------|
| Gateway WS control plane | ALTO | WS tipado, roles/scopes, event bus con seq | REST-only, polling | AB |
| Session durability + compaction | ALTO | Transcripts JSONL, compaction, tool truncation | Ad-hoc en memoria | AB |
| Deterministic channel routing | MEDIO | 8 niveles prioridad, session keys | Per-bridge hardcoded | AB.3 |
| Plugin SDK + boundaries | MEDIO | SDK publico, baseline CI, contract tests | Skills sin SDK formal | AC |
| Config migration + doctor | MEDIO | Audit trail, lastKnownGood, doctor incremental | Basico | AB.4 |
| Architecture guardrails | MEDIO | 6+ scripts custom en CI | Solo fmt+clippy | AD |

### Diferenciacion unica vs competidores (Vision Mundial)

| Competidor | Modelo | Debilidad |
|-----------|--------|-----------|
| Apple Intelligence | Cloud + cerrado + $$$ | No puedes ver/controlar que hace con tus datos |
| Microsoft Copilot | Telemetria + suscripcion | Forza AI en el OS sin consentimiento |
| Google Astra | Cloud + data harvesting | Todo pasa por servidores de Google |
| OpenClaw | App dentro de OS | No ES el OS — no tiene acceso kernel/hardware |
| Devin | Cloud sandbox | No corre en tu hardware, pagas suscripcion |
| **LifeOS** | **ES el OS + local + privado + immutable + gratis** | **Necesita reliability y polish** |
