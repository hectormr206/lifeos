# Fase AY: OS Control Plane (Jerarquia de 4 Capas)

> Estado: CONSECUTIVA (implementable sin investigacion profunda)
> Depende de: Fase Q (MCP base), Fase N (desktop operator)
> Investigacion base: [docs/research/cross-platform-controller/README.md](../research/cross-platform-controller/README.md)
> Fecha: 2026-03-31

## Objetivo

Convertir a LifeOS en un control plane estructurado del sistema operativo, exponiendo
20+ tools MCP para ventanas, apps, clipboard, sistema y archivos. Implementar una
politica de seleccion de capa que priorice MCP > adapter nativo > accesibilidad > vision,
evitando depender de computer use visual para acciones que tienen APIs estructuradas.

## Principio Rector

No apostar todo a screenshots + clicks. La arquitectura correcta es:

1. **MCP** cuando exista tool especifica
2. **Adapter nativo** cuando haya API del sistema (D-Bus, swaymsg, wpctl)
3. **Accesibilidad** cuando haya arbol AT-SPI2 usable
4. **Vision + input** solo como fallback universal

Esto da resultados mas rapidos, baratos, deterministas y auditables que vision pura.

---

## Contexto de la Investigacion Web (2026-03-31)

### MCP para control de OS — estado del ecosistema

- **Windows-MCP** (github.com/CursorTouch/Windows-MCP): MCP server open-source que permite
  a agentes AI controlar Windows (archivos, apps, UI). Valida que la idea de "OS como MCP
  server" ya tiene traccion.
- **Desktop Commander** (desktopcommander.app): MCP server local-first para filesystem,
  terminal, ventanas. Funciona con Claude Desktop.
- **Microsoft** adopto MCP oficialmente para Windows AI (learn.microsoft.com/windows/ai/mcp).
- **Red Hat** lanzo un MCP server para RHEL (developer preview) con analisis de logs,
  monitoreo de rendimiento y deteccion de anomalias via SSH.
- **MCP fue donado a la Linux Foundation** (Agentic AI Foundation) en diciembre 2025,
  convirtiendolo en estandar vendor-neutral.

### D-Bus como MCP bridge — ya existe

- **mcp-dbus** (github.com/repr0bated/dbus-mcp): descubrimiento automatico de servicios
  D-Bus, expone 100+ tools sin configuracion. Prueba de concepto de que D-Bus -> MCP
  es viable.
- **subpop/mcp_dbus** (lobehub.com/mcp/subpop-mcp_dbus): otro MCP server D-Bus que permite
  a AI assistants llamar metodos de systemd, NetworkManager, UPower, etc.
- LifeOS puede adoptar este patron: exponer servicios D-Bus criticos como MCP tools.

### AT-SPI2 en Rust — maduro

- **atspi crate** (github.com/odilia-app/atspi): implementacion pura Rust del protocolo
  AT-SPI2 usando zbus. Asincronico, bien mantenido (proyecto Odilia).
- **AccessKit** (github.com/AccessKit/accesskit): infraestructura de accesibilidad para
  UI toolkits en Rust. Su adaptador Unix implementa interfaces D-Bus de AT-SPI via zbus.
- Odilia es el unico screen reader que conecta directamente a dbus-daemon sin pasar por
  pyatspi2/libatspi. Modelo ideal para LifeOS.

### Wayland/COSMIC automation — herramientas disponibles

- **swaymsg**: controla compositor Sway (ventanas, workspaces, outputs). COSMIC usa
  cosmic-comp (basado en Smithay), no Sway, pero expone protocolo similar.
- **cosmic-randr**: preinstalado en COSMIC, controla outputs desde terminal.
- **wlrctl**: control de ventanas/teclado en compositors wlroots.
- **ydotool**: automatizacion generica para Wayland (equivalente a xdotool).
- **wtype**: input de teclado en Wayland.
- **grim + slurp**: captura de pantalla en Wayland.
- **wl-clipboard** (wl-copy/wl-paste): clipboard en Wayland.
- COSMIC expone muchas capacidades via D-Bus (cosmic-settings-daemon).

