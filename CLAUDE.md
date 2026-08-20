# LifeOS app — agent operating rules (VPS)

This repo is worked on from Claude Code sessions running **inside the production VPS**, next to
Postgres, Vault, n8n and every public site. Android/Flutter builds are the heaviest thing this
machine ever does, and they are what takes it down.

## Android and Flutter builds do not belong on the VPS

On 2026-08-19 two simultaneous Android builds (a `assembleDebug` and a Flutter `assembleRelease`)
plus a headless Chromium drove the VPS to **load 96 with 63% iowait**: SSH froze for minutes, and
the laptop lost DNS because AdGuard runs here too. On 2026-08-18 a Gradle build was OOM-killed by
`user-mem-guard` twice for the same reason. This is not theoretical.

1. **Los builds de Android y Flutter se hacen en el devbox de la Asus, no aquí.** Tiene la
   cadena completa (Flutter 3.44.8, la misma revisión que este host; Android SDK 34/35/36,
   build-tools 28.0.3/34/35/36, NDK 28.2.13676358) sobre un disco de 80 GB, 8 núcleos y 16 GB
   que no compiten con producción. **Compila el release en 14 minutos**; aquí tardaba ~50 y
   moría a medias.
   ```
   ssh devbox
   cd ~/dev/gama/lifeos/lifeos-app/mobile
   flutter build apk --release          # o ./tools/publish-to-vps.sh "notas" para publicar
   ```
   El entorno se carga solo desde `~/.buildenv.sh` (PATH, ANDROID_SDK_ROOT, GRADLE_USER_HOME,
   PUB_CACHE y `DOCKER_HOST=ssh://hectormr@10.66.66.1`). Ese `DOCKER_HOST` es lo que hace que
   `publish-to-vps.sh` detecte el volumen OTA del VPS y publique ahí directamente, sin cambiar
   una línea del script.
   Antes de compilar, asegurate de que el devbox tiene la rama correcta: `ota-volume.sh` solo
   existe en `sync-over-vpn-pr1-mesh-trust`, no en `main`.

2. **Nunca compiles Android en este host.** Este VPS tiene 13 GB para TODAS las sesiones
   interactivas juntas; un build pide ~2.8 GB en ráfaga y `user-mem-guard` lo mata: pasó **seis
   veces el 2026-08-19**. Si por algo tuvieras que hacerlo igualmente, va dentro de su caja:
   `build-safe ./gradlew ...` — pero es el último recurso, no el camino.

3. **Nunca dos builds a la vez**, ni en una sesión ni entre varias. Comprobalo antes:
   ```
   pgrep -af 'GradleDaemon|assemble|flutter build' | head
   ssh devbox 'pgrep -af "flutter build|gradle" | head'
   ```

4. **Nunca compiles con un navegador abierto.** Playwright/Chromium y Gradle son ambos glotones
   de disco; juntos saturan la cola y congelan todo, incluida tu propia shell.

5. **El `publish-to-vps.sh` tarda ~14 min en el devbox.** Lanzalo a conciencia, uno a la vez.

`~/.gradle/gradle.properties` already forces `org.gradle.daemon=false`, a 2 GB heap and 3 workers
(host-wide policy, set 2026-08-18 after 4 GB Gradle daemons kept surviving builds and getting
killed as orphans). Do not override those in the project files.

## Long-running jobs must not outlive their session

A killed Claude session leaves its children running: on 2026-08-19 an orphaned `publish-to-vps.sh`
kept building for 50 minutes after its session died (it did finish and publish 0.9.19-864, but
that was luck). Anything that runs longer than a few minutes should be started with `timeout`, and
if you are about to end a session, check what you are leaving behind:
```
pgrep -af 'gradle|flutter|playwright|chromium' | head
```

## Browser automation

Close Playwright/Chromium when you are done with it. Two orphaned headless Chromiums accumulated
218 hours of CPU in state D before anyone noticed. The MCP server does not clean them up for you.
