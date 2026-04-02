# Branding Audit — 2026-04

Auditoria de consistencia entre la marca oficial de LifeOS, la identidad de **Axi como ajolote mexicano**, y las superficies reales del proyecto.

**Fecha:** 2026-04-01  
**Estado:** Auditoria documental y de assets, con remediacion inicial aplicada en esta misma pasada  
**Alcance:** `docs/`, `image/`, `daemon/static/`, `lifeos-site/docs/`

---

## Resumen Ejecutivo

La marca de LifeOS ya tiene una direccion clara y fuerte:

- **Axi** como rostro del sistema
- **el ajolote mexicano** como motivo simbolico central
- **teal + rosa + dark-first** como paleta principal

Pero esa direccion **todavia no esta aplicada de forma uniforme** en todo el proyecto.

El estado real hoy es:

- **documentacion de marca:** bastante bien
- **prompt de sitio/landing:** bien encaminada
- **assets de Axi:** base solida
- **design tokens y temas base:** desalineados
- **wallpapers oficiales:** parcialmente desalineados
- **algunas superficies de producto:** todavia mezclan identidad LifeOS general con Axi sin una regla consistente

Conclusion corta:

- **la vision de marca ya existe**
- **la aplicacion completa todavia no**

---

## Estado Tras Esta Pasada

Quedaron corregidos en el worktree actual:

- fuente de verdad de tokens y temas base
- wallpapers default, dark, light, minimal y lock dentro de una familia mas coherente
- script de aplicacion de tema para usar el canonico vigente
- config de wallpaper para `skel` y `cosmic-greeter`
- documentacion secundaria principal que seguia apuntando a la etapa vieja
- una primera superficie Axi adicional (`axi.svg`) para uso en apps/shell

Siguen pendientes para una pasada posterior:

- revisar mas a fondo el set completo de iconos de Axi
- decidir si el dashboard debe incorporar una representacion visual mas explicita del ajolote
- actualizar activos historicos o de evidencia solo si realmente estorban

---

## Hallazgos

### 1. Critico — las fuentes base de tema y tokens siguen en la paleta azul vieja

La direccion oficial actual de marca dice:

- accent principal = `#00D4AA`
- secundario = `#FF6B9D`
- dark-first = `#0F0F1B` / `#161830`

Pero varias fuentes base del sistema siguen declarando la paleta anterior azul:

- [design-tokens.md](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/docs/branding/design-tokens.md)
- [design-tokens.toml](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files/etc/lifeos/design-tokens.toml)
- [design-tokens.json](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files/etc/lifeos/design-tokens.json)
- [cosmic-theme.toml](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files/etc/lifeos/cosmic-theme.toml)
- [LifeOS-Dark/index.theme](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files/usr/share/themes/LifeOS-Dark/index.theme)
- [LifeOS-Light/index.theme](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files/usr/share/themes/LifeOS-Light/index.theme)
- [LifeOS-Dark/gtk.css](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files/usr/share/themes/LifeOS-Dark/gtk-4.0/gtk.css)
- [LifeOS-Light/gtk.css](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files/usr/share/themes/LifeOS-Light/gtk-4.0/gtk.css)

Esto es la inconsistencia estructural mas importante porque deja dos “verdades” de marca coexistiendo:

- la documentada nueva
- la implementada vieja

Impacto:

- dificulta que web, OS, GTK, wallpapers y docs hablen el mismo lenguaje
- hace que contributors o generadores automaticos lean la fuente equivocada

### 2. Critico — el wallpaper default real todavia no refleja la nueva marca del ajolote

La nueva direccion de marca dice que:

- el wallpaper canonico debe tener un ajolote reconocible
- `Axi Xochimilco` debe funcionar como wallpaper central

Pero hoy el wallpaper default y varios derivados siguen siendo abstractos, orbitales o de paleta vieja:

- [lifeos-default.svg](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files/usr/share/backgrounds/lifeos/lifeos-default.svg)
- [lifeos-dark.svg](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files/usr/share/backgrounds/lifeos/lifeos-dark.svg)
- [lifeos-light.svg](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files/usr/share/backgrounds/lifeos/lifeos-light.svg)
- [lifeos-lock.svg](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files/usr/share/backgrounds/lifeos/lifeos-lock.svg)

El archivo mas cercano a la nueva direccion es:

- [lifeos-axi-night-wallpaper.svg](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files/usr/share/backgrounds/lifeos/lifeos-axi-night-wallpaper.svg)

Pero incluso ese todavia no incorpora un ajolote; sigue siendo una composicion atmosferica con anillos y glow.

Impacto:

- el usuario todavia no recibe visualmente la tesis de marca apenas arranca LifeOS
- el wallpaper oficial no distingue a LifeOS tanto como podria

### 3. Alto — documentacion tecnica y de arquitectura sigue describiendo el sistema visual anterior

