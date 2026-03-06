# Reconstruir imagen y generar artefactos de LifeOS

## Opcion rapida (pipeline completo)

Comando por defecto (genera ISO):

```bash
sudo bash scripts/build-iso.sh
```

Comando para `raw` (tu caso de prueba):

```bash
sudo bash scripts/build-iso.sh --type raw --image localhost/lifeos:latest
```

Esto ejecuta automaticamente los pasos 0-3:

1. Limpia imagen anterior
2. Reconstruye imagen con `--no-cache`
3. Verifica imagen (os-release, llama-server, modelo, CLI, compat docker/podman-compose)
4. Genera artefacto con `bootc-image-builder` (`iso`, `raw`, `qcow2` o `vmdk`)

Log completo del build:

- `output/build-iso.log` (siempre se actualiza como ultimo build)
- `output/build-<type>.log` (log por tipo ejecutado)
- `output/build-raw.log` (tipo `raw`)
- `output/build-qcow2.log` (tipo `qcow2`)
- `output/build-vmdk.log` (tipo `vmdk`)

Nota importante (seguridad de disco en ISO):

- Modo default: `LIFEOS_INSTALL_MODE=interactive`
  Anaconda pide seleccionar disco destino manualmente.
- Modo CI/lab: `LIFEOS_INSTALL_MODE=unattended`
  Puede particionar automaticamente y sobrescribir disco.

## Pasos manuales (si se necesita correr por separado)

```bash
# 0. Limpiar
sudo podman rmi -f localhost/lifeos:latest

# 1. Reconstruir la imagen desde cero
sudo podman build --no-cache -t localhost/lifeos:latest -f image/Containerfile .

# 2. Verificar que tiene ID=fedora
podman run --rm localhost/lifeos:latest cat /usr/lib/os-release | grep ^ID=

# 3. Generar artefacto
chmod +x scripts/generate-iso-simple.sh
sudo bash scripts/generate-iso-simple.sh --type raw --image localhost/lifeos:latest

# Para ISO:
sudo bash scripts/generate-iso-simple.sh --type iso --image localhost/lifeos:latest
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
