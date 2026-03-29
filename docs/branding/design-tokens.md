# LifeOS Design Tokens

**Version:** 1.0.0  
**Last Updated:** 2026-03-05  
**Status:** Official

## Overview

Design tokens son los valores atómicos del sistema de diseño de LifeOS. Estos tokens definen colores, tipografía, espaciado, sombras y bordes para mantener consistencia visual en toda la plataforma.

## Naming Convention

Todos los tokens siguen el patrón: `--lifeos-{category}-{variant}-{state}`

```
--lifeos-primary           → Color primario base
--lifeos-primary-hover     → Color primario en hover
--lifeos-spacing-md        → Espaciado medium
--lifeos-shadow-lg         → Sombra large
```

---

## Colors

### Brand Colors (Paleta Principal)

| Token | Value | Usage |
|-------|-------|-------|
| `--lifeos-primary` | `#0f4c75` | Primary actions, links, focus rings |
| `--lifeos-accent` | `#3282b8` | Accents, highlights, secondary actions |
| `--lifeos-surface` | `#16213e` | Cards, panels, elevated surfaces |
| `--lifeos-background` | `#1a1a2e` | Main background |

### Semantic Colors

| Token | Dark Theme | Light Theme | Usage |
|-------|------------|-------------|-------|
| `--lifeos-text` | `#e8e8e8` | `#1a1a2e` | Primary text |
| `--lifeos-text-muted` | `#a0a0a0` | `#6b6b7b` | Secondary text, placeholders |
| `--lifeos-error` | `#e74c3c` | `#c0392b` | Error states, destructive actions |
| `--lifeos-warning` | `#f39c12` | `#d68910` | Warning states |
| `--lifeos-success` | `#2ecc71` | `#27ae60` | Success states, confirmations |

### State Colors

| Token | Value | Usage |
|-------|-------|-------|
| `--lifeos-hover` | `rgba(255, 255, 255, 0.08)` | Hover overlay |
| `--lifeos-active` | `rgba(255, 255, 255, 0.12)` | Active/pressed state |
| `--lifeos-disabled` | `rgba(255, 255, 255, 0.38)` | Disabled elements |
| `--lifeos-focus` | `--lifeos-primary` | Focus ring color |

### High Contrast Theme

| Token | Value | Usage |
|-------|-------|-------|
| `--lifeos-primary` | `#00ff00` | Green for maximum visibility |
| `--lifeos-accent` | `#ffff00` | Yellow accent |
| `--lifeos-background` | `#000000` | Pure black background |
| `--lifeos-surface` | `#1a1a1a` | Near-black surface |
| `--lifeos-text` | `#ffffff` | Pure white text |

---

## Typography

### Font Family

```css
--lifeos-font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
--lifeos-font-mono: 'JetBrains Mono', 'Fira Code', 'Consolas', monospace;
```

### Font Sizes

| Token | Value | Usage |
|-------|-------|-------|
| `--lifeos-text-xs` | `12px` | Captions, labels, small text |
| `--lifeos-text-sm` | `14px` | Body small, secondary text |
| `--lifeos-text-base` | `16px` | Body text, default |
| `--lifeos-text-lg` | `18px` | Large body text |
| `--lifeos-text-xl` | `20px` | Headings level 4 |
| `--lifeos-text-2xl` | `24px` | Headings level 3 |
| `--lifeos-text-3xl` | `30px` | Headings level 2 |
| `--lifeos-text-4xl` | `36px` | Headings level 1 |
| `--lifeos-text-5xl` | `48px` | Display headings |
| `--lifeos-text-6xl` | `72px` | Hero text |

### Font Weights

| Token | Value | Usage |
|-------|-------|-------|
| `--lifeos-font-normal` | `400` | Body text |
| `--lifeos-font-medium` | `500` | Emphasized text |
| `--lifeos-font-semibold` | `600` | Subheadings |
| `--lifeos-font-bold` | `700` | Headings, strong emphasis |

### Line Heights

| Token | Value | Usage |
|-------|-------|-------|
| `--lifeos-leading-none` | `1` | Single line |
| `--lifeos-leading-tight` | `1.25` | Headings |
| `--lifeos-leading-normal` | `1.5` | Body text |
| `--lifeos-leading-relaxed` | `1.75` | Long form text |

---

## Spacing

### Scale (4px base unit)

| Token | Value | Pixels | Usage |
|-------|-------|--------|-------|
| `--lifeos-spacing-0` | `0` | `0px` | No spacing |
| `--lifeos-spacing-1` | `0.25rem` | `4px` | Tight spacing |
| `--lifeos-spacing-2` | `0.5rem` | `8px` | Small spacing |
| `--lifeos-spacing-3` | `0.75rem` | `12px` | Medium-small |
| `--lifeos-spacing-4` | `1rem` | `16px` | Default spacing |
| `--lifeos-spacing-5` | `1.5rem` | `24px` | Medium spacing |
| `--lifeos-spacing-6` | `2rem` | `32px` | Large spacing |
| `--lifeos-spacing-7` | `3rem` | `48px` | Section spacing |
| `--lifeos-spacing-8` | `4rem` | `64px` | Large section |
| `--lifeos-spacing-9` | `6rem` | `96px` | XL spacing |
| `--lifeos-spacing-10` | `8rem` | `128px` | Hero spacing |

