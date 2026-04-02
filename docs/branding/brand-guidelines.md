# LifeOS & Axi — Brand Guidelines

Guia oficial de identidad visual para **LifeOS** y su asistente **Axi, el Ajolote tecnologico**.
Todo elemento visual de LifeOS debe seguir estas reglas.

**Version:** 2.0.0
**Updated:** 2026-03-26
**Author:** Hector Martinez — [hectormr.com](https://hectormr.com)
**Status:** Official

---

## 1. Paleta de Colores

### Colores Primarios

| Color | Hex | RGBA (0-1) | Uso |
|-------|-----|------------|-----|
| **Teal Axi** | `#00D4AA` | (0.0, 0.831, 0.667, 1.0) | Accent principal. Botones, links, selecciones, bordes activos, cursor, iconos activos |
| **Rosa Axi** | `#FF6B9D` | (1.0, 0.420, 0.612, 1.0) | Accent secundario. Branquias de Axi, errores, destructivo, notificaciones urgentes |
| **Noche Profunda** | `#0F0F1B` | (0.059, 0.059, 0.106, 1.0) | Background principal dark mode. Fondos de ventanas |
| **Medianoche** | `#161830` | (0.086, 0.094, 0.188, 1.0) | Surface/container. Paneles, cards, menus |
| **Blanco Suave** | `#E8E8E8` | (0.910, 0.910, 0.910, 1.0) | Texto principal. Legible sin cansar la vista |

### Colores Secundarios

| Color | Hex | Uso |
|-------|-----|-----|
| **Azul LifeOS** | `#3282B8` | Links, acentos frios, complementario |
| **Purpura Profundo** | `#5E26CC` | Modo nocturno, premium features |
| **Amarillo Alerta** | `#F0C420` | Warnings, precauciones |
| **Naranja Energia** | `#E67E22` | Alertas medias, energia |

### Colores Semanticos

| Token | Color | Uso |
|-------|-------|-----|
| **accent** | `#00D4AA` | Teal Axi — SIEMPRE el accent |
| **success** | `#00D4AA` | Mismo que accent (teal = positivo) |
| **warning** | `#F0C420` | Amarillo |
| **destructive** | `#FF6B9D` | Rosa Axi |
| **info** | `#3282B8` | Azul LifeOS |

### Neutrals (escala de grises con tinte teal)

| Step | Hex | Uso |
|------|-----|-----|
| neutral_0 | `#0D0D17` | Fondo mas oscuro |
| neutral_1 | `#12121F` | Surfaces profundas |
| neutral_2 | `#1A1A2E` | Surfaces |
| neutral_3 | `#222338` | Borders |
| neutral_4 | `#2D2F45` | Borders activos |
| neutral_5 | `#383A52` | Texto deshabilitado |
| neutral_6 | `#4A4C61` | Placeholders |
| neutral_7 | `#5E6078` | Texto secundario |
| neutral_8 | `#737587` | Texto muted |
| neutral_9 | `#8C8E9E` | Labels |
| neutral_10 | `#A8AAB7` | Texto claro sobre oscuro |

---

## 2. Tipografia

### Fuente del Sistema (UI)
- **Primaria:** Inter (SIL Open Font License)
- **Fallback:** Noto Sans, sans-serif
- **Peso base:** Regular (400) para cuerpo, Medium (500) para labels, SemiBold (600) para titulos

### Fuente Monospace (Terminal, Codigo)
- **Primaria:** JetBrains Mono (Apache 2.0)
- **Fallback:** Noto Sans Mono, monospace
- **Ligatures:** Habilitadas por defecto

### Reglas
- Tamano minimo: 12px para UI, 10px para labels pequenos
- Line height: 1.5 para texto largo, 1.2 para UI compacta
- NO usar fuentes decorativas, script, o serif en la UI del sistema

---

## 3. Axi — El Ajolote Tecnologico

Documento complementario:

- Ver `docs/branding/axi-visual-system.md` para la estrategia oficial de Axi como simbolo central, wallpapers canonicos y coleccion regional.

### Personalidad
- **Amigable** — no intimidante, accesible para todos
- **Inteligente** — sutil, no pretencioso
- **Protector** — cuida la privacidad y seguridad del usuario

### Proporciones del Personaje

```
     ╭──────────────╮
     │  Cabeza 30%   │  Ojos expresivos, sonrisa
     │   ◕   ◕      │
     ╰──────────────╯
     ╭──────────────╮
     │  Branquias 20%│  3 pares, Rosa Axi (#FF6B9D)
     │  ╰┬╯ ╰┬╯ ╰┬╯ │
     ╰──────────────╯
     ╭──────────────╮
     │  Cuerpo 40%   │  Teal Axi (#00D4AA), redondeado
     ╰──────────────╯
     ╭──────────────╮
     │  Cola 10%     │  Aletada, expresiva
     ╰──────────────╯
```

### Estados de Axi (para tray icon y overlay)

| Estado | Color del orbe | Label |
|--------|---------------|-------|
| Idle | Verde `#2ED673` | En espera |
| Listening | Cyan `#00D1D4` | Escuchando |
| Thinking | Amber `#FFA603` | Pensando |
| Speaking | Blue `#3842FA` | Hablando |
| Watching | Teal `#1ABD9C` | Observando |
| Error | Red `#FF4757` | Atencion |
| Offline | Gray `#646E73` | Desconectado |
| Night | Indigo `#5E26CC` | Modo nocturno |

---

## 4. Estilo Visual del Desktop

### COSMIC Theme (lifeos-dark.ron)
- **Frosted glass:** Habilitado (blur en paneles y dock)
- **Corner radius:** 12px en elementos medianos, 4px en pequenos
- **Gaps entre ventanas:** 4px
- **Active hint:** 2px borde teal en ventana activa
- **Window hint color:** Teal Axi (#00D4AA)

### Panel Superior
- **Opacity:** 85% (frosted glass)
- **Floating:** Si (no pegado a bordes)
- **Border radius:** 12px
- **Spacing:** 4px entre applets

### Dock Inferior
- **Opacity:** 75% (mas transparente que panel)
- **Floating:** Si
- **Auto-hide:** Si (1 segundo de espera)
- **Size:** L (no XL)
- **Border radius:** 160px (pill shape)

---

## 5. Wallpapers

Todas las variantes deben seguir estos principios:
- **Dark mode first** — fondos oscuros con acentos teal/rosa sutiles
- **Minimalismo** — sin elementos ruidosos o distractores
- **Reconocible** — un usuario debe poder identificar que es LifeOS
- **4K minimo** — 3840x2160
- **Sin texto** — el wallpaper no debe tener texto visible

### Variantes requeridas
1. **Default (Axi Xochimilco / canonico):** Ajolote reconocible, elegante y dark-first, con atmosfera acuática y lenguaje visual LifeOS
2. **Minimal:** Casi negro con un unico glow teal sutil
3. **Nature:** Aurora boreal abstracta con paleta LifeOS
4. **Light:** Fondo claro con acentos teal y rosa suaves
5. **Lock Screen:** Orbe teal central con anillos, elegante
6. **Greeter:** Similar a lock screen pero mas oscuro

Regla adicional:

- los wallpapers oficiales deben seguir `docs/branding/axi-visual-system.md`
- el wallpaper default debe reforzar que el ajolote es el motivo central de LifeOS
- las variantes regionales deben empezar por estados; las ciudades quedan para ediciones especiales

---

## 6. Iconos

### Estilo de Iconos
- **Flat design** — sin sombras, sin 3D
- **Rounded corners** — consistente con corner_radii del tema
- **Two-tone:** Base neutral oscura + accent teal/rosa
- **512x512 PNG** o SVG vectorial
- **Background transparente**

### Iconos necesarios (custom LifeOS)
- Carpeta (teal tab)
- Terminal (cursor teal)
- Settings (gear con accent teal)
- Axi (mascota, para tray y launcher)
- LifeOS logo (para about screen)

---

## 7. Reglas de Uso

### HACER
- Usar Teal Axi (#00D4AA) como accent principal en TODA la UI
- Mantener fondos oscuros (#0F0F1B) para dark mode
- Usar Rosa Axi (#FF6B9D) solo para errores/destructivo/branquias de Axi
- Mantener contraste WCAG AA minimo (4.5:1 para texto)

### NO HACER
- No usar azul System76 (#62a0ea) — ese es el default de COSMIC, no de LifeOS
- No usar fondos blancos puros (#FFFFFF) en dark mode
- No mezclar la paleta LifeOS con colores arbitrarios
- No poner texto sobre wallpapers sin overlay de contraste
- No cambiar las proporciones de Axi
- No usar Axi en contextos que contradigan su personalidad (violencia, adulto)

---

## 8. Archivos de Referencia

| Archivo | Ubicacion |
|---------|-----------|
| Tema COSMIC dark | `/usr/share/lifeos/themes/lifeos-dark.ron` |
| Tema terminal | `/usr/share/lifeos/themes/lifeos-terminal.ron` |
| Wallpapers | `/usr/share/backgrounds/lifeos/` |
| Iconos Axi (SVG) | `/usr/share/icons/LifeOS/axi/svg/` |
| Logo LifeOS (SVG) | `/usr/share/icons/LifeOS/scalable/apps/lifeos.svg` |
| Plymouth theme | `/usr/share/plymouth/themes/lifeos/` |
| Sound theme | `/usr/share/sounds/lifeos/` |

---

## Reglas Criticas para Iconos (NUNCA VIOLAR)

Estas reglas existen porque cometimos errores que causaron iconos invisibles en el escritorio.

### 1. Color de body de iconos: SIEMPRE `#2A2A3E`

El fondo del escritorio LifeOS es `#0F0F1B` (Noche Profunda). Si el body del icono usa `#161830` (Medianoche), el icono se vuelve **INVISIBLE** — se pierde completamente contra el fondo.

| Correcto | Incorrecto |
|----------|-----------|
| `fill="#2A2A3E"` (visible) | `fill="#161830"` (invisible) |
| `fill="#222338"` (carpetas) | `fill="#0F0F1B"` (peor) |

### 2. NUNCA `width`/`height` en el tag `<svg>`

COSMIC Desktop no escala correctamente los iconos con dimensiones fijas. Solo usar `viewBox`:

```xml
<!-- CORRECTO -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">

<!-- INCORRECTO — no hacer esto -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
```

### 3. Iconos de pares DEBEN ser visualmente distintos

Estos pares fueron verificados. Si se modifica uno, verificar que siga siendo diferente del otro:

- `system-reboot` (flecha circular) ≠ `system-shutdown` (boton de poder)
- `window-maximize` (cuadrado) ≠ `window-minimize` (linea) ≠ `window-restore` (cuadrados superpuestos)
- `window-close` = X rosa (#FF6B9D), NUNCA un cuadrado
- `go-next` (flecha derecha) ≠ `go-previous` (flecha izquierda)
- `audio-volume-high` ≠ `audio-volume-muted`
- `battery-full` ≠ `battery-empty` ≠ `battery-charging`

### 4. Guia completa de iconos

Ver `docs/branding/icon-theme-guide.md` para la referencia completa de colores, formato, y proceso.
