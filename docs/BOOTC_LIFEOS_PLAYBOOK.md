# Bootc LifeOS Playbook

## 1. Objetivo

Este documento resume como usar la documentacion oficial de Bootc para construir LifeOS de forma correcta, repetible y segura.

No reemplaza al spec global de LifeOS. Lo complementa con un flujo practico de implementacion para:

- construir imagen OCI de sistema,
- convertirla a ISO/qcow2/raw,
- instalar y validar baseline de seguridad,
- operar updates con cadena de confianza.

SOP operativo por fases: `docs/LIFEOS_PHASE_SOP.md`
Runbook rapido para updates privados en `stable`: `docs/UPDATE_STABLE_PRIVATE_QUICKSTART.md`

## 2. Fuentes oficiales clave

### 2.1 Documentacion y guias

- Fedora Bootc docs: https://fedora-projects.github.io/bootc/
- CentOS SIG Bootc guide (muy detallada): https://sigs.centos.org/automotive/bootc/

### 2.2 Codigo y herramientas

- Proyecto bootc (motor y ejemplos): https://github.com/containers/bootc
- bootc-image-builder (ISO/AMI/qcow2/raw): https://github.com/osbuild/bootc-image-builder

### 2.3 Imagen base oficial

- Fedora bootc base image (Quay): https://quay.io/repository/fedora/fedora-bootc

### 2.4 Material practico adicional

- Fedora Magazine (buscar "bootc"): tutoriales de casos reales y hardware especifico.

## 3. Como leer estas fuentes sin perder tiempo

1. Empezar por Fedora Bootc docs para conceptos base:
   - imagen mode,
   - switch/upgrade/rollback,
   - modelo operativo inmutable.
2. Usar CentOS SIG guide para decisiones de arquitectura:
   - estructura de imagen,
   - capas, estado persistente, servicios,
   - patrones de produccion.
3. Ir al repo `containers/bootc` para ejemplos concretos de implementacion.
4. Usar `bootc-image-builder` para empaquetado final instalable.

## 4. Flujo recomendado para LifeOS

### Paso A: Definir base y capas de sistema

- Base: `FROM quay.io/fedora/fedora-bootc:<tag>`
- Paquetes de sistema en `image/Containerfile`.
- Herramientas CLI base preinstaladas en ISO: `git`, `wget`, `curl`, `jq`.
- Gaming default en ISO: `steam` + `steam-devices` via RPM Fusion (Steam Flatpak solo fallback opcional).
- Servicios y scripts en `image/files/`.
- No usar instaladores ad-hoc post-install como fuente de verdad.

### Paso B: Construir imagen OCI

```bash
podman build -t localhost/lifeos:latest -f image/Containerfile .
```

Validar que al final pase `bootc container lint`.

### Paso C: Generar medio instalable

```bash
# Script completo
./scripts/generate-iso.sh --local -t iso

# Script simplificado
sudo ./scripts/generate-iso-simple.sh --type iso --image localhost/lifeos:latest
```

### Paso D: Instalar y validar baseline

Objetivo de baseline para release:

- UEFI + Secure Boot activo.
- Root cifrado con LUKS2.

En LifeOS esto se valida por servicio:

- `lifeos-security-baseline.service`
- `/usr/local/bin/lifeos-security-baseline-check.sh`

### Paso E: Validar runtime y seguridad

Checks minimos post-install:

```bash
life --version
systemctl status lifeosd llama-server --no-pager
TOKEN=$(cat /run/lifeos/bootstrap.token)
curl -H "x-bootstrap-token: $TOKEN" http://127.0.0.1:8081/api/v1/health
```

Tests de regresion:

```bash
bash tests/security_tests.sh
```

## 5. Mapeo directo con este repositorio

- Imagen base y paquetes: `image/Containerfile`
- Servicios systemd: `image/files/etc/systemd/system/`
- Scripts runtime: `image/files/usr/local/bin/`
- Config default: `image/files/etc/lifeos/`
- Generacion ISO: `scripts/generate-iso.sh`, `scripts/generate-iso-simple.sh`
- Seguridad runtime CI: `tests/security_tests.sh` + `.github/workflows/ci.yml`
- Especificacion global: `docs/lifeos-ai-distribution.md`

## 6. Reglas tecnicas para "hacerlo bien"

1. Mantener `/usr` como capa inmutable; estado mutable en `/etc`, `/var`, `/home`.
2. Hacer que todo componente critico sea declarativo en imagen (no manual post-install).
3. Tratar `Containerfile` como fuente de verdad del sistema base.
4. Enlazar cada claim de seguridad con:
   - control tecnico real,
   - test automatizado,
   - evidencia de build/runtime.
5. Evitar depender de runtime externos no controlados para funciones core.

## 7. Errores comunes a evitar

1. Generar ISO y mover "la primera que aparezca" en `output/`:
   - siempre tomar artefacto exacto de `bootc-image-builder`.
2. Asumir que Secure Boot/LUKS2 estan activos sin comprobar:
   - validar siempre en runtime.
3. Mezclar logica mutable en `/usr/local` sin control de imagen:
   - versionar scripts y units en repo.
4. Tener API local sin auth:
   - forzar bootstrap token en endpoints de control.

## 8. Criterio de "correcto" para LifeOS

Se considera correcto cuando:

1. La imagen OCI builda de forma reproducible.
2. Se puede generar ISO y arrancar en VM/hardware.
3. `lifeosd` y `llama-server` quedan operativos en loopback.
4. Health checks y security baseline reportan estado esperado.
5. Suite de seguridad runtime pasa en local/CI.
6. Roadmap/spec se mantiene sincronizado con el codigo real.
