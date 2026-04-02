# Fase BD — Calendario Inteligente

> Sistema completo de gestion de eventos, recordatorios e integracion
> con calendarios externos. Axi como asistente proactivo de agenda.

## Estado actual (2026-04-01)

| Componente | Estado | Detalle |
|---|---|---|
| CalendarManager (SQLite) | **Funcional** | calendar.db con eventos, zonas horarias, recordatorios |
| Telegram tools (#67, #68) | **Corregido** | Ahora usan CalendarManager real (antes usaban JSON suelto) |
| Chequeo de recordatorios | **Funcional** | Cada 60 seg revisa due_reminders() |
| API REST | **Funcional** | /api/v1/calendar/* (CRUD + reminders) |
| Eventos recurrentes | **Parcial** | Campo recurrence existe en schema pero sin logica |
| Google Calendar sync | **No implementado** | — |
| CalDAV/iCal sync | **No implementado** | — |
| GNOME Calendar integracion | **No implementado** | — |
| Vista calendario en dashboard | **No implementado** | — |
| Recordatorios perdidos | **No implementado** | No hay historial de que recordatorios se enviaron |

## Tareas

### BD.1 — Eventos recurrentes
- Implementar logica de recurrencia (diario, semanal, mensual, personalizado)
- Formato: iCal RRULE simplificado ("cada lunes", "cada 2 semanas", "primer viernes del mes")
- Axi debe entender lenguaje natural: "Todos los martes a las 9am tengo junta"
- Generar instancias automaticas de eventos futuros
- Permitir excepciones ("este martes no hay junta")
- Archivo: calendar.rs

### BD.2 — Google Calendar sync (bidireccional)
- OAuth2 flow para conectar cuenta de Google
- Sincronizar eventos de Google Calendar → CalendarManager
- Sincronizar eventos creados en Axi → Google Calendar
- Deteccion de conflictos (mismo horario, diferentes fuentes)
- Sync incremental (solo cambios, no full refresh)
- Respeto a privacidad: datos guardados localmente, sync es opt-in
- Archivo: nuevo modulo google_calendar.rs
- Dependencia: google-apis-rs o reqwest + OAuth2

### BD.3 — CalDAV/iCal sync
- Soporte para servidores CalDAV (Nextcloud, Radicale, Baikal, iCloud)
- Import de archivos .ics
- Export de calendario a .ics
- Sync bidireccional con CalDAV
- Esto cubre: Nextcloud Calendar, Thunderbird, Apple Calendar (via iCloud CalDAV)
- Archivo: nuevo modulo caldav_sync.rs
- Dependencia: ical-rs o custom parser

### BD.4 — Integracion con GNOME/COSMIC Calendar
- Leer eventos del calendario del sistema (GNOME Online Accounts, Evolution Data Server)
- Mostrar eventos de Axi en el calendario del escritorio
- Usar xdg-desktop-portal para notificaciones de recordatorio nativas
- Sincronizacion automatica cuando el usuario agrega eventos en GNOME Calendar
- Archivo: nuevo modulo desktop_calendar.rs
- Dependencia: D-Bus (zbus), evolution-data-server API

### BD.5 — Vista calendario en dashboard
- Seccion de calendario en el dashboard web
- Vista mensual con eventos marcados
- Vista de dia con timeline
- Lista de proximos eventos
- Proximos recordatorios
- Crear/editar/eliminar eventos desde el dashboard
- Archivos: dashboard/index.html, dashboard/app.js

### BD.6 — Historial de recordatorios
- Registrar cuando se envia cada recordatorio (timestamp, canal, entregado si/no)
- Si el recordatorio no se pudo entregar (Telegram caido, usuario desconectado):
  - Reintentar en 5 minutos
  - Guardar como "recordatorio pendiente"
  - Entregar al reconectar
- Vista de "recordatorios enviados hoy" en dashboard
- Archivo: calendar.rs

### BD.7 — Recordatorios inteligentes (proactivos)
- Axi analiza patrones de calendario:
  - "Siempre tienes junta los martes a las 9am, quieres que la agende automaticamente?"
  - "Tu cita del viernes se acerca, necesitas preparar algo?"
  - "No tienes nada agendado para manana, quieres que revise tu email por pendientes?"
- Recordatorios adaptativos:
  - Si la cita es lejos (otra ciudad), recordar con mas anticipacion
  - Si la cita es virtual (Meet/Zoom), recordar 5 min antes
  - Si hay trafico (integracion futura), ajustar recordatorio
- Archivo: proactive.rs + calendar.rs

### BD.8 — Importacion/Migracion
- Importar calendarios existentes del usuario:
  - Google Calendar (via export .ics)
  - Apple Calendar (via .ics export)
  - Outlook (.ics export)
  - Archivos .ics individuales
- Wizard de migracion en el dashboard
- Detectar duplicados al importar
- Archivo: calendar.rs + dashboard

### BD.9 — Unificacion de cron + calendario
- Actualmente existen dos sistemas separados:
  - CronStore (telegram_cron.json) — tareas recurrentes via Telegram
  - ScheduledTaskManager (scheduled_tasks.db) — tareas via API
  - CalendarManager (calendar.db) — eventos
- Unificar en un solo sistema de "eventos programados":
  - Eventos de calendario con recordatorio
  - Tareas recurrentes (cron jobs)
  - Recordatorios de salud
- Un solo lugar para ver "que tengo pendiente"
- Archivos: calendar.rs, telegram_tools.rs, scheduled_tasks.rs

## Prioridad sugerida

| Tarea | Impacto | Esfuerzo | Prioridad |
|---|---|---|---|
| BD.1 Eventos recurrentes | Alto | Medio | **1** |
| BD.5 Vista calendario dashboard | Alto | Medio | **2** |
| BD.6 Historial recordatorios | Medio | Bajo | **3** |
| BD.7 Recordatorios inteligentes | Alto | Alto | **4** |
| BD.2 Google Calendar sync | Alto | Alto | **5** |
| BD.9 Unificacion cron+calendario | Medio | Alto | **6** |
| BD.3 CalDAV/iCal sync | Medio | Alto | **7** |
| BD.4 GNOME/COSMIC Calendar | Bajo | Alto | **8** |
| BD.8 Importacion/Migracion | Bajo | Medio | **9** |

## Dependencias externas

| Componente | Para que | Tamano |
|---|---|---|
| google-apis-rs o reqwest+OAuth2 | Google Calendar API | ~5 MB |
| ical-rs | Parser iCal/CalDAV | ~1 MB |
| zbus (ya incluido) | D-Bus para GNOME Calendar | Ya instalado |
| evolution-data-server | GNOME Calendar backend | ~50 MB (sistema) |

## Ejemplo de flujo completo (futuro)

```
Usuario: "Tengo cita con el dentista el viernes a las 4pm"

Axi:
1. Crea evento en CalendarManager (SQLite)
2. Sincroniza a Google Calendar (si configurado)
3. Detecta que es presencial → recordatorio 30 min antes
4. Viernes 3:30pm → "Tienes cita con el dentista en 30 minutos"
5. Si no responde → reintenta en 5 min
6. Guarda en historial: "Recordatorio entregado a las 15:30"
7. Despues de la cita → "Como te fue con el dentista?"
```