### XDG Desktop Portals — acceso sandboxed

- Portales D-Bus estandar para acciones del sistema: screenshots, screencasts, file
  chooser, open URI, notifications, background, USB, dynamic launchers.
- Funcionan tanto para apps sandboxed (Flatpak) como no-sandboxed.
- LifeOS puede usar portales como adapter layer uniforme en vez de llamar herramientas
  CLI directamente — mas portable entre compositors.

### Vision-based vs structured APIs — consenso

- Computer Use (Anthropic) es beta: screenshots + mouse + teclado. Util como fallback
  universal pero lento, costoso en tokens, y fragil ante cambios de UI.
- El consenso en la industria (Windows-MCP, RHEL MCP, Desktop Commander) es que APIs
  estructuradas son preferibles cuando existen. Vision es el seguro, no el plan A.

---

## Sub-fases

### AY.1 — MCP OS Control Plane (PRIORIDAD ALTA, 2-3 semanas)

Expandir `daemon/src/mcp_server.rs` con tools de control del sistema operativo.
Cada tool se implementa invocando herramientas CLI que ya existen en COSMIC/Wayland.

#### Window Management

| Tool | Descripcion | Implementacion |
|------|-------------|----------------|
| `lifeos.windows.list` | Listar ventanas abiertas | `swaymsg -t get_tree` o cosmic-comp IPC |
| `lifeos.windows.focus` | Enfocar ventana por id/titulo | `swaymsg '[con_id=X] focus'` |
| `lifeos.windows.move` | Mover ventana a workspace/posicion | `swaymsg '[con_id=X] move to workspace N'` |
| `lifeos.windows.resize` | Redimensionar ventana | `swaymsg '[con_id=X] resize set W H'` |
| `lifeos.windows.close` | Cerrar ventana | `swaymsg '[con_id=X] kill'` |

**Nota COSMIC:** cosmic-comp no es Sway. Verificar si expone IPC compatible o si necesitamos
usar D-Bus de cosmic-settings-daemon. Posible fallback: ydotool + wlrctl.

#### App Management

| Tool | Descripcion | Implementacion |
|------|-------------|----------------|
| `lifeos.apps.launch` | Lanzar app por nombre .desktop | `gtk-launch <name>` o `xdg-open` |
| `lifeos.apps.list` | Listar apps instaladas | Parsear `/usr/share/applications/*.desktop` |
| `lifeos.apps.running` | Listar procesos activos | `/proc` o `ps aux` filtrado |

#### Clipboard

| Tool | Descripcion | Implementacion |
|------|-------------|----------------|
| `lifeos.clipboard.get` | Leer clipboard | `wl-paste` |
| `lifeos.clipboard.set` | Escribir clipboard | `wl-copy` |

#### Notifications

| Tool | Descripcion | Implementacion |
|------|-------------|----------------|
| `lifeos.notify.send` | Enviar notificacion | `notify-rust` crate (ya en daemon) |
| `lifeos.notify.list` | Listar notificaciones recientes | D-Bus `org.freedesktop.Notifications` |

#### System

| Tool | Descripcion | Implementacion |
|------|-------------|----------------|
| `lifeos.system.info` | CPU, RAM, disco, GPU | `sysinfo` crate (ya en daemon) |
| `lifeos.system.screenshot` | Capturar pantalla | `grim` (Wayland) |
| `lifeos.system.volume` | Get/set volumen | `wpctl get-volume @DEFAULT_AUDIO_SINK@` |
| `lifeos.system.brightness` | Get/set brillo | `brightnessctl` o D-Bus |

#### Files

| Tool | Descripcion | Implementacion |
|------|-------------|----------------|
| `lifeos.files.read` | Leer contenido de archivo | `std::fs::read_to_string` (con sandbox) |
| `lifeos.files.write` | Escribir archivo | `std::fs::write` (con sandbox, solo /home, /var) |
| `lifeos.files.search` | Buscar archivos por patron | `fd` o `glob` recursivo |
| `lifeos.files.open` | Abrir con app por defecto | `xdg-open` |

