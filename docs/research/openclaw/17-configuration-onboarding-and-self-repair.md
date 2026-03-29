# 17 - Configuration, Onboarding, And Self-Repair

## Tesis

OpenClaw no trata la configuracion como un archivo muerto.
La trata como un sistema vivo que:

- migra
- valida
- se audita
- se repara
- y se protege de clobbers accidentales

Eso explica una parte muy grande de por que el producto sobrevive upgrades y setups reales.

## `loadConfig` hace mucho mas que parsear JSON5

La export publica `src/config/config.ts` reexpone una capa bastante grande, pero la implementacion real vive sobre todo en `src/config/io.ts`.

Ahí aparecen varias fases:

- resolver ruta de config
- cargar `.env` y fallback de shell env
- resolver includes con guards
- sustituir env vars
- aplicar migraciones legacy
- validar con schema plugin-aware
- aplicar defaults y normalizaciones
- detectar problemas legacy y duplicados
- aplicar runtime overrides

La conclusion es clara:

- OpenClaw no confia en que la config ya venga limpia
- la lleva a un estado operativo antes de usarla

## IO de config como safety system

`src/config/io.ts` es uno de los archivos mas reveladores de todo el repo.

No solo lee y escribe.
Tambien mantiene:

- `config-audit.jsonl`
- `config-health.json`
- fingerprints de archivo
- `lastKnownGood`
- deteccion de estados sospechosos
- copia de artefactos clobbered
- backups rotados

Eso quiere decir que el equipo ya penso en problemas como:

- editores o procesos que pisan la config
- escrituras parciales
- corrupciones raras
- cambios concurrentes

Esta es una capa muy poco comun en proyectos personales y muy comun en productos que ya recibieron golpes reales.

## Escrituras cuidadosas y redaccion de secretos

La misma capa de config cuida que los secretos no destruyan la ergonomia del producto.

`src/config/redact-snapshot.ts` introduce un detalle especialmente bueno:

- un sentinel `__OPENCLAW_REDACTED__`

La idea es que la UI o APIs puedan redondear una config ya redactada sin sobrescribir credenciales con basura.

Tambien hay soporte para:

- SecretRefs
- ocultar `id` sensibles
- quitar userinfo de URLs
- preservar placeholders tipo `${VAR}`

Esto revela que ya resolvieron el problema de "quiero editar config desde UI sin romper secretos".

## Legacy migration y compatibilidad operativa

`src/config/legacy-migrate.ts` no intenta ser magia.
Hace algo mejor:

- aplica migraciones conocidas
- valida el resultado con el schema real
- si todavia queda invalido, lo admite y deja cambios/hints

Eso hace que las migraciones sean:

- explicitas
- auditables
- y no silenciosamente destructivas

## Schema y metadata de UI como contrato

`src/config/schema.ts` y `src/config/doc-baseline.ts` muestran otra decision muy madura:

- el schema no sirve solo para validar
- tambien alimenta surfaces de UI y documentacion

Se combinan varias cosas:

- schema base generado
- hints de UI
- metadata de plugins
- metadata de canales
- baseline de docs generado en `docs/.generated/`

La configuracion, entonces, no es solo "lo que acepta el parser".
Es una superficie publica relativamente gobernada.

## Onboarding no interactivo como producto

`src/commands/onboard-non-interactive/local.ts` muestra que la instalacion automatizable esta bien trabajada.

El flujo hace, en orden:

- elegir workspace
- resolver auth/provider
- configurar Gateway
- aplicar skills
- escribir config con metadata del wizard
- crear workspace y sesiones
- instalar daemon si se pidio
- esperar health real del Gateway

Lo importante es que no se limita a "escribir un archivo".
Tambien valida que el sistema levantado quede utilizable.

## Instalacion del daemon con prechecks reales

`src/commands/onboard-non-interactive/local/daemon-install.ts` confirma que no todo vale con tal de "instalar algo":

- en Linux detecta si hay user systemd disponible
- valida runtime `node` o `bun`
- resuelve el token real a instalar
- bloquea si la auth configurada no puede resolverse
- instala el servicio con un plan calculado

Eso evita setups a medias que "parecen instalados" pero nacen rotos.

## `doctor` como motor de autoreparacion

La capa `src/commands/doctor/` esta mucho mas cerca de una herramienta de mantenimiento que de un simple comando informativo.

`repair-sequencing.ts` y sus helpers reparan cosas como:

- usernames/allowlists de Telegram
- IDs numericos de Discord
- politicas `allowFrom`
- rutas de plugins bundled
- referencias stale a plugins
- perfiles `exec-safe-bins`
- claves legacy

Y si no conviene reparar automaticamente, dejan hints concretos.

Eso es muy importante porque convierte muchos upgrades rotos en un flujo guiado de recuperacion.

## Stale plugin config y drift operativo

`src/commands/doctor/shared/stale-plugin-config.ts` muestra otro patron excelente:

- primero mira el registry real de plugins
- luego detecta ids viejos en `plugins.allow` o `plugins.entries`
- solo auto-repara si discovery no esta ya en estado de error

Es decir:

- no corrige ciegamente
- corrige solo cuando el sistema tiene suficiente certeza

## Que patrones explican que esta capa sea fuerte

- config IO con auditoria y health fingerprint
- redaccion reversible para no romper secretos
- migraciones validadas, no solo transformaciones textuales
- schema + UI metadata + docs baseline
- onboarding que verifica salud de runtime
- daemon install con bloqueos cuando faltan prerequisitos
- doctor como sistema de reparacion incremental

## Archivos mas importantes

- `../openclaw-main/src/config/config.ts`
- `../openclaw-main/src/config/io.ts`
- `../openclaw-main/src/config/schema.ts`
- `../openclaw-main/src/config/legacy-migrate.ts`
- `../openclaw-main/src/config/redact-snapshot.ts`
- `../openclaw-main/src/config/doc-baseline.ts`
- `../openclaw-main/src/commands/onboard-non-interactive/local.ts`
- `../openclaw-main/src/commands/onboard-non-interactive/local/daemon-install.ts`
- `../openclaw-main/src/commands/doctor/finalize-config-flow.ts`
- `../openclaw-main/src/commands/doctor/repair-sequencing.ts`
- `../openclaw-main/src/commands/doctor/shared/config-flow-steps.ts`
- `../openclaw-main/src/commands/doctor/shared/stale-plugin-config.ts`
- `../openclaw-main/docs/start/wizard.md`

## Conclusion

Una parte enorme de la madurez de OpenClaw no esta en los prompts ni en los modelos.
Esta en que ya invirtieron mucho en hacer que la configuracion:

- sobreviva cambios
- se pueda instalar bien
- se pueda reparar
- y no pierda secretos ni consistencia en el camino

