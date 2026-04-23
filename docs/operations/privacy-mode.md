# Modo Privacidad

> Override global que fuerza al `llm_router` a usar **solamente** providers
> con `tier=Local`. Cualquier llamada que el router despache mientras está
> ON queda confinada al modelo local — sin escalation a Free, sin fallback
> silencioso a remoto.

## ¿Qué es?

El **Modo Privacidad** es una política de runtime que vive sobre `llm_router.rs`.
Cuando está ON:

- `select_candidates(...)` se filtra a `tier=Local` después del rank.
- `chat_with_escalation()` deshabilita la escalation a Free y delega
  directamente a `chat()` con el filtro aplicado.
- Si un caller pasa `preferred_provider` que no es Local, el router lo
  sobrescribe (con `warn!`) por el primer Local disponible.
- Si **no hay** ningún provider Local disponible, la request falla con error
  claro `PRIVACY_MODE_NO_LOCAL` — nunca se cae a remoto silente.

## ¿Para qué?

Funciona como **referencia "100% confidencial"** experimental: te permite
descubrir los límites del modelo local cuando importa más la confidencialidad
que la calidad de la respuesta. Útil para:

- Procesar documentos sensibles (médicos, legales, fiscales).
- Sesiones de brainstorming personales que no querés que toquen API externas.
- Auditar el comportamiento del modelo local frente a un task real.

## Cómo activar

Hay tres vías equivalentes — la primera que aplique gana:

1. **Tray icon → "Modo Privacidad (solo modelo local)"**
   Toggle visual en el system tray. Persiste a archivo.

2. **Dashboard → botón "Modo Privacidad" en el sidebar (header)**
   Verde cuando ON, gris cuando OFF. Persiste a archivo.

3. **Variable de entorno** `LIFEOS_PRIVACY_MODE`
   - `1`, `true`, `yes`, `on` → fuerza ON
   - `0`, `false`, `no`, `off` → fuerza OFF
   - Cualquier otro valor → se ignora y cae al archivo
   - Si está set, **prevalece sobre el archivo**. Útil para servicios
     systemd o tests que necesitan un estado fijo.

## Persistencia

- Archivo: `~/.config/lifeos/privacy-mode` (un único byte, `0` o `1`).
- Escritura atómica (tempfile + rename) — un toggle interrumpido nunca
  deja un archivo a medias.
- Cache en memoria: un `RwLock<bool>` que se carga la primera vez y se
  refresca en cada `set_privacy_mode()`. Evita golpear disco en cada
  request del router.
- El archivo se crea automáticamente en el primer toggle. No existe →
  default `false`.

## Behavior cuando ON

| Aspecto | Comportamiento |
|---------|----------------|
| Filter de candidates | `retain(|p| p.tier == ProviderTier::Local)` después del rank |
| Escalation Free | **Deshabilitada** — delega a `chat()` directo |
| Sin provider Local | Error `PRIVACY_MODE_NO_LOCAL` con mensaje accionable |
| `preferred_provider` no-Local | Override silencioso al primer Local + `warn!` |
| Endpoint API | `GET/POST /api/v1/privacy-mode` (auth bootstrap-token) |

## Limitaciones honestas

El Modo Privacidad cubre **únicamente** el LLM dispatch a través del
`llm_router`. **NO** afecta:

- Llamadas que el daemon hace a APIs externas que **NO** pasan por
  `llm_router` (por ejemplo: GitHub Actions, llamadas directas a Cerebras
  vía env var en otros módulos, webhooks, telemetría).
- MCP tools que invocan servicios externos. Si el usuario pide
  explícitamente un MCP tool que llama a un servicio remoto, eso **no**
  está protegido por este toggle — el contrato del Modo Privacidad es
  sobre el dispatch del modelo, no sobre intenciones del usuario.
- SimpleX bridge, dashboard chat, ni cualquier otro plano que no consulte
  `is_privacy_mode_enabled()` antes de actuar.

Si querés un kill-switch total sobre todo el tráfico saliente, usá el
**Kill Switch** del tray (que apaga sentidos completos), o configurá tu
firewall a nivel sistema.

## API

```
GET  /api/v1/privacy-mode
→ { "enabled": true, "source": "env" | "file" | "default" }

POST /api/v1/privacy-mode
Body: { "enabled": true }
→ { "enabled": true, "source": "env" | "file" | "default" }
```

Auth: header `x-bootstrap-token: <token>` (mismo pattern que el resto de
`/api/v1/*`).

> Si `source` viene como `env`, el POST igual escribe el archivo, pero la
> respuesta GET seguirá reportando `env` mientras esa variable esté set.
> Quitá la env var (o desactivá el unit de systemd que la define) para que
> el archivo vuelva a tener efecto.
