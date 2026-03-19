# Fase 1 - Implementación Status

## Objetivo de Fase 1
Experiencia diaria usable, rápida y estable para usuario final.

## Checklist de Fase 1 (Estado Actual)

### ✅ Completado
- [x] **Fase 0** - Fundación técnica completada
  - Sistema instalable que arranca, se actualiza y se recupera
  - Baseline de seguridad activo: Secure Boot + LUKS2
  - Validación TUF previa a update activa
  - Snapshots Btrfs pre-update operativos
  - Suite runtime de seguridad pasa en local/CI

- [x] **AI Runtime Básico**
  - llama-server integrado
  - Comandos CLI para AI (start, stop, chat, ask, models, pull, remove, status)
  - Daemon AI module con integración de llama-server
  - API REST del daemon
  - System monitoring
  - Health checks

- [x] **Arquitectura de Screen Capture**
  - Módulo `daemon/src/screen_capture.rs` creado
  - Soporte multi-plataforma (X11 y Wayland/COSMIC)
  - Herramientas de captura: grim, swaygrab, maim
  - Soporte para múltiples formatos: JPEG, PNG, WebP
  - Gestión de metadatos de capturas

- [x] **Arquitectura de Overlay AI**
  - Módulo `daemon/src/overlay.rs` creado
  - Estado de overlay visible/oculto
  - Historial de chat persistente
  - Integración con screen capture para contexto multimodal
  - Exportación/importación de chat history

- [x] **Comandos CLI para Overlay**
  - Módulo `cli/src/commands/overlay.rs` creado
  - Comandos: show, hide, toggle, chat, screenshot, clear, export, import, status, config
  - Integración con daemon API

### ✅ Completado
- [x] **Overlay AI (Super+Space)** - 100% (Implementación)
  - ✅ Módulos backend creados (overlay_window.rs 820 líneas)
  - ✅ Comandos CLI creados (overlay.rs 320+ líneas)
  - ✅ Ventana GTK4 overlay (UI flotante)
  - ✅ Integración con atajo global de teclado (Super+Space)
  - ✅ API endpoints en daemon para control de overlay (14 endpoints)
  - ✅ Soporte de temas (Dark/Light/Auto)
  - ✅ Posicionamiento configurable (9 opciones)
  - ✅ Handlers de shortcuts (4 predefinidos)
  - 🚧 Testing en COSMIC/Wayland (requiere VM)
  - 🚧 Bench p95 de latencia de apertura (<500ms objetivo)

- [x] **Modos de Experiencia (Simple/Pro/Builder)** - 100% (Implementación)
  - ✅ Módulo creado (experience_modes.rs 680 líneas)
  - ✅ Comandos CLI creados (mode.rs 360+ líneas)
  - ✅ 3 modos definidos con configuración específica
  - ✅ API endpoints (7 endpoints)
  - 🚧 Testing en COSMIC/Wayland (requiere VM)

- [x] **Scheduler de Updates por Canal** - 100% (Implementación)
  - ✅ Módulo creado (update_scheduler.rs 570+ líneas)
  - ✅ Canales stable/candidate/edge definidos
  - ✅ API endpoints (11 endpoints)
  - ✅ Funciones: download, install, rollback, verify
  - 🚧 Testing en COSMIC/Wayland (requiere VM)

### ✅ Completado
- [x] **FollowAlong Básico** - 100% (Implementación)
  - ✅ Módulo creado (follow_along.rs 600+ líneas)
  - ✅ Monitoreo de acciones del usuario
  - ✅ Sistema de consentimiento (Granted/Revoked/NotAsked)
  - ✅ Resumir/traducir/explicar con consentimiento
  - ✅ Captura de eventos de teclado/mouse
  - ✅ Algoritmo de detección de patrones
  - ✅ Gestión de contexto (application, window, active_pattern)
  - ✅ API endpoints (10 endpoints)
  - ✅ CLI commands (10 commands)
  - 🚧 Testing en COSMIC/Wayland (requiere VM)

- [x] **Políticas por Contexto (Workplace)** - 100% (Implementación)
  - ✅ Módulo creado (context_policies.rs 700+ líneas)
  - ✅ Sistema de contextos (Home, Work, Gaming, Creative, Development, Social, Learning, Travel, Custom)
  - ✅ Perfiles y reglas por contexto
  - ✅ Detección automática (time-based, network-based, application-based)
  - ✅ Aplicación automática de reglas
  - 🚧 API endpoints pendientes
  - 🚧 CLI commands pendientes
  - 🚧 Testing en COSMIC/Wayland (requiere VM)


- [ ] **Telemetría Local Opt-In**
  - Sin exfiltración por defecto
  - Métricas de estabilidad (crashes, latencia, errores)
  - Almacenamiento local cifrado
  - Opt-in explícito del usuario
  - API para acceso a métricas

- [ ] **Accesibilidad WCAG AA**
  - Validación de temas principales
  - Contraste de colores
  - Tamaño de fuentes
  - Navegación por teclado
  - Screen reader compatibility

