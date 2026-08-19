# LifeOS app — agent operating rules (VPS)

This repo is worked on from Claude Code sessions running **inside the production VPS**, next to
Postgres, Vault, n8n and every public site. Android/Flutter builds are the heaviest thing this
machine ever does, and they are what takes it down.

## Android and Flutter builds do not belong on the VPS

On 2026-08-19 two simultaneous Android builds (a `assembleDebug` and a Flutter `assembleRelease`)
plus a headless Chromium drove the VPS to **load 96 with 63% iowait**: SSH froze for minutes, and
the laptop lost DNS because AdGuard runs here too. On 2026-08-18 a Gradle build was OOM-killed by
`user-mem-guard` twice for the same reason. This is not theoretical.

1. **Default: send it to CI.** The Asus Proxmox runner (`runs-on: [self-hosted, ci]`) has 6 cores,
   9 GB and a warm Gradle cache, and nothing on it competes with production. Push the branch and
   let `.github/workflows/ci.yml` build it.
2. **Never run two Android/Flutter builds at once**, whether in one session or across sessions.
   Check first:
   ```
   pgrep -af 'GradleDaemon|assemble|flutter build' | head
   ```
3. **Never build while a browser session is open.** Playwright/Chromium and Gradle are both
   I/O-hungry; together they saturate the disk queue and freeze everything, including your own
   session's shell.
4. **If a build genuinely has to run here** — `mobile/tools/publish-to-vps.sh` builds the signed
   release APK for the OTA, and that one is legitimate — run it deliberately, one at a time, and
   deprioritise its disk access so the rest of the machine keeps breathing:
   ```
   ionice -c3 nice -n19 ./tools/publish-to-vps.sh "notas del release"
   ```
   That publish takes ~50 minutes. Do not start it and then walk away into other heavy work.

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