#### Reutilizacion del codigo existente

Muchas de estas acciones ya existen en `telegram_tools.rs` (screenshot, run_command,
browser_navigate, etc.) y en `computer_use.rs`. El trabajo es:

1. Extraer la logica a modulos compartidos (`os_tools/`)
2. Exponer via MCP en `mcp_server.rs`
3. Mantener Telegram tools como wrapper de las mismas funciones

#### Checklist AY.1

- [ ] Crear modulo `daemon/src/os_tools/mod.rs` con submodulos: windows, apps, clipboard, notify, system, files
- [ ] Implementar cada tool como funcion async que retorna `Result<serde_json::Value>`
- [ ] Registrar tools en `mcp_server.rs::list_tools()`
- [ ] Implementar dispatch en handler de `tools/call` del MCP server
- [ ] Agregar sandbox: files solo en `/home/lifeos`, `/var/lib/lifeos`, `/tmp`
- [ ] Agregar rate limiting basico (max 10 calls/sec por tool)
- [ ] Tests unitarios para cada tool (mock de comandos)
- [ ] Refactorizar `telegram_tools.rs` para usar `os_tools` compartido
- [ ] Documentar tools en formato MCP (JSON Schema por tool)

---

### AY.2 — Layer Selection Policy (1 semana)

Codificar la politica de seleccion de capa en el agent runtime.

```rust
// daemon/src/control_layer.rs

/// Las 4 capas de control, ordenadas por preferencia.
pub enum ControlLayer {
    /// Capa 1: Tool MCP estructurada (determinista, rapida, barata)
    Mcp,
    /// Capa 2: Adapter nativo del sistema (D-Bus, swaymsg, wpctl, CLI)
    NativeAdapter,
    /// Capa 3: Accesibilidad (AT-SPI2 en Linux, UIAutomation en Windows)
    Accessibility,
    /// Capa 4: Vision + input (screenshot + OCR + mouse/teclado) — fallback
    VisionInput,
}

/// Determina la mejor capa para ejecutar una accion.
///
/// Politica:
/// 1. Si existe MCP tool registrada para esta accion -> Mcp
/// 2. Si existe adapter nativo confiable -> NativeAdapter
/// 3. Si la app expone arbol de accesibilidad -> Accessibility
/// 4. Fallback universal -> VisionInput
pub fn select_layer(action: &str, target_app: &str, registry: &ToolRegistry) -> ControlLayer {
    if registry.has_mcp_tool(action) {
        return ControlLayer::Mcp;
    }
    if registry.has_native_adapter(action, target_app) {
        return ControlLayer::NativeAdapter;
    }
    if registry.has_accessibility_support(target_app) {
        return ControlLayer::Accessibility;
    }
    ControlLayer::VisionInput
}
```

#### Checklist AY.2

- [ ] Crear `daemon/src/control_layer.rs` con enum + select_layer
- [ ] Crear `ToolRegistry` que mantiene mapa de tools MCP registradas
- [ ] Agregar deteccion de adapters nativos (D-Bus introspection)
- [ ] Agregar deteccion de soporte AT-SPI2 por app (check si tiene arbol)
- [ ] Integrar select_layer en el agent loop (antes de ejecutar accion)
- [ ] Log de que capa se eligio y por que (para auditoria)
- [ ] Wire a `/api/v1/control-layer` endpoint para consultar politica

---

### AY.3 — Browser Bridge: CDP a MCP (1-2 semanas)

Exponer el `cdp_client.rs` existente como MCP tools para automatizacion web.

| Tool | Descripcion | Implementacion |
|------|-------------|----------------|
| `lifeos.browser.navigate` | Abrir URL | CDP `Page.navigate` |
| `lifeos.browser.screenshot` | Captura de pagina | CDP `Page.captureScreenshot` |
| `lifeos.browser.extract_text` | Texto de la pagina | CDP `Runtime.evaluate` + `document.body.innerText` |
| `lifeos.browser.click` | Click en elemento CSS | CDP `Runtime.evaluate` + `querySelector().click()` |
| `lifeos.browser.fill` | Llenar campo de formulario | CDP `Runtime.evaluate` + set value |
| `lifeos.browser.tabs` | Listar tabs abiertos | CDP `Target.getTargets` |
| `lifeos.browser.close_tab` | Cerrar tab | CDP `Target.closeTarget` |

