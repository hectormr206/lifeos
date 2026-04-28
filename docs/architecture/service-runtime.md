# Runtime Model de Servicios

Este documento define la verdad canonica del runtime model actual de servicios en LifeOS.

## Resumen ejecutivo

| Componente | Runtime primario hoy | Fallback soportado | Legacy / debug |
| --- | --- | --- | --- |
| `lifeosd` | `systemd --user` | Ninguno como modo operativo normal | Alias en system scope solo para compat/debug |
| `llama-server` | `systemd` de sistema | `systemd --user` solo si un host o flujo de recuperacion lo monta asi | Overrides/drop-ins viejos fuera del env runtime actual |

## Verdad canonica

### `lifeosd`

- `lifeosd` corre primariamente como **user service**.
- La razon operativa es concreta: necesita heredar sesion grafica y recursos del usuario (`Wayland`, `PipeWire`, `D-Bus`, secretos/config de usuario).
- La unit canonica se genera en `image/Containerfile` y se instala en `/usr/lib/systemd/user/lifeosd.service`.
- La imagen habilita `lifeosd` en `default.target` del usuario, no en `multi-user.target` del sistema.

Comandos canonicos:

```bash
systemctl --user status lifeosd
systemctl --user restart lifeosd
journalctl --user -u lifeosd -f
```

### `llama-server`

- `llama-server` corre primariamente como **system service**.
- La unit canonica vive en `/usr/lib/systemd/system/llama-server.service`.
- Se habilita en `multi-user.target` y expone el runtime local en loopback.
- `lifeosd` consume ese runtime por HTTP local y puede ajustar parametros via env/runtime overrides.

Comandos canonicos:

```bash
sudo systemctl status llama-server
sudo systemctl restart llama-server
journalctl -u llama-server -f
```

## System scope vs user scope

### Alias de `lifeosd` en system scope

- La imagen deja un symlink en `/usr/lib/systemd/system/lifeosd.service` apuntando a la user unit.
- Ese alias **no cambia la verdad canonica**: `lifeosd` no se considera un servicio de sistema primario.
- Su funcion actual es compatibilidad y debug rapido para operadores o scripts legacy que todavia inspeccionan `lifeosd.service` desde system scope.
- **Drift conocido:** algunos hosts tienen `/etc/systemd/system/lifeosd.service -> /dev/null` (mask manual). Esa configuracion **no es canonica** y debe revertirse con `sudo systemctl unmask lifeosd.service` para restaurar el alias de debug/legacy. No hay ninguna parte de la imagen que instale ese mask; si aparece, es drift local y debe limpiarse.

### Fallback user para `llama-server`

- Algunos hosts o flujos de recuperacion pueden levantar `llama-server` como user unit.
- Ese modo existe como fallback operativo, no como narrativa principal del producto.
- La documentacion debe revisar primero system scope y solo despues user scope si la unit de sistema no existe o el host fue overrideado.

## Artefactos legacy

- El archivo legacy del repo `files/usr/lib/systemd/system/lifeosd.service` ya no define el runtime real de la imagen.
- Los drop-ins viejos en `/etc/systemd/system/llama-server.service.d/` se consideran legacy si duplican lo que hoy vive en:
  - `/etc/lifeos/llama-server.env`
  - `/var/lib/lifeos/llama-server-runtime-profile.env`
  - `/var/lib/lifeos/llama-server-game-guard.env`

## Profile model selection (Qwen3.5 9B vs 4B)

`RuntimeSettings` en `daemon/src/ai_runtime_profile.rs` lleva ahora dos campos opcionales `model` y `mmproj` que se emiten como `LIFEOS_AI_MODEL` y `LIFEOS_AI_MMPROJ` en los archivos `runtime-profile.env` y `game-guard.env`. Reglas vigentes:

- **`normal_gpu`**: pinea Qwen3.5-9B-Q4_K_M.gguf + Qwen3.5-9B-mmproj-F16.gguf con `gpu_layers=99`. Es el modelo canónico cuando la GPU está disponible.
- **`game_guard_cpu_fallback`**: pinea Qwen3.5-4B-Q4_K_M.gguf + Qwen3.5-4B-mmproj-F16.gguf con `gpu_layers=0`. Cuando game_guard detecta un juego, libera la VRAM al juego y deja a Axi corriendo el modelo más chico en CPU pero **conservando ctx grande (hasta 131K en máquinas con ≥ 64GB RAM)** para no perder tool-calling ni contexto conversacional.
- **`cpu_ram`**: deja `model=None`/`mmproj=None`, hereda lo que esté en `/etc/lifeos/llama-server.env` (default 9B). Es el perfil "no hay GPU disponible" y el usuario decide si bumpea a 4B manualmente.

Como los `EnvironmentFile=` cargan en orden (`llama-server.env` → `runtime-profile.env` → `game-guard.env`), el último archivo presente gana — game_guard puede sobrescribir el modelo del runtime profile, y al limpiarse vuelve al runtime profile (9B en GPU).

## Fuentes de verdad

Orden de prioridad para entender el runtime real:

1. `image/Containerfile`
2. `image/files/etc/systemd/system/llama-server.service`
3. `docs/architecture/service-runtime.md`
4. Runbooks operativos (`docs/operations/*`, `docs/user/*`)

Si otro archivo contradice esta pagina, se considera desactualizado hasta corregirlo.
