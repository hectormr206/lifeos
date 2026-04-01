# Fase AZ — CI Cloud-Native (Release Channels en GitHub Actions)

> **Estado:** CONSECUTIVA — bloqueante para updates automaticos sin self-hosted runner
> **Prioridad:** Alta — sin esto no se generan imagenes OCI nuevas
> **Fecha:** 2026-04-01

---

## Problema

El workflow `Release Channels` fue disenado para correr en self-hosted runner con `podman` y `buildah` pre-instalados. Al migrar a `ubuntu-latest` (runners gratuitos de GitHub), el workflow pasa "success" pero **no construye ni pushea la imagen OCI** porque:

1. El Containerfile usa `podman build` con features especificas de Fedora (dnf, rpm, systemd)
2. El build necesita ~20GB de espacio y acceso a registries de Fedora
3. Cosign/sigstore para firma de imagenes puede requerir configuracion adicional
4. El workflow puede estar skipping el build silenciosamente

## Objetivo

Que `Release Channels` genere y pushee imagenes OCI funcionales a `ghcr.io/hectormr206/lifeos` desde `ubuntu-latest`, sin depender del self-hosted runner.

## Tareas

### AZ.1 — Diagnosticar workflow actual (1 dia)

- [ ] Leer el workflow completo `release-channels.yml` y entender cada step
- [ ] Identificar que pasos dependen de self-hosted (podman version, buildah, disk space)
- [ ] Verificar si el build realmente se ejecuta o se skipea en ubuntu-latest
- [ ] Documentar los pasos que fallan o se skipean

### AZ.2 — Adaptar build para ubuntu-latest (2-3 dias)

- [ ] Instalar podman/buildah en ubuntu-latest via apt (ya vienen pre-instalados en ubuntu-24.04)
- [ ] Verificar espacio en disco (GitHub runners tienen 14GB libres, bootc image necesita mas)
- [ ] Usar `docker/setup-buildx-action` o `podman` nativo segun lo que funcione
- [ ] Probar build del Containerfile completo en CI
- [ ] Resolver dependencias de Fedora repos (dnf, rpm-ostree, bootc)

### AZ.3 — Push a GHCR desde CI (1 dia)

- [ ] Verificar que `GITHUB_TOKEN` tenga permisos `packages: write`
- [ ] Login a ghcr.io con `docker/login-action` o `podman login`
- [ ] Push de imagen con tag edge-YYYYMMDD-SHORTSHA
- [ ] Verificar que el tag aparece en ghcr.io/hectormr206/lifeos

### AZ.4 — Firma con Cosign (1 dia)

- [ ] Instalar cosign en ubuntu-latest (version compatible)
- [ ] Firmar imagen con keyless signing (OIDC + Fulcio)
- [ ] Verificar firma desde el host con `cosign verify`

### AZ.5 — Update del manifest (ya funciona)

- [x] `update-channel-manifest` job ya actualiza `channels/edge.json` correctamente

---

## Alternativa temporal

Mientras AZ no este completo, hay dos formas de actualizar LifeOS:

1. **Build local:** `make build` + copiar binarios + restart daemon
2. **Self-hosted runner:** Encender el runner en la laptop para un push, luego apagar

---

## Metricas de exito

- [ ] `Release Channels` workflow genera imagen OCI en ubuntu-latest
- [ ] Imagen aparece en ghcr.io/hectormr206/lifeos con tag correcto
- [ ] `sudo bootc switch ghcr.io/hectormr206/lifeos:edge-YYYYMMDD-XXXXXXX` funciona sin token
- [ ] Tiempo total de CI < 30 minutos