#### Checklist AY.3

- [ ] Verificar que `cdp_client.rs` soporta todas las operaciones necesarias
- [ ] Crear `daemon/src/os_tools/browser.rs` como wrapper MCP de CDP
- [ ] Registrar browser tools en `mcp_server.rs`
- [ ] Agregar timeout por operacion (default 10s)
- [ ] Agregar deteccion automatica de browser (Firefox con remote debugging)
- [ ] Manejar caso donde no hay browser corriendo (error descriptivo)
- [ ] Test: navigate + screenshot + extract_text end-to-end

---

### AY.4 — Accessibility Layer: AT-SPI2 (2-3 semanas, investigacion + implementacion)

Usar la crate `atspi` (de Odilia) para leer y manipular el arbol de accesibilidad.

#### Viabilidad en COSMIC Desktop

Hallazgos de la investigacion web:

- **atspi crate** (puro Rust, async, via zbus) es la mejor opcion. Mantiene Odilia project.
- **AccessKit** provee bridge Rust <-> AT-SPI2 para toolkits (egui, Bevy, etc.).
- COSMIC usa libcosmic (basado en iced), que tiene soporte de accesibilidad en progreso.
  Verificar si apps COSMIC exponen arbol AT-SPI2 usable.
- GTK4/libadwaita apps (Firefox, GNOME apps en Flatpak) SI exponen AT-SPI2 completo.

#### Capacidades objetivo

```rust
// daemon/src/os_tools/accessibility.rs

/// Leer el arbol de accesibilidad de una app.
pub async fn get_accessibility_tree(app_pid: u32) -> Result<AccessibilityNode>;

/// Buscar un elemento por rol y nombre.
pub async fn find_element(app_pid: u32, role: &str, name: &str) -> Result<AccessibilityNode>;

/// Activar (click) un elemento de accesibilidad.
pub async fn activate_element(node: &AccessibilityNode) -> Result<()>;

/// Leer el texto de un elemento.
pub async fn get_text(node: &AccessibilityNode) -> Result<String>;

/// Escribir texto en un campo de entrada.
pub async fn set_text(node: &AccessibilityNode, text: &str) -> Result<()>;
```

#### Checklist AY.4 ✅ COMPLETADO

- [x] Agregar `atspi = "0.22"` y `zbus` a `daemon/Cargo.toml` — behind `dbus` feature
- [x] Crear `daemon/src/atspi_layer.rs` — iterative BFS tree builder, no recursive async
- [x] Implementar lectura basica del arbol (`get_tree()` — listar nodos con rol y nombre)
- [x] Implementar busqueda de elementos por rol/nombre (`find_elements()`)
- [x] Implementar activacion (`activate_element()` via DoDefaultAction) y `set_text()` / `get_text()`
- [ ] Probar con Firefox (GTK4, buen soporte AT-SPI2) — requiere hardware
- [ ] Probar con apps COSMIC nativas (verificar calidad del arbol) — requiere hardware
- [ ] Documentar que apps funcionan bien y cuales tienen arbol pobre — requiere hardware
- [x] Registrar como MCP tools: `lifeos_a11y_tree`, `lifeos_a11y_find`, `lifeos_a11y_activate`, `lifeos_a11y_get_text`, `lifeos_a11y_set_text`, `lifeos_a11y_apps` (6 tools)
- [x] Manejar gracefully cuando AT-SPI2 no esta disponible — `is_available()` check + stub module

---

### AY.5 — Vision Fallback (documentar como Capa 4, 3 dias)

Los modulos existentes ya forman esta capa:

