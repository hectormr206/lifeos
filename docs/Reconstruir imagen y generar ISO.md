# Reconstruir imagen y generar ISO de LifeOS

## Opcion rapida (un solo comando)

sudo bash scripts/build-iso.sh

# Esto ejecuta automaticamente los pasos 0-3:
#   0. Limpia imagen anterior
#   1. Reconstruye imagen con --no-cache
#   2. Verifica imagen (os-release, llama-server, modelo, CLI)
#   3. Genera ISO con bootc-image-builder

## Pasos manuales (si se necesita correr por separado)

# 0. Limpiar
sudo podman rmi -f localhost/lifeos:latest

# 1. Reconstruir la imagen desde cero
sudo podman build --no-cache -t localhost/lifeos:latest -f image/Containerfile .

# 2. Verificar que tiene ID=fedora
podman run --rm localhost/lifeos:latest cat /usr/lib/os-release | grep ^ID=

# 3. Generar ISO
chmod +x scripts/generate-iso-simple.sh && sudo bash scripts/generate-iso-simple.sh --type iso --image localhost/lifeos:latest

## Instalar en VirtualBox

# Crear VM: Fedora 64-bit, 4GB RAM, 40GB disco, EFI habilitado
# Montar ISO como unidad optica, arrancar e instalar
# Usuario: lifeos / Password: lifeos

## Verificacion post-instalacion (un solo comando)

sudo life check

# Esto ejecuta lifeos-check que verifica:
#   - Identidad (os-release, life CLI, VARIANT_ID)
#   - Servicios (lifeosd, llama-server, lifeos-security-baseline)
#   - AI Runtime (binary, version, modelo pre-instalado, API)
#   - bootc (imagen booteada)
#   - Daemon (bootstrap token, health API)
#   - Disco (/var usage)
#   - Red (IP asignada)
#
# Tambien se puede correr directamente:
#   sudo lifeos-check
