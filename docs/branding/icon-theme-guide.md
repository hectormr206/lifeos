# LifeOS Icon Theme — Contributor Guide

## Overview

The LifeOS icon theme contains **324 full-color + 324 symbolic SVGs** across 8 freedesktop contexts, plus 9 Axi state icons. All icons are brand-compliant.

## Icon Color Palette (MANDATORY)

**REGLA CRITICA:** Los iconos se ven sobre un fondo oscuro (#0F0F1B). NUNCA usar colores que se confundan con el fondo.

| Color | Hex | Uso en iconos | NOTA |
|-------|-----|--------------|------|
| **Icon Body** | `#2A2A3E` | Cuerpo principal del icono (rectangulos, circulos) | **OBLIGATORIO para bodies** |
| **Folder Body** | `#222338` | Cuerpo de carpetas (ligeramente diferente para profundidad) | Solo para places/folder* |
| **Teal Axi** | `#00D4AA` | Acentos, elementos activos, tabs de carpetas | Acento principal |
| **Rosa Axi** | `#FF6B9D` | Errores, destructivo, close buttons | Solo para alertas/cierre |
| **Amarillo Alerta** | `#F0C420` | Warnings, precaucion | Solo para estados de alerta |
| **Verde Success** | `#2ECC71` | Exito, confirmacion positiva | Solo para estados positivos |
| **Azul LifeOS** | `#3282B8` | Info, links, acento secundario | Solo para info/links |
| **Blanco Suave** | `#E8E8E8` | Texto dentro de iconos, symbolic variants | Para texto y lineas finas |
| **Noche Profunda** | `#0F0F1B` | SOLO para el logo de LifeOS (gradiente) | NUNCA para iconos normales |

### ERRORES COMUNES (NUNCA HACER):

1. **NUNCA usar `#161830` como body de iconos** — es el mismo color que el fondo del escritorio. Los iconos se vuelven INVISIBLES. Usar `#2A2A3E` en su lugar.
2. **NUNCA usar `#0F0F1B` como body** — mismo problema, peor aun.
3. **NUNCA agregar `width="512" height="512"` al tag `<svg>`** — COSMIC no escala correctamente. Solo usar `viewBox`.
4. **NUNCA hacer dos iconos identicos** — cada icono debe ser visualmente distinguible. Verificar pares (reboot≠shutdown, maximize≠minimize, etc.)

## SVG Format

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <!-- SOLO viewBox, NUNCA width/height en el tag svg -->
  <!-- icon content here -->
</svg>
```

- **ViewBox:** Always `0 0 512 512`
- **No width/height attributes** (let the toolkit scale)
- **Flat design:** No shadows, no gradients, no 3D effects
- **Rounded corners:** Use `rx="8"` to `rx="24"` for consistency
- **Two-tone:** Dark background (#161830) + teal/colored foreground (#00D4AA)
- **Transparent background:** The SVG itself has no background — the icon bg is part of the design

## Design Style

Icons follow a minimalist flat style:

1. **Primary shape** in `#161830` (Medianoche) as the icon "body"
2. **Accent elements** in `#00D4AA` (Teal Axi) for visual interest
3. **Opacity variations** (0.3-0.8) for depth without additional colors
4. **Simple geometry:** rectangles, circles, paths — avoid complex bezier curves

### Example: A simple action icon

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <circle cx="256" cy="256" r="200" fill="#161830"/>
  <path d="M200 160 L380 256 L200 352 Z" fill="#00D4AA"/>
</svg>
```

## File Structure

```
image/files/usr/share/icons/LifeOS/
├── index.theme           # Theme metadata
├── axi/svg/              # Axi mascot state icons
├── scalable/
│   ├── actions/          # 85 icons (toolbar, menu actions)
│   │   ├── edit-copy.svg
│   │   ├── edit-copy-symbolic.svg    # Monochrome variant
│   │   └── ...
│   ├── apps/             # 62 icons (application launchers)
│   ├── categories/       # 15 icons (app categories)
│   ├── devices/          # 22 icons (hardware)
│   ├── emblems/          # 13 icons (file decorations)
│   ├── mimetypes/        # 36 icons (file types)
│   ├── places/           # 21 icons (folders, locations)
│   └── status/           # 63 icons (system state indicators)
```

## Symbolic Variants

Every icon has a `-symbolic.svg` variant that is monochrome `#E8E8E8`. GTK/libcosmic automatically recolors these based on the active theme (dark/light).

Symbolic icons are generated automatically from full-color icons by replacing all fill/stroke colors with `#E8E8E8`.

To regenerate: `bash scripts/generate-symbolic-icons.sh`

## Adding a New Icon

1. Create the SVG in the correct context directory
2. Use ONLY brand palette colors
3. Run `bash scripts/generate-symbolic-icons.sh` to create the symbolic variant
4. Run `bash scripts/test-icon-completeness.sh` to verify
5. If adding a new context directory, update `index.theme`

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/generate-missing-icons.sh` | Generate batch of icons (first run) |
| `scripts/generate-remaining-icons.sh` | Generate additional icons (second run) |
| `scripts/generate-final-icons.sh` | Generate final remaining icons |
| `scripts/generate-symbolic-icons.sh` | Generate symbolic variants from full-color |
| `scripts/rasterize-icons.sh` | Generate PNG variants (requires rsvg-convert) |
| `scripts/test-icon-completeness.sh` | Verify critical icon coverage |

## Naming Convention

Follow the [freedesktop Icon Naming Specification](https://specifications.freedesktop.org/icon-naming-spec/latest/):

- Use lowercase with hyphens: `document-new`, not `DocumentNew`
- Symbolic variants: append `-symbolic`: `document-new-symbolic.svg`
- App icons match the `.desktop` file `Icon=` field

## Theme Inheritance

```
LifeOS → Adwaita → hicolor
```

Any icon not found in LifeOS falls back to Adwaita, then hicolor. This is standard freedesktop behavior.