| Modulo | Archivo | Funcion |
|--------|---------|---------|
| Computer Use | `daemon/src/computer_use.rs` | Mouse, teclado, scroll, drag |
| Screen Capture | `daemon/src/screen_capture.rs` | Screenshots via grim |
| Sensory Pipeline | `daemon/src/sensory_pipeline.rs` | OCR, deteccion de estado visual |
| Browser Automation | `daemon/src/browser_automation.rs` | CDP como complemento visual |

#### Checklist AY.5 ✅ COMPLETADO

- [x] Documentar estos modulos como "Layer 4: Vision Fallback" — documentado en esta seccion
- [x] `select_layer()` devuelve `VisionInput` como fallback por defecto
- [ ] Agregar metricas: cuantas veces se usa cada capa (para optimizar) — futuro
- [x] Agregar `warn!()` cuando se usa vision para algo que deberia tener MCP tool
- [ ] Crear issue/TODO automatico cuando vision se usa repetidamente — futuro

---

## Arquitectura Final

```text
+----------------------------------+
|          Agent Runtime           |
|    (recibe intent del usuario)   |
+----------------+-----------------+
                 |
                 v
+----------------+-----------------+
|       select_layer(action)       |
|   Politica: MCP > Adapter >     |
|   Accessibility > Vision         |
+--+--------+--------+--------+---+
   |        |        |        |
   v        v        v        v
+------+ +------+ +------+ +------+
| MCP  | |Native| |AT-SPI| |Vision|
|Tools | |Adapt.| |  2   | |+Input|
+------+ +------+ +------+ +------+
   |        |        |        |
   v        v        v        v
 swaymsg  D-Bus    atspi   grim+
 wl-copy  wpctl    crate   ydotool
 grim     gtk-     zbus    OCR
 wpctl    launch
```

## XDG Desktop Portals como Adapter Uniforme

En vez de llamar herramientas CLI directamente, LifeOS puede usar portales D-Bus
estandar para varias operaciones. Esto es mas portable entre compositors (COSMIC, Sway,
GNOME) y respeta el modelo de permisos del sandbox.

| Portal | Operacion | Equivale a |
|--------|-----------|------------|
| `org.freedesktop.portal.Screenshot` | Captura de pantalla | `grim` |
| `org.freedesktop.portal.ScreenCast` | Grabacion/streaming | `wf-recorder` |
| `org.freedesktop.portal.OpenURI` | Abrir URL/archivo | `xdg-open` |
| `org.freedesktop.portal.FileChooser` | Seleccionar archivo | dialog nativo |
| `org.freedesktop.portal.Notification` | Enviar notificacion | `notify-send` |
| `org.freedesktop.portal.Background` | Permiso de background | — |
| `org.freedesktop.portal.DynamicLauncher` | Crear .desktop | — |

Recomendacion: usar portales como implementacion preferida de los MCP tools cuando
el portal exista, con fallback a CLI directa.

## D-Bus como Fuente de Adapters

Siguiendo el patron de `mcp-dbus`, LifeOS puede hacer introspection automatica de
servicios D-Bus disponibles y generar MCP tools dinamicamente. Servicios prioritarios:

| Servicio D-Bus | Capacidades |
|---------------|-------------|
| `org.freedesktop.systemd1` | Listar/iniciar/parar servicios |
| `org.freedesktop.NetworkManager` | Estado de red, WiFi, VPN |
| `org.freedesktop.UPower` | Bateria, estado de energia |
| `org.freedesktop.login1` | Sesion, suspend, reboot |
| `org.freedesktop.hostname1` | Nombre del host, OS info |
| `com.system76.CosmicSettings` | Configuracion COSMIC (tema, wallpaper, etc.) |

---

## Dependencias

| Fase | Relacion |
|------|----------|
| Q (MCP base) | AY expande el MCP server que Q establecio |
| N (desktop operator) | AY formaliza tools que N usa de forma ad-hoc |
| AW (cross-platform) | AY define el control plane Linux; AW lo extiende a otros OS |
| AX (auditoria) | Verificar que tools MCP existentes realmente funcionan en host |

## Linea futura desacoplada: OpenCode bridge

