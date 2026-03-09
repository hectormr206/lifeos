# LifeOS Updates (Stable + GHCR privado)

Guia corta para actualizar una laptop principal con LifeOS instalado via ISO, usando solo el canal `stable`.

## 1) Idea base (en 10 segundos)

- La ISO sirve para instalar.
- Las actualizaciones llegan desde GHCR (`ghcr.io`).
- La laptop principal debe apuntar a: `ghcr.io/hectormr206/lifeos:stable`.
- Tu VM de VirtualBox es el filtro antes de promover a `stable`.

## 2) Flujo operativo recomendado

### Paso A - Validar en VM

1. Construye y prueba cambios de la fase (ej. 2.5) en VirtualBox.
2. Si todo pasa, promueves esa version a `stable`.

### Paso B - Publicar `stable` en GitHub/GHCR

Forma formal (recomendada): tag semantico.

```bash
git checkout main
git pull --ff-only
git tag v0.2.5
git push origin v0.2.5
```

Esto dispara `release-channels.yml` y publica/mueve la etiqueta `stable`.

## 3) Preparar laptop principal (solo primera vez)

GHCR privado requiere autenticacion.

1. Crea un GitHub PAT con al menos `read:packages`.
2. Configura credenciales persistentes (recomendado para evitar reingresarlas y para sesiones Codex):

```bash
./scripts/setup-gh-credentials.sh --user hectormr206 --gh-login --podman-login
```

Esto crea:
- `~/.config/lifeos/gh.env` (permisos `600`)
- `/tmp/lifeos-gh.env` (enlace para sesiones de automatizacion/Codex)

3. En la laptop LifeOS (alternativa manual):

```bash
sudo podman login ghcr.io -u hectormr206
```

4. Verifica que la imagen existe y es accesible:

```bash
sudo podman pull ghcr.io/hectormr206/lifeos:stable
```

Si `podman login` dice `Login Succeeded` pero `podman pull` falla con
`reading manifest ... denied`, el token no tiene permisos efectivos sobre paquetes GHCR.
Valida con (debe devolver `200`):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -u "$GH_USER:$GH_TOKEN" \
  -H 'Accept: application/vnd.oci.image.index.v1+json' \
  https://ghcr.io/v2/hectormr206/lifeos/manifests/stable
```

Si devuelve `401/403`, crea un nuevo PAT con:
- Classic token: `read:packages` (y `repo` si aplica package privado/repo-scoped).
- Fine-grained token: `Packages: Read` sobre el owner/repositorio correcto.

5. Conecta el sistema al stream `stable` (una sola vez):

```bash
sudo bootc switch ghcr.io/hectormr206/lifeos:stable
sudo reboot
```

Alternativa robusta (recomendada) con script:

```bash
sudo ./scripts/update-lifeos.sh --channel stable --switch --yes
sudo reboot
```

## 4) Actualizar en cada release estable

Cuando publiques un nuevo `stable`, en la laptop:

```bash
sudo bootc upgrade --check
sudo bootc upgrade --apply
sudo reboot
```

Alternativa robusta (incluye pull con fallback `skopeo` si `podman pull` se cuelga):

```bash
sudo ./scripts/update-lifeos.sh --channel stable --apply --yes
sudo reboot
```

## 5) Rollback rapido si algo falla

```bash
sudo bootc rollback
sudo reboot
```

## 8) Script operativo recomendado

Se agrega `scripts/update-lifeos.sh` para encapsular el flujo seguro de update:

- Pull normal con `podman` + timeout.
- Fallback automatico: `skopeo copy -> docker-archive -> podman load`.
- `bootc switch` opcional para apuntar al stream.
- Fallback automatico de `bootc switch` a `--transport containers-storage` cuando hay imagen local.
- `bootc upgrade --check` y `--apply` opcional.
- Logging continuo + snapshot de diagnostico automatico en errores.

Ejemplos:

```bash
# Solo preparar imagen + check de update
sudo ./scripts/update-lifeos.sh --channel stable

# Switch de stream (primera vez) + apply de update
sudo ./scripts/update-lifeos.sh --channel stable --switch --apply --yes

# En caso extremo: resetear storage de podman antes del pull (destructivo)
sudo ./scripts/update-lifeos.sh --channel stable --reset-storage --apply

# Log personalizado (por ejemplo para adjuntar a soporte)
sudo ./scripts/update-lifeos.sh --channel stable --apply --log-file /var/tmp/lifeos-update.log
```

Logs por defecto:
- `/var/log/lifeos/update-lifeos-YYYYMMDD-HHMMSS.log`
- Fallback: `/var/tmp/update-lifeos-YYYYMMDD-HHMMSS.log`

## 6) Checklist rapido de verificacion

```bash
bootc status
life status
systemctl status lifeosd --no-pager
```

## 7) Notas importantes para la fase actual

- No necesitas `candidate` ni `edge` para operar tu laptop principal.
- Puedes seguir usando `main` como rama unica.
- Por ahora, para updates reales usa `bootc` directo.
  - El parametro `--channel` de `life update` aun no controla completamente el origen de imagen.
