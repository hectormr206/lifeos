# LifeOS - Pendientes para V2

## 🎨 Branding (Cambiar Fedora → LifeOS)

### 1. Bootloader (GRUB)
```dockerfile
# En Containerfile
RUN echo 'GRUB_DISTRIBUTOR="LifeOS"' > /etc/default/grub
RUN echo 'GRUB_DISTRIBUTOR="LifeOS"' > /etc/sysconfig/grub
RUN grub2-mkconfig -o /boot/grub2/grub.cfg || true
```
**Efecto:** Cambia "Fedora Linux 42" → "LifeOS" en el menú de arranque

### 2. /etc/os-release
```dockerfile
RUN cat > /etc/os-release << 'EOF'
NAME="LifeOS"
VERSION="0.1.0-alpha"
ID=lifeos
ID_LIKE=fedora
VERSION_ID=0.1.0
PRETTY_NAME="LifeOS 0.1.0-alpha"
ANSI_COLOR="0;34"
LOGO=lifeos-logo-icon
CPE_NAME="cpe:/o:lifeos:lifeos:0.1.0"
HOME_URL="https://lifeos.io"
DOCUMENTATION_URL="https://docs.lifeos.io"
SUPPORT_URL="https://community.lifeos.io"
BUG_REPORT_URL="https://github.com/lifeos/lifeos/issues"
EOF
```

### 3. Logo e Iconos
```dockerfile
# Copiar logos de LifeOS
COPY files/usr/share/pixmaps/lifeos-logo*.png /usr/share/pixmaps/
COPY files/usr/share/icons/lifeos/ /usr/share/icons/lifeos/

# Reemplazar iconos de Fedora
RUN ln -sf /usr/share/pixmaps/lifeos-logo-icon.png /usr/share/pixmaps/fedora-logo-icon.png || true
```

### 4. Wallpapers
```dockerfile
# Crear directorio de wallpapers
RUN mkdir -p /usr/share/backgrounds/lifeos
COPY files/usr/share/backgrounds/lifeos/ /usr/share/backgrounds/lifeos/

# Establecer wallpaper por defecto
RUN ln -sf /usr/share/backgrounds/lifeos/default.jpg /usr/share/backgrounds/gnome/default.jpg || true
```

### 5. Tema Plymouth (Boot Animation)
```dockerfile
# Instalar tema personalizado de boot
COPY files/usr/share/plymouth/themes/lifeos/ /usr/share/plymouth/themes/lifeos/
RUN plymouth-set-default-theme lifeos || true
```

### 6. Anaconda (Instalador Gráfico)
```dockerfile
# Customizar apariencia del instalador
COPY files/usr/share/anaconda/pixmaps/lifeos-*.png /usr/share/anaconda/pixmaps/ || true
COPY files/etc/anaconda/conf.d/lifeos.conf /etc/anaconda/conf.d/lifeos.conf || true
```

---

## 🌍 Soporte de Idiomas

### Problema Actual
El wizard de bienvenida de GNOME muestra "No languages found" al buscar "spanish"

### Solución
```dockerfile
# En Containerfile, agregar paquetes de idiomas
RUN dnf -y install \
    glibc-langpack-es \
    glibc-langpack-en \
    langpacks-es \
    langpacks-en \
    gnome-getting-started-docs-es \
    gnome-user-docs-es \
    && dnf clean all
```

### Idiomas a Soportar
- ✅ Español (es)
- ✅ Inglés (en)
- ✅ Portugués (pt)
- Francés (fr) - Opcional
- Alemán (de) - Opcional

### Configuración Regional
```dockerfile
# Configurar locales
RUN echo 'LANG=es_MX.UTF-8' > /etc/locale.conf || true
RUN echo 'KEYMAP=es' > /etc/vconsole.conf || true
```

---

## 📁 Archivos Necesarios

### Crear estructura:
```
image/files/
├── usr/share/pixmaps/
│   ├── lifeos-logo-icon.png
│   ├── lifeos-logo-small.png
│   └── lifeos-logo-large.png
├── usr/share/backgrounds/lifeos/
│   ├── default.jpg
│   ├── dark.jpg
│   └── light.jpg
├── usr/share/icons/lifeos/
│   └── ... iconos del tema
├── usr/share/plymouth/themes/lifeos/
│   └── ... tema de boot
└── etc/anaconda/conf.d/
    └── lifeos.conf
```

---

## 🎯 Prioridades

### Para V2 (Inmediato):
1. ✅ CLI funcional (en progreso)
2. 🎨 Branding básico (os-release, logos)
3. 🌍 Idiomas (español, inglés)

### Para V3 (Futuro):
- Tema Plymouth completo
- Anaconda customizado
- Wallpapers personalizados
- Más idiomas

---

## 📝 Notas

- Los cambios de branding deben hacerse ANTES de generar la ISO
- Probar en VM antes de distribuir
- Mantener compatibilidad con Fedora para updates
- Documentar cambios para futuros mantenedores

---

*Creado: 2026-02-25*
*Para implementar después de que el CLI funcione correctamente*