**Estado:** FUTURO / NO CONSECUTIVO / NO BLOQUEANTE

No conviene meter un bridge de OpenCode en la secuencia inmediata de AY.
Debe tratarse como una linea futura desacoplada, retomable cuando el control
plane principal del OS ya este mas maduro y validado.

**Razon:**

- OpenCode ya expone superficies programables propias (`opencode serve`,
  OpenAPI, SDK y endpoints `/tui`)
- no vimos evidencia oficial de que OpenCode se exponga hoy como MCP server
  nativo para manipularse a si mismo
- por eso, si algun dia se hace, la implementacion correcta seria un
  **adapter/bridge** encima de su API oficial, no una fase consecutiva del
  control plane del OS

**Enfoque recomendado cuando se retome:**

1. usar `opencode serve` o el SDK oficial como superficie primaria
2. exponer sesiones, prompts, comandos, abort, mensajes y diffs como tools
   estructuradas
3. evitar vision/input para controlar OpenCode salvo como ultimo fallback

**Herramientas candidatas si algun dia se hace:**

- `opencode.session.create`
- `opencode.session.prompt`
- `opencode.session.messages`
- `opencode.session.command`
- `opencode.session.abort`
- `opencode.session.diff`

**Regla de roadmap:**

Esta linea no debe mover la prioridad de AY, no debe convertirse en la
siguiente fase por default, y no bloquea el control plane del OS ni el camino
critico de LifeOS.

## Metricas de Exito

- [ ] 20+ MCP tools registradas y funcionales en `mcp_server.rs`
- [ ] `select_layer()` decide correctamente en 90%+ de los casos
- [ ] Browser tools funcionan end-to-end (navigate + screenshot + extract)
- [ ] AT-SPI2 lee arbol de al menos Firefox y 1 app GTK4
- [ ] Vision fallback se usa en <20% de acciones (la mayoria resueltas por MCP/adapter)
- [ ] Telegram tools refactorizados para usar `os_tools` compartido

## Estimacion Total

| Sub-fase | Tiempo estimado |
|----------|----------------|
| AY.1 MCP OS tools | 2-3 semanas |
| AY.2 Layer selection | 1 semana |
| AY.3 Browser bridge | 1-2 semanas |
| AY.4 AT-SPI2 | 2-3 semanas |
| AY.5 Vision docs | 3 dias |
| **Total** | **7-10 semanas** |

## Fuentes de la Investigacion

- Windows-MCP: https://github.com/CursorTouch/Windows-MCP
- Microsoft MCP on Windows: https://learn.microsoft.com/en-us/windows/ai/mcp/overview
- Desktop Commander: https://desktopcommander.app/blog/best-mcp-servers/
- RHEL MCP Server: https://www.redhat.com/en/blog/smarter-troubleshooting-new-mcp-server-red-hat-enterprise-linux-now-developer-preview
- MCP at Linux Foundation: https://workos.com/blog/everything-your-team-needs-to-know-about-mcp-in-2026
- D-Bus MCP (repr0bated): https://github.com/repr0bated/dbus-mcp
- D-Bus MCP (subpop): https://lobehub.com/mcp/subpop-mcp_dbus
- Odilia atspi crate: https://github.com/odilia-app/atspi
- AccessKit: https://github.com/AccessKit/accesskit
- AT-SPI2 architecture: https://gnome.pages.gitlab.gnome.org/at-spi2-core/devel-docs/architecture.html
- COSMIC randr: https://github.com/pop-os/cosmic-randr
- Sway wiki: https://wiki.archlinux.org/title/Sway
- XDG Desktop Portal: https://flatpak.github.io/xdg-desktop-portal/
- XDG Portal API Reference: https://flatpak.github.io/xdg-desktop-portal/docs/api-reference.html
- Portals for unsandboxed apps: https://blogs.gnome.org/ignapk/2025/06/04/using-portals-with-unsandboxed-apps/
- Computer Use Tool (Anthropic): https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool

---

## AY.6 — MCP para Aplicaciones (LibreOffice, Firefox, COSMIC Apps)

