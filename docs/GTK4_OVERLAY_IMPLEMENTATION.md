# GTK4 Overlay Window - Instructions de Prueba

## Implementación Completada

### Archivos Creados

#### Daemon (Rust)
- `daemon/src/overlay_window.rs` - Ventana GTK4 overlay completa
  - Ventana flotante redimensionable y arrastrable
  - Chat UI con historial
  - Integración con captura de pantalla
  - Atajo Escape para cerrar
  - Soporte para temas Dark/Light/Auto

- `daemon/Cargo.toml` - Dependencias actualizadas
  - `gtk4 = "0.9"` (para COSMIC)
  - `glib = "0.20"`
  - `image`, `base64`, `uuid` (para captura de pantalla)
  - Feature `ui-overlay` agregada

- `daemon/src/api/mod.rs` - Endpoints API para overlay
  - `/api/v1/overlay/show`
  - `/api/v1/overlay/hide`
  - `/api/v1/overlay/toggle`
  - `/api/v1/overlay/chat`
  - `/api/v1/overlay/screenshot`
  - `/api/v1/overlay/clear`
  - `/api/v1/overlay/status`
  - `/api/v1/overlay/config`
  - `/api/v1/overlay/export`
  - `/api/v1/overlay/import`

- `daemon/src/main.rs` - Módulo integrado

#### CLI (Rust)
- `cli/src/commands/overlay.rs` - Comandos CLI listos

- `cli/src/main.rs` - Comando `Overlay` agregado

### Características Implementadas

#### Ventana Overlay
- ✅ Posicionamiento configurable (Center, TopLeft, TopRight, BottomLeft, BottomRight, Custom)
- ✅ Redimensionable
- ✅ Arrastrable
- ✅ Sin decoraciones de ventana (decorated=false)
- ✅ Siempre encima de otras ventanas
- ✅ Opacidad configurable (0.0-1.0)

#### Chat UI
- ✅ Área de chat con scroll
- ✅ Campo de entrada con placeholder
- ✅ Botón Send (estilo sugerido)
- ✅ Botón Screenshot con emoji 📷
- ✅ Botón Clear con emoji 🗑
- ✅ Mensajes de usuario y AI con colores distintivos
- ✅ Historial persistente en OverlayState

#### Temas
- ✅ Modo Dark (para COSMIC por defecto)
- ✅ Modo Light
- ✅ Modo Auto (sigue preferencias del sistema)

#### Handlers
- ✅ Send button: envía mensaje a AI (placeholder)
- ✅ Screenshot: captura pantalla y agrega a chat
- ✅ Clear: limpia historial de chat
- ✅ Escape key: cierra ventana
- ✅ Focus on show: enfoca campo de entrada
- ✅ Hide: actualiza estado a visible=false

### Comandos CLI Disponibles

```bash
# Mostrar overlay
life overlay show

# Ocultar overlay
life overlay hide

# Alternar visibilidad
life overlay toggle

# Enviar mensaje
life overlay chat "¿Qué hora es?"

# Capturar pantalla
life overlay screenshot

# Limpiar chat
life overlay clear

# Ver estado
life overlay status

# Configurar
life overlay config --theme dark --shortcut "Super+Space" --opacity 0.95 --enabled true

# Exportar chat
life overlay export /tmp/lifeos_chat.json

# Importar chat
life overlay import /tmp/lifeos_chat.json
```

### Pasos Siguientes para Completar

#### 1. Implementar Handlers de API
Los endpoints están definidos pero faltan los handlers que responden a las requests.

**Handlers a implementar:**
```rust
#[utoipa::path(
    post,
    path = "/api/v1/overlay/show",
    responses(
        (status = 200, description = "Overlay shown"),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn show_overlay(State(_state): State<ApiState>) -> StatusCode {
    // Trigger overlay window show via GTK event or D-Bus
    StatusCode::OK
}

// Similar handlers para hide, toggle, chat, screenshot, clear, status, config, export, import
```

#### 2. Implementar Atajo Global de Teclado
Para que Super+Space funcione como atajo global:

**Opción A: xdg-desktop-portal (Recomendado)**
```bash
# Instalar portal
sudo dnf install xdg-desktop-portal

# Usar API de portal para registrar atajo
# Esto permite que funcione en Wayland sin romper sandbox
```

**Opción B: layer-shell (Más complejo)**
```bash
# Crear layer-shell personalizado
# Integrar con Wayland compositor
```

**Opción C: Atajo en COSMIC (Si disponible)**
```bash
# Configurar COSMIC para ejecutar comando en Super+Space
# Editar ~/.config/cosmic/com.cosmic.Keybindings
```

#### 3. Integración con OverlayManager
El módulo `overlay_window.rs` actualmente es independiente. Para integrarlo con `OverlayManager`:

