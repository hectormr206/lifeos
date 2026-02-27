# 0. Limpiar

sudo podman rmi -f localhost/lifeos:latest

# 1. Reconstruir la imagen desde cero

sudo podman build --no-cache -t localhost/lifeos:latest -f image/Containerfile .

# 2. Verificar que tiene ID=fedora

podman run --rm localhost/lifeos:latest cat /usr/lib/os-release | grep ^ID=

# 3. Generar ISO

chmod +x scripts/generate-iso-simple.sh && sudo bash scripts/generate-iso-simple.sh --type iso --image localhost/lifeos:latest

# 4. Instalar en VirtualBox y copiar ISO a Windows

cp /ruta/al/output/lifeos-YYYYMMDD.iso /mnt/c/Users/$USER/Downloads/

# Crear VM: Fedora 64-bit, 4GB RAM, 40GB disco, EFI habilitado
# Montar ISO como unidad optica, arrancar e instalar
# Usuario: lifeos / Password: lifeos

# 5. Verificacion post-instalacion

# --- Identidad del sistema ---
cat /etc/os-release
# Debe mostrar: NAME="LifeOS", VARIANT_ID=lifeos, PRETTY_NAME="LifeOS 0.1 Aegis (Fedora 42)"

life --version
# Debe mostrar: life 0.1.0

# --- Servicios core ---
systemctl status lifeosd --no-pager
systemctl status llama-server --no-pager
systemctl status lifeos-security-baseline --no-pager

# --- bootc ---
sudo bootc status
# Debe mostrar el deployment activo con la imagen de LifeOS

# --- AI runtime ---
which llama-server
# Debe mostrar: /usr/bin/llama-server

llama-server --version
# Debe mostrar version de llama.cpp

# --- Health check del daemon ---
# El token tiene permisos 0600 (solo root), necesita sudo para leerlo
TOKEN=$(sudo cat /run/lifeos/bootstrap.token 2>/dev/null)
curl -H "x-bootstrap-token: $TOKEN" http://127.0.0.1:8081/api/v1/health

# --- Red y disco ---
ip addr show
# Usar /var en lugar de / porque composefs (root) siempre reporta 100%
df -h /var

# --- Resumen rapido (todo en un bloque) ---
echo "=== LifeOS Post-Install Check ===" && \
cat /etc/os-release | grep -E "^(NAME|ID|VARIANT|PRETTY)" && \
life --version && \
echo "--- Servicios ---" && \
systemctl is-active lifeosd llama-server lifeos-security-baseline && \
echo "--- bootc ---" && \
sudo bootc status --format=human 2>/dev/null | head -5 && \
echo "--- llama-server ---" && \
which llama-server && llama-server --version 2>&1 | head -1 && \
echo "=== Check completo ==="