**Objetivo:** No solo controlar el OS, sino controlar las APLICACIONES dentro del OS de forma estructurada.

### LibreOffice (via UNO bridge)

Ya existe `lifeos-libreoffice-verify.py` con 5 comandos. Exponerlos como MCP tools:

- [x] `lifeos_calc_read_cells` — leer celdas de un .ods/.xlsx
- [x] `lifeos_calc_verify_formula` — verificar formula en celda
- [x] `lifeos_calc_sheet_info` — info de hojas
- [x] `lifeos_writer_export_pdf` — exportar documento a PDF
- [ ] `lifeos_writer_insert_text` — insertar texto en documento abierto
- [ ] `lifeos_writer_replace_text` — buscar y reemplazar
- [ ] `lifeos_impress_export_pdf` — exportar presentacion a PDF
- [ ] `lifeos_impress_slide_count` — contar slides

### Firefox (via CDP y extension futura)

- [x] `lifeos_browser_navigate` — abrir URL (ya implementado AY.3)
- [x] `lifeos_browser_screenshot` — capturar pagina
- [x] `lifeos_browser_click` — click por selector CSS
- [x] `lifeos_browser_fill` — llenar campo de formulario
- [x] `lifeos_browser_extract_text` — extraer texto de pagina
- [ ] `lifeos_browser_tabs_list` — listar pestanas abiertas
- [ ] `lifeos_browser_tab_close` — cerrar pestana
- [ ] `lifeos_browser_bookmarks` — listar/agregar bookmarks
- [ ] `lifeos_browser_history` — historial reciente

### COSMIC Apps (via CLI y D-Bus)

- [x] `lifeos_cosmic_terminal` — abrir terminal (con comando opcional)
- [x] `lifeos_cosmic_files` — abrir explorador de archivos (con ruta opcional)
- [x] `lifeos_cosmic_editor` — abrir editor de texto (con archivo opcional)
- [x] `lifeos_cosmic_settings` — abrir configuracion (con pagina opcional)
- [x] `lifeos_cosmic_store` — abrir tienda de apps
- [ ] `lifeos_cosmic_screenshot_tool` — abrir herramienta de captura
- [ ] `lifeos_cosmic_calculator` — abrir calculadora

## AY.7 — MCP para COSMIC Desktop Control

**Objetivo:** Controlar la experiencia del escritorio COSMIC de forma programatica.

### Workspaces

- [x] `lifeos_workspaces_list` — listar workspaces con info (focused, windows)
- [x] `lifeos_workspaces_switch` — cambiar a workspace N o por nombre
- [x] `lifeos_workspaces_create` — crear workspace nuevo
- [x] `lifeos_workspaces_move_window_to` — mover ventana activa a workspace N

### Tema y Apariencia

- [x] `lifeos_cosmic_dark_mode` — activar/desactivar modo oscuro
- [x] `lifeos_cosmic_dock_autohide` — activar/desactivar auto-hide del dock
- [x] `lifeos_cosmic_panel_position` — cambiar posicion del panel (top/bottom)
- [ ] `lifeos_cosmic_accent_color` — cambiar color de acento
- [ ] `lifeos_cosmic_wallpaper` — cambiar wallpaper
- [ ] `lifeos_cosmic_font` — cambiar fuente del sistema

### Display

- [x] `lifeos_displays_list` — listar monitores (ya existia)
- [x] `lifeos_display_resolution` — cambiar resolucion de un monitor

### Conteo actual de MCP tools

| Categoria | Tools | Estado |
|-----------|-------|--------|
| OS Control (AY.1) | 16 | Implementados |
| Browser (AY.3) | 5 | Implementados |
| Layer Selection (AY.2) | 1 | Implementado |
| LibreOffice (AY.6) | 4 | Implementados |
| COSMIC Apps (AY.6) | 5 | Implementados |
| Workspaces (AY.7) | 4 | Implementados |
| COSMIC Desktop (AY.7) | 3+ | Implementados |
| **Total** | **~40** | **De 9 a ~40** |
