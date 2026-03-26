# Axi Brand Guidelines

Este documento defines the visual identity system for **Axi, el Ajolote tecnológico**.

**Version:** 1.1.0
**Last Updated:** 2026-03-26
**Status:** Official
**Author:** Héctor Martínez — [hectormr.com](https://hectormr.com)

## Color Palette

### Brand Colors (Paleta Oficial)

| Color              | Hex       | Uso                                    |
| ------------------ | --------- | -------------------------------------- |
| **Rosa Axi**       | `#FF6B9D` | Color base, branquias, acentos cálidos |
| **Verde Regeneración** | `#00D4AA` | Brillos, efectos de recovery, success  |
| **Azul LifeOS**    | `#3282B8` | Acentos, complementario, links         |
| **Púrpura Profundo**   | `#1A1A2E` | Fondos, contornos, neutral dark        |
| **Blanco Hueso**   | `#E8E8E8` | Detalles, ojos, texto claro            |

### Semantic Colors

| Token     | Dark Theme | Usage                           |
| --------- | ---------- | ------------------------------- |
| **primary**   | `#0f4c75`  | Primary actions, focus rings    |
| **secondary** | `#3282b8`  | Secondary actions, accents      |
| **success**   | `#00D4AA`  | Success states, confirmations   |
| **warning**   | `#e67e22`  | Warning states, alerts          |
| **error**     | `#e74c3c`  | Error states, destructive       |
| **neutral**   | `#1a1a2e`  | Dark background, surfaces       |
| **highlight** | `#f1c40d`  | Yellow glow, emphasis           |

## Character Proportions

Axi sigue proporciones específicas para mantener consistencia visual en todos los formatos:

```
     ╭─────────────────────────────╮
     │         Cabeza (30%)         │ ← Ojos expresivos, sonrisa
     │      ◕ ◕    ◕ ◕             │
     ╰─────────────────────────────╯
     ╭─────────────────────────────╮
     │   Branquias (20%)            │ ← 3 pares, estilo antenas
     │   ╰┬─┬╯  ╰┬─┬╯  ╰┬─┬╯       │
     ╰─────────────────────────────╯
     ╭─────────────────────────────╮
     │      Cuerpo (40%)            │ ← Redondeado, tierno
     │      ╭───────────────╮       │
     │      │   │││││││││   │       │
     │      ╰───────────────╯       │
     ╰─────────────────────────────╯
     ╭─────────────────────────────╮
     │      Cola (10%)              │ ← Aletada, expresiva
     │         ~~~~~~~               │
     ╰─────────────────────────────╯
```

| Sección    | Proporción | Elementos Clave                          |
| ---------- | ---------- | ---------------------------------------- |
| **Cabeza** | 30%        | Ojos expresivos, sonrisa, expresiones    |
| **Branquias** | 20%     | 3 pares de branquias externas, estilo antenas |
| **Cuerpo** | 40%        | Forma redondeada, tierna, patas pequeñas |
| **Cola**   | 10%        | Aleta semi-transparente, expresiva       |

## Typography
- **Font family**: Rounded, friendly, sans serifs
- **Logo font**: Bold, geometric sans serifs
- **Body font**: Clean sans serifs

## Character Design
- **Style**: Cute but expressive, slightly cartoonish
- **Personality**: Helpful, curious, slightly mischievous but always well-intentioned
- **Age**: Timeless (can be baby or adult depending on context)
- **Signature elements**:
  - Six external gills (feathery, pink/coral)
  - Permanent smile
  - Large expressive eyes
  - Small legs and semi-transparent tail fin

## Animation Guidelines
- **Idle**: Gentle bobbing (subtle breathing)
- **Happy**: Tail wag, eyes sparkle
- **Working**: Focused expression, tools appear
- **Regenerating**: Green glow pulses through body
- **Error**: Sad expression, console appears

## Art Style Guidelines

### Line Style
- **Líneas:** Redondeadas, sin esquinas agresivas
- **Grosor:** Consistente, 2-3px en SVG base
- **Suavidad:** Curvas Bezier, evitar líneas rectas

### Color Application
- **Simplificación:** Máximo 3 colores por variante
- **Paleta:** Usar siempre colores oficiales de la tabla anterior
- **Gradientes:** Solo para efectos especiales (regeneración, brillos)

### Expressions
- **Minimalistas pero claras:**
  - Happy: ◕ ◕ (ojos abiertos, sonrisa)
  - Neutral: ◕ ◡ (ojos normales, boca relajada)
  - Worried: ◕︵◕ (ojos preocupados, posible lágrima estilizada)
  - Focused: ◕ ◕ (ojos concentrados, cejas ligeramente fruncidas)
  - Sleeping: - - (ojos cerrados, boca relajada)

### Scalability
- **Reconocibilidad:** Debe ser identificable en 32x32px (favicon) y 512x512px (sticker)
- **Simplificación:** A tamaños pequeños, reducir detalles manteniendo silueta reconocible
- **Elementos mínimos:** Branquias, ojos, sonrisa siempre visibles

## Accessibility

### WCAG 2.2 AA Compliance

Todos los assets de Axi deben cumplir con los requisitos de accesibilidad:

| Requisito                    | Criterio                           | Implementación                       |
| ---------------------------- | ---------------------------------- | ------------------------------------ |
| **Contraste de color**       | Ratio mínimo 4.5:1 para texto      | Usar Blanco Hueso `#E8E8E8` sobre Púrpura Profundo `#1A1A2E` |
| **Contraste para gráficos**  | Ratio mínimo 3:1 para UI components | Verificar todas las variantes con herramientas de contraste |
| **Tamaño mínimo**            | 32x32px para iconos distinguibles  | Mantener elementos clave visibles a 32px |
| **Alternativas de texto**    | Descripción clara para screen readers | Incluir `alt` text y `aria-label` apropiados |
| **No dependencia de color**  | Información no transmitida solo por color | Usar formas, expresiones y contexto adicionales |

### High Contrast Variant
- Disponible para usuarios con necesidades de visibilidad
- Contornos más gruesos (4-6px)
- Colores de alto contraste: fondo negro `#000000`, Axi en rosa `#FF6B9D`, detalles en blanco `#FFFFFF`

### Testing Checklist
- [ ] Verificar contraste con [WebAIM Contrast Checker](https://webaim.org/resources/contrastchecker/)
- [ ] Probar visibilidad en modo oscuro y claro
- [ ] Validar reconocimiento a 32x32px
- [ ] Confirmar que expresiones son distinguibles sin color

## Usage Guidelines

1. **Consistency**: Axi should always look like the same character across all materials
2. **Adaptability**: Can be simplified for small sizes or detailed for large formats
3. **Accessibility**: High contrast versions available for users with visual impairments
4. **Cultural Sensitivity**: Avoid stereotyping; keep the friendly and inclusive

## Changelog

### v1.1.0 (2026-03-05)
- Synchronized color palette with official spec from `lifeos-ai-distribution.md` section 3.3
- Fixed typo in success color: `#2abc98e` → `#00D4AA` (Verde Regeneración)
- Added Rosa Axi `#FF6B9D` as primary brand color
- Added "Character Proportions" section with ASCII diagram
- Added "Art Style Guidelines" section
- Added "Accessibility" section with WCAG 2.2 AA requirements
- Added semantic color tokens table

## Asset Files

SVG base assets are located at:
```
/usr/share/icons/LifeOS/axi/svg/
├── axi-healthy.svg    # Base state - smiling
├── axi-updating.svg   # Updates in progress
├── axi-rollback.svg   # Regenerating with green glow
├── axi-autonomy.svg     # Intelligence mode
├── axi-focus.svg      # Focus/Flow mode
├── axi-meeting.svg    # Meeting mode
├── axi-night.svg      # Night mode/sleepy
├── axi-error.svg      # Error/worried state
└── axi-offline.svg    # Offline/sleeping
```

PNG exports (generated via `make axi-pngs`):
```
/usr/share/icons/LifeOS/axi/png/
├── 512/    # High resolution (stickers, merch)
├── 64/     # Medium resolution (app icons)
└── 32/     # Low resolution (favicons)
```

CLI Easter Eggs:
```bash
life --axi        # ASCII art with motivational message
life --axi-facts  # Fun facts about axolotls
```