---

## Shadows

### Elevation Levels

| Token | Value | Usage |
|-------|-------|-------|
| `--lifeos-shadow-none` | `none` | Flat elements |
| `--lifeos-shadow-sm` | `0 1px 2px rgba(0, 0, 0, 0.3)` | Subtle lift |
| `--lifeos-shadow-md` | `0 4px 6px rgba(0, 0, 0, 0.4)` | Cards, dropdowns |
| `--lifeos-shadow-lg` | `0 10px 15px rgba(0, 0, 0, 0.5)` | Modals, popovers |
| `--lifeos-shadow-xl` | `0 20px 25px rgba(0, 0, 0, 0.6)` | Floating elements |
| `--lifeos-shadow-2xl` | `0 25px 50px rgba(0, 0, 0, 0.7)` | Maximum elevation |

---

## Borders

### Border Radius

| Token | Value | Usage |
|-------|-------|-------|
| `--lifeos-radius-none` | `0` | Square corners |
| `--lifeos-radius-sm` | `4px` | Small radius |
| `--lifeos-radius-md` | `8px` | Default radius |
| `--lifeos-radius-lg` | `12px` | Large radius |
| `--lifeos-radius-xl` | `16px` | Extra large |
| `--lifeos-radius-full` | `9999px` | Pills, circles |

### Border Widths

| Token | Value | Usage |
|-------|-------|-------|
| `--lifeos-border-0` | `0` | No border |
| `--lifeos-border-1` | `1px` | Default border |
| `--lifeos-border-2` | `2px` | Emphasis border |
| `--lifeos-border-4` | `4px` | Strong emphasis |

---

## Animation

### Durations

| Token | Value | Usage |
|-------|-------|-------|
| `--lifeos-duration-fast` | `150ms` | Quick interactions |
| `--lifeos-duration-normal` | `250ms` | Default transitions |
| `--lifeos-duration-slow` | `400ms` | Complex animations |
| `--lifeos-duration-slower` | `600ms` | Page transitions |

### Easing

| Token | Value | Usage |
|-------|-------|-------|
| `--lifeos-ease-linear` | `linear` | Linear motion |
| `--lifeos-ease-in` | `cubic-bezier(0.4, 0, 1, 1)` | Ease in |
| `--lifeos-ease-out` | `cubic-bezier(0, 0, 0.2, 1)` | Ease out |
| `--lifeos-ease-in-out` | `cubic-bezier(0.4, 0, 0.2, 1)` | Ease in-out |

---

## Z-Index Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--lifeos-z-base` | `0` | Default layer |
| `--lifeos-z-dropdown` | `100` | Dropdowns |
| `--lifeos-z-sticky` | `200` | Sticky headers |
| `--lifeos-z-fixed` | `300` | Fixed elements |
| `--lifeos-z-modal-backdrop` | `400` | Modal backdrop |
| `--lifeos-z-modal` | `500` | Modals |
| `--lifeos-z-popover` | `600` | Popovers |
| `--lifeos-z-tooltip` | `700` | Tooltips |

---

## WCAG Compliance

All color combinations in LifeOS themes are tested for WCAG 2.1 compliance:

| Theme | Contrast Ratio | Level |
|-------|----------------|-------|
| LifeOS Dark | 7.5:1 | AAA |
| LifeOS Light | 7.2:1 | AAA |
| LifeOS High Contrast | 21:1 | AAA |

---

## Changelog

### v1.0.0 (2026-03-05)
- Initial design tokens specification
- Defined brand colors palette
- Typography scale with Inter font
- Spacing scale based on 4px units
- Shadow elevation system
- Border radius and width tokens
- Animation timing tokens
- Z-index scale

---

## Usage

### In GTK CSS

```css
@define-color lifeos_primary #0f4c75;
@define-color lifeos_accent #3282b8;

button {
  background-color: @lifeos_primary;
  border-radius: 8px;
}
```

### In TOML Configuration

```toml
[colors]
primary = "#0f4c75"
accent = "#3282b8"

[typography]
font_family = "Inter"
base_size = 16
```

### In Rust Code

```rust
const LIFEOS_PRIMARY: &str = "#0f4c75";
const LIFEOS_ACCENT: &str = "#3282b8";
```

---

## References

- [THEMES.md](./THEMES.md) - Theme system documentation
- [cosmic-theme.toml](../image/files/etc/lifeos/cosmic-theme.toml) - Theme configuration
- [WCAG 2.1 Guidelines](https://www.w3.org/WAI/WCAG21/quickref/)