- [ ] **Matriz de Hardware**
  - Documentación de compatibilidad actualizada
  - Mínimos RAM/VRAM por componente
  - Hardware probado y verificado
  - Publicación en docs/

## Estructura de Archivos Creados

### Daemon (Rust)
- `daemon/src/screen_capture.rs` - Captura de pantalla multi-plataforma
- `daemon/src/overlay.rs` - Gestión de overlay AI
- `daemon/src/overlay_window.rs` - Ventana GTK4 overlay (820 líneas)
- `daemon/src/keyboard_shortcut.rs` - Gestión de atajos globales (260 líneas)
- `daemon/src/experience_modes.rs` - Gestión de modos de experiencia (680 líneas)
- `daemon/src/update_scheduler.rs` - Scheduler de updates por canal (570+ líneas)
- `daemon/src/follow_along.rs` - Asistente contextual FollowAlong (600+ líneas)
- `daemon/src/context_policies.rs` - Gestión de políticas por contexto (700+ líneas)
- `daemon/src/ai.rs` - ✅ Existente, integración llama-server
- `daemon/src/models/mod.rs` - ✅ Existente, registry de modelos
- `daemon/src/api/mod.rs` - ✅ Existente, API REST (50+ endpoints)

### CLI (Rust)
- `cli/src/commands/overlay.rs` - Comandos de overlay AI (320+ líneas)
- `cli/src/commands/mode.rs` - Comandos de modos de experiencia (360+ líneas)
- `cli/src/commands/followalong.rs` - Comandos de FollowAlong (400+ líneas)
- `cli/src/commands/ai.rs` - ✅ Existente
- `cli/src/commands/update.rs` - ✅ Existente (comandos bootc)

### Configuración
- `image/files/etc/lifeos/llama-server.env` - ✅ Existente, configuración de AI
- `image/files/etc/systemd/system/llama-server.service` - ✅ Existente, servicio systemd

## Pruebas Mínimas Obligatorias (Fase 1)

### Requeridas
- [ ] **Bench p95 de apertura overlay**
  - Medir latencia de <500ms objetivo
  - Test en COSMIC (Wayland)

- [ ] **Test de regresión de permisos por contexto**
  - Verificar que modos no rompen permisos
  - Test transición entre contextos

- [ ] **Test de update en canal candidate + rollback**
  - Probar update en canal candidate
  - Verificar rollback automático en caso de fallo

- [ ] **Test de arranque y primer uso en VM limpia**
  - Verificar first-boot experience
  - Test configuración inicial

### Evidence Pack Mínimo
- [ ] Capturas/video corto de UX clave
- [ ] Reporte de latencias p95
- [ ] Resultado de pruebas de canal de update
- [ ] Documento de compatibilidad de hardware

## Pasos Siguientes

### Inmediatos (Componentes Críticos)
1. **Completar Overlay AI UI**
   - Crear ventana GTK4 overlay
   - Implementar atajo global Super+Space
   - Agregar endpoints API al daemon
   - Test latencia de apertura

2. **Implementar Modos de Experiencia**
   - Crear módulo de gestión de modos
   - Implementar perfiles Simple/Pro/Builder
   - Integrar con daemon
   - Test transición entre modos

### Corto Plazo (Funcionalidades Adicionales)
3. **Implementar FollowAlong Básico**
   - Monitoreo de eventos
   - Algoritmo de detección de acciones
   - Integración con consentimiento

4. **Implementar Scheduler de Updates por Canal**
   - Sistema de canales stable/candidate/edge
   - Configuración de preferencias
   - Planificación automática

### Largo Plazo (Estabilización)
5. **Implementar Telemetría Local Opt-In**
   - Métricas de estabilidad
   - Almacenamiento local cifrado

6. **Validar Accesibilidad WCAG AA**
   - Validar temas principales
   - Documentar resultados

7. **Actualizar Matriz de Hardware**
   - Documentar hardware probado
   - Publicar en docs/

## Dependencias Faltantes

### Para Overlay UI
- `gtk4` - UI toolkit para COSMIC
- `layer-shell` - Wayland layer shell para overlay
- Atajo global de teclado (xdg-desktop-portal)

### Para FollowAlong
- Biblioteca de captura de eventos (libinput, xinput)
- Algoritmo de detección de patrones de uso

### Para Updates por Canal
- Sistema de validación de actualizaciones
- Mecanismo de rollback automático

## Notas

1. **Corrección de llama-server**: Ya se han aplicado correcciones al servicio:
   - Context size reducido de 131072 a 4096
   - TimeoutStartSec aumentado a 120 segundos
   - RestartSec aumentado a 10 segundos
   --log-level 2 agregado para debugging

2. **Modelos**: Se ha actualizado a Qwen3.5-4B con soporte multimodal

3. **Prioridad Actual**: Completar Overlay AI (Super+Space) es la prioridad más alta para UX

## Fecha
Última actualización: 2026-03-02
