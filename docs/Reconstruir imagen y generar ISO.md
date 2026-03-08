# Reconstruir imagen y generar artefactos de LifeOS

## Opcion rapida (pipeline completo)

Comando por defecto (genera ISO):

```bash
sudo bash scripts/build-iso.sh
```

ISO sin modelo prebundled (recomendado para iteracion rapida):

```bash
sudo bash scripts/build-iso-without-model.sh
```

ISO con modelo prebundled (imagen mas pesada):

```bash
sudo bash scripts/build-iso-with-model.sh
```

Comando para `raw` (tu caso de prueba):

```bash
sudo bash scripts/build-iso.sh --type raw --image localhost/lifeos:latest
```

Esto ejecuta automaticamente los pasos 0-3:

1. Limpia imagen anterior
2. Reconstruye imagen con `--no-cache`
3. Verifica imagen (os-release, llama-server, CLI, compat docker/podman-compose; modelo si esta pre-cargado)
4. Genera artefacto con `bootc-image-builder` (`iso`, `raw`, `qcow2` o `vmdk`)

Log completo del build:

- `output/build-iso.log` (siempre se actualiza como ultimo build)
- `output/build-<type>.log` (log por tipo ejecutado)
- `output/build-raw.log` (tipo `raw`)
- `output/build-qcow2.log` (tipo `qcow2`)
- `output/build-vmdk.log` (tipo `vmdk`)

Al finalizar cada build del pipeline completo (`build-iso*.sh`), comparte esto para revision rapida:

```bash
tail -n 250 output/build-iso.log
```

Filtro rapido de errores/warnings:

```bash
rg -n "ERROR|\\[ERROR\\]|\\[!\\]|failed|FATAL" output/build-*.log
```

Con esos dos comandos podemos validar si quedo correcto o donde ajustar.

## Iteracion realmente rapida (sin reconstruir toda la imagen)

Si no cambiaste `image/Containerfile` ni paquetes base, usa la imagen ya construida y solo genera el artefacto:

```bash
sudo bash scripts/generate-iso-simple.sh --type iso --image localhost/lifeos:latest
```

Regla practica:

- Cambios en sistema base (Containerfile, paquetes, servicios base): usa `build-iso*.sh` (pipeline completo).
- Cambios de empaquetado/artefacto o solo necesitas nueva ISO del mismo `localhost/lifeos:latest`: usa `generate-iso-simple.sh`.

Importante para logs en iteracion rapida:

- `generate-iso-simple.sh` no escribe `output/build-iso.log` por si solo.
- Para no confundirte con logs viejos, ejecutalo con `tee`:

```bash
sudo bash scripts/generate-iso-simple.sh --type iso --image localhost/lifeos:latest 2>&1 | tee output/generate-iso.log
```

- Revision rapida despues de iteracion rapida:

```bash
tail -n 250 output/generate-iso.log
rg -n "ERROR|\\[ERROR\\]|\\[!\\]|failed|FATAL" output/generate-iso.log
```

Nota importante (seguridad de disco en ISO):

- Modo default: `LIFEOS_INSTALL_MODE=interactive`
  Anaconda pide seleccionar disco destino manualmente.
- Modo CI/lab: `LIFEOS_INSTALL_MODE=unattended`
  Puede particionar automaticamente y sobrescribir disco.

Nota importante (tamano de imagen/modelo):

- Default: `LIFEOS_PRELOAD_MODEL=false` (build mas ligero)
- Con modelo: `LIFEOS_PRELOAD_MODEL=true` (descarga varios GB adicionales)

## Pasos manuales (si se necesita correr por separado)

```bash
# 0. Limpiar
sudo podman rmi -f localhost/lifeos:latest

# 1A. Reconstruir la imagen desde cero (sin modelo, recomendado)
sudo podman build --no-cache --build-arg LIFEOS_PRELOAD_MODEL=false -t localhost/lifeos:latest -f image/Containerfile .

# 1B. Reconstruir la imagen desde cero (con modelo prebundled)
sudo podman build --no-cache --build-arg LIFEOS_PRELOAD_MODEL=true -t localhost/lifeos:with-model -f image/Containerfile .

# 2. Verificar que tiene ID=fedora
podman run --rm localhost/lifeos:latest cat /usr/lib/os-release | grep ^ID=

# 3. Generar artefacto
chmod +x scripts/generate-iso-simple.sh
sudo bash scripts/generate-iso-simple.sh --type raw --image localhost/lifeos:latest

# Para ISO:
sudo bash scripts/generate-iso-simple.sh --type iso --image localhost/lifeos:latest
```

## Actualizar LifeOS instalado (robusto + logs)

Para equipos ya instalados (no para construir ISO), usar el flujo robusto:

```bash
# Canal stable + apply update
sudo ./scripts/update-lifeos.sh --channel stable --apply --yes
```

Con log personalizado para soporte:

```bash
sudo ./scripts/update-lifeos.sh --channel stable --apply --log-file /var/tmp/lifeos-update.log
```

## Instalar en VirtualBox (si usas ISO)

- Crear VM: Fedora 64-bit, 4GB RAM, 40GB disco, EFI habilitado
- Montar ISO como unidad optica
- Arrancar y en Anaconda seleccionar disco destino
- Usuario: `lifeos` / Password: `lifeos`

## Verificacion post-instalacion

```bash
sudo life check
```

Tambien se puede correr directamente:

```bash
sudo lifeos-check
```