Varias referencias de arquitectura y estrategia siguen describiendo wallpapers/orbes abstractos o rutas antiguas:

- [ai-runtime.md](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/docs/architecture/ai-runtime.md)
- [vision-y-decisiones.md](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/docs/strategy/vision-y-decisiones.md)

Problemas concretos:

- mencionan `axi-brand-guidelines.md`, que ya no es el nombre correcto
- describen sets de wallpaper centrados en “orbe”, “nebula”, “grid”, no en el ajolote canonico

Impacto:

- la documentacion secundaria puede arrastrar decisiones viejas
- complica la coherencia para futuros agentes y contribuidores

### 4. Alto — las superficies “Axi” no siempre usan iconografia de Axi

Ejemplo concreto:

- [lifeos-axi-dashboard.desktop](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files/usr/share/applications/lifeos-axi-dashboard.desktop)

Hoy dice:

- `Name=Axi Command Center`
- `Icon=lifeos`

Eso no rompe el producto, pero sí contradice la regla nueva:

- si una superficie es de **Axi**, deberia evaluar usar **Axi** como rostro principal

Impacto:

- confunde la jerarquia LifeOS vs Axi
- baja reconocimiento del asistente como entidad visual consistente

### 5. Medio — el dashboard esta bien encaminado, pero todavia no incorpora claramente la identidad del ajolote

El dashboard usa bien:

- teal como accent
- fondos oscuros
- orb / aura de Axi

Archivos:

- [index.html](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/daemon/static/dashboard/index.html)
- [style.css](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/daemon/static/dashboard/style.css)

Pero sigue representando a Axi sobre todo como:

- orbe
- aura
- etiqueta textual

Todavia no se ve una traduccion mas explicita del ajolote como forma, microilustracion, perfil o sistema iconografico.

Impacto:

- no es inconsistente
- pero si deja oportunidad clara de subir identidad sin reescribir todo

### 6. Medio — el repo del sitio ya esta mejor que el producto actual en fidelidad de marca

La prompt y checklist del sitio ya reflejan bien la nueva direccion:

- [landing-page-prompt.md](/var/home/lifeos/personalProjects/gama/lifeos/lifeos-site/docs/landing-page-prompt.md)
- [landing-page-review-checklist.md](/var/home/lifeos/personalProjects/gama/lifeos/lifeos-site/docs/landing-page-review-checklist.md)

Esto es bueno, pero deja una tension:

- la web ya está pensando en la marca correcta
- el sistema base todavia arrastra tokens y wallpapers viejos

Impacto:

- si se genera la landing ya, puede verse “mas correcta” que el OS actual

### 7. Bajo — hay evidencia historica y tests que todavia reflejan la etapa azul

Esto aparece en:

- `evidence/phase-2.5/*`
- `tests/firefox/firefox_hardened_tests.sh`
- `docs/archive/*`

No es urgente si el contenido es historico o de evidencia.
Solo importa para no confundirlo con la fuente oficial vigente.

---

## Lo Que Ya Esta Bien Alineado

- [brand-guidelines.md](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/docs/branding/brand-guidelines.md)
- [axi-visual-system.md](/var/home/lifeos/personalProjects/gama/lifeos/lifeos/docs/branding/axi-visual-system.md)
- el set de iconos/estados de Axi en `image/files/usr/share/icons/LifeOS/axi/`
- la paleta principal del dashboard
- la narrativa actual de la landing en `lifeos-site`

---

## Recomendaciones

### Fase 1 — Fuente de verdad unica

Actualizar para que la fuente estructural de color y tema coincida con la nueva marca:

- `docs/branding/design-tokens.md`
- `image/files/etc/lifeos/design-tokens.toml`
- `image/files/etc/lifeos/design-tokens.json`
- `image/files/etc/lifeos/cosmic-theme.toml`
- temas GTK `LifeOS-Dark` y `LifeOS-Light`

### Fase 2 — Wallpaper canonico real

Definir y producir:

- `Axi Xochimilco` como wallpaper oficial canonico
- variantes:
  - default
  - minimal
  - lock
  - greeter
  - light

### Fase 3 — Superficies Axi

Revisar todas las superficies nombradas como Axi para decidir si deben usar:

- icono LifeOS
- icono Axi
- ambos

Prioridad minima:

- `.desktop` de Axi
- Telegram avatar
- dashboard hero
- tray-facing assets

### Fase 4 — Limpieza documental

Actualizar docs secundarios que siguen atados a la etapa vieja:

- `docs/architecture/ai-runtime.md`
- `docs/strategy/vision-y-decisiones.md`

---

## Decision Practica Recomendada

Si hubiera que elegir el orden mas logico:

1. **alinear tokens/temas**
2. **crear wallpaper canonico**
3. **actualizar superficies Axi**
4. **limpiar documentacion secundaria**

Ese orden evita que la landing vaya mas adelante que el propio sistema.
