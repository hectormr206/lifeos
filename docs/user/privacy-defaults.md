# Defaults de privacidad en LifeOS

LifeOS está diseñado para correr **encima** de tu Linux sin tomar control de
nada sin tu consentimiento. Esta página lista todos los features que están
**OFF por defecto** y cómo activarlos.

## Features off por defecto

| Feature | Motivo del default off | Cómo activar |
|---------|----------------------|--------------|
| Captura de voz / wake word (`voice_enabled`) | El micrófono es un recurso compartido; grabarlo sin consentimiento es invasivo y puede bloquear otras apps | Dashboard → Sistema → Voz, o `voice_enabled = true` en `/etc/lifeos/daemon.toml`, o env `LIFEOS_ENABLE_VOICE=1` |
| Notificaciones de escritorio proactivas (`proactive_notifications_enabled`) | Las notificaciones no solicitadas interrumpen el flujo de trabajo | Dashboard → Sistema → Notificaciones, o `proactive_notifications_enabled = true` en daemon.toml, o env `LIFEOS_DESKTOP_NOTIFICATIONS=1` |

## Qué sigue funcionando aunque el feature esté off

| Feature off | Qué sigue activo |
|-------------|-----------------|
| `voice_enabled = false` | El daemon sigue corriendo; el dashboard, LLM, TTS de respuesta por texto, y todos los demás servicios funcionan normalmente. Solo el ciclo de captura de micrófono y el wake word están inactivos. |
| `proactive_notifications_enabled = false` | Las comprobaciones de salud del sistema (disco, RAM, temperatura, batería, firewall, etc.) **siguen corriendo** cada 5 minutos. Sus alertas se acumulan en el ring buffer interno y son visibles en el panel del dashboard (`GET /api/v1/security/alerts`). Solo se suprime el pop-up de escritorio via `notify-send`. |

## Configuracion en daemon.toml

Editá `/etc/lifeos/daemon.toml` (crealo si no existe):

```toml
# /etc/lifeos/daemon.toml

# Habilita captura de voz y wake word (default: false)
voice_enabled = true

# Habilita notificaciones de escritorio proactivas (default: false)
proactive_notifications_enabled = true
```

Reiniciá el daemon para que tome efecto:

```bash
systemctl --user restart lifeosd
```

## Override via variables de entorno

Las variables de entorno tienen prioridad sobre el archivo de configuracion:

```ini
# /etc/systemd/system/lifeosd.service.d/privacy-override.conf
[Service]
Environment=LIFEOS_ENABLE_VOICE=1
Environment=LIFEOS_DESKTOP_NOTIFICATIONS=1
```

Recargá la configuracion de systemd:

```bash
systemctl daemon-reload
systemctl --user restart lifeosd
```

## Por que LifeOS no te espia

- El codigo fuente es abierto y auditable.
- Ningun dato sale de tu maquina a servidores de terceros salvo que configures
  explicitamente un proveedor LLM externo (OpenAI, Anthropic, etc.).
- El modelo de lenguaje local (Qwen3.5-4B) corre completamente offline.
- El microfono solo se activa cuando `voice_enabled = true` Y el usuario no
  ha activado el kill switch sensorial.
- Cada acceso al microfono, camara, o pantalla queda registrado en el audit
  ring (`GET /api/v1/sensory/gate-audit`) y es visible desde el dashboard.
