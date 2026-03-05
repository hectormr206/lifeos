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
2. En la laptop LifeOS:

```bash
sudo podman login ghcr.io -u hectormr206
```

3. Verifica que la imagen existe y es accesible:

```bash
sudo podman pull ghcr.io/hectormr206/lifeos:stable
```

4. Conecta el sistema al stream `stable` (una sola vez):

```bash
sudo bootc switch ghcr.io/hectormr206/lifeos:stable
sudo reboot
```

## 4) Actualizar en cada release estable

Cuando publiques un nuevo `stable`, en la laptop:

```bash
sudo bootc upgrade --check
sudo bootc upgrade --apply
sudo reboot
```

## 5) Rollback rapido si algo falla

```bash
sudo bootc rollback
sudo reboot
```

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
