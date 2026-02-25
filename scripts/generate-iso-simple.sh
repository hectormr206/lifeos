#!/bin/bash
#===============================================================================
# LifeOS ISO Generator - Versión Simplificada para Usuario
#===============================================================================
# Este script genera un ISO usando Docker (no requiere Podman rootful)
# 
# INSTRUCCIONES PARA WINDOWS 11:
# 1. Tener WSL2 instalado: wsl --install (en PowerShell como admin)
# 2. Dentro de WSL2, ejecutar este script
# 3. El ISO se generará en: /home/hectormr/lifeos-iso/
# 4. Copiar el ISO a Windows: cp lifeos.iso /mnt/c/Users/TuUsuario/Downloads/
#===============================================================================

set -e

echo "🚀 LifeOS ISO Generator"
echo "======================="
echo ""

# Configuración
OUTPUT_DIR="$HOME/lifeos-iso"
mkdir -p "$OUTPUT_DIR"

echo "📁 Directorio de salida: $OUTPUT_DIR"
echo ""

# Verificar que la imagen existe
echo "🔍 Verificando imagen Docker..."
if ! docker images | grep -q "lifeos"; then
    echo "❌ Error: No se encontró la imagen 'lifeos:dev'"
    echo ""
    echo "Primero debes construir la imagen:"
    echo "  cd ~/.openclaw/workspace-orchestra/projects/lifeos"
    echo "  docker build -t lifeos:dev -f image/Containerfile image/"
    exit 1
fi

echo "✅ Imagen encontrada"
echo ""

# Método 1: Usar bootc-image-builder con Docker (más fácil)
echo "📦 Método 1: Usando bootc-image-builder con Docker..."
echo ""

# Crear un script temporal para generar el ISO
cat > "$OUTPUT_DIR/generate.sh" << 'INNERSCRIPT'
#!/bin/bash
set -e

# Instalar herramientas necesarias
apt-get update
apt-get install -y podman skopeo

# Configurar registro local
echo "📦 Configurando registro..."
mkdir -p /etc/containers/registries.conf.d/
cat > /etc/containers/registries.conf.d/local.conf << EOF
[[registry]]
location = "localhost:5000"
insecure = true
EOF

# Iniciar registro local
podman run -d -p 5000:5000 --name registry registry:2 || true

# Esperar a que el registro esté listo
sleep 3

# Empujar imagen al registro local
echo "⬆️  Subiendo imagen al registro..."
skopeo copy --insecure-policy --dest-tls-verify=false \
    docker-daemon:lifeos:dev \
    docker://localhost:5000/lifeos:latest

# Generar ISO
echo "💿 Generando ISO..."
mkdir -p /output
podman run --rm --privileged \
    -v /output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type iso \
    --rootfs xfs \
    localhost:5000/lifeos:latest

# Copiar ISO de salida
cp /output/bootiso/*.iso /output/lifeos.iso
echo "✅ ISO generada: /output/lifeos.iso"
INNERSCRIPT

chmod +x "$OUTPUT_DIR/generate.sh"

echo "🐳 Iniciando contenedor de construcción..."
echo ""

# Ejecutar en contenedor con privilegios
docker run --rm --privileged \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$OUTPUT_DIR:/output" \
    -v "$HOME/.openclaw/workspace-orchestra/projects/lifeos/image/files:/lifeos-files:ro" \
    fedora:42 \
    bash /output/generate.sh 2>&1 || {
        echo ""
        echo "⚠️  El método 1 falló. Intentando método alternativo..."
        exit 1
    }

# Copiar resultado final
if [ -f "$OUTPUT_DIR/lifeos.iso" ]; then
    echo ""
    echo "✅ ¡ISO GENERADA EXITOSAMENTE!"
    echo ""
    echo "📁 Ubicación: $OUTPUT_DIR/lifeos.iso"
    ls -lh "$OUTPUT_DIR/lifeos.iso"
    echo ""
    echo "📝 Para copiar a Windows:"
    echo "   cp $OUTPUT_DIR/lifeos.iso /mnt/c/Users/\$USER/Downloads/"
else
    echo "❌ Error: No se generó el archivo ISO"
    exit 1
fi