**Opción A: Event Channel**
```rust
// En overlay_window.rs
use tokio::sync::broadcast;

pub struct OverlayWindow {
    event_tx: broadcast::Sender<OverlayEvent>,
}

#[derive(Clone)]
pub enum OverlayEvent {
    Show,
    Hide,
    Toggle,
    Chat { message: String, include_screen: bool },
    Screenshot,
    Clear,
}

// En daemon
// Crear canal de comunicación entre API y ventana
```

**Opción B: Shared State**
```rust
// Ya existe Arc<RwLock<OverlayState>>
// Modificar overlay_window para usarlo directamente
```

### Testing

#### Tests Requeridos
- [ ] Abrir overlay con comando CLI
- [ ] Cerrar con Escape key
- [ ] Enviar mensaje y ver respuesta en chat
- [ ] Capturar pantalla
- [ ] Limpiar historial
- [ ] Probar en COSMIC (Wayland)

#### Bench de Latencia (p95 <500ms objetivo)
```bash
# Script de benchmark
#!/bin/bash

for i in {1..100}; do
    start=$(date +%s%N)
    life overlay show
    sleep 0.1  # Esperar a que ventana aparezca
    # Verificar si ventana es visible
    end=$(date +%s%N)
    latency=$((end - start))
    echo "$latency"
done | sort -n | tail -1 > latencies.txt

# Calcular p95
python3 -c "
import numpy as np
data = np.loadtxt('latencies.txt')
p95 = np.percentile(data, 95)
print(f'p95 latency: {p95:.2f}ms')
"
```

### Solución de Problemas Conocidos

#### Problema 1: GTK en Wayland
**Solución:** El módulo actual usa gtk4 con ApplicationWindow estándar. Para Wayland/COSMIC, esto debería funcionar porque GTK4 maneja la plataforma automáticamente.

#### Problema 2: Atajo Global
**Solución:** Usar xdg-desktop-portal o crear un pequeño proceso que escucha atajos y envía comandos a la ventana overlay.

#### Problema 3: Integración con llama-server
**Solución:** El módulo `ai.rs` ya tiene la función `chat()` que llama a llama-server. Los handlers API deberían usar esta función existente.

### Configuración

#### Archivo de Configuración (`/etc/lifeos/overlay.conf`)
```toml
[overlay]
enabled = true
shortcut = "Super+space"
theme = "dark"
opacity = 0.95
default_position = "center"
show_preview = true

[keybindings]
show = "Super+space"
hide = "Escape"
screenshot = "Super+shift+s"
```

### Próximos Pasos

1. **Implementar handlers API** (Prioridad Alta)
2. **Implementar atajo global Super+Space** (Prioridad Alta)
3. **Test completo en VM COSMIC** (Prioridad Alta)
4. **Bench p95 latencia** (Requerido para Fase 1)

### Archivos de Configuración de Sistema

#### Archivo Desktop Entry
`/usr/share/applications/lifeos-overlay.desktop`
```desktop
[Desktop Entry]
Name=LifeOS AI Overlay
Comment=AI Assistant Overlay
Exec=life overlay toggle
Icon=lifeos-overlay
Type=Application
Categories=Utility;
StartupNotify=false
Terminal=false
```

#### Keybinding en COSMIC
Configurar en COSMIC settings:
- Super+Space → `life overlay toggle`
- Escape → `life overlay hide`

### Notas Importantes

1. **Wayland Layer**: Para que la ventana esté "siempre encima" en Wayland, se necesita usar un layer-shell o configurar el compositor correctamente.

2. **Privilegios**: La ventana debe iniciarse con permisos apropiados para capturar pantalla. Esto puede requerir `xdg-desktop-portal`.

3. **Estado Persistente**: El `OverlayState` ya está en `Arc<RwLock<>>`, lo que permite compartir estado entre la ventana y la API.

4. **Performance**: La ventana debe usar CSS nativo de GTK4 para mejor rendimiento. No usar webkit o webview.

5. **Accesibilidad**: Asegurar que la ventana cumpla WCAG AA cuando esté completamente implementada.

### Comandos de Diagnóstico

```bash
# Ver estado de overlay
life overlay status

# Verificar que daemon está corriendo
systemctl status lifeosd

# Ver logs del daemon
journalctl -u lifeosd -f

# Ver logs de overlay (cuando se implemente)
journalctl -u lifeosd | grep overlay

# Probar API de overlay
curl http://127.0.0.1:8081/api/v1/overlay/status

# Enviar mensaje de prueba
curl -X POST http://127.0.0.1:8081/api/v1/overlay/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "test", "include_screen": false}'
```

### Cronograma

| Tarea | Estado | Prioridad |
|-------|--------|----------|
| Handlers API | Pendiente | Alta |
| Atajo Global | Pendiente | Alta |
| Test COSMIC | Pendiente | Alta |
| Bench p95 | Pendiente | Requerido |
| Documentación | Completada | Media |

Última actualización: 2026-03-02
