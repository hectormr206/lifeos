# Brief Operativo: Landing v1 de LifeOS

> Estado: siguiente paso recomendado
> Contexto: post-NLnet, presencia publica inicial, founder solo, audiencias hispanohablantes y open-source global
> Fecha: `2026-04-01`

---

## 1. Objetivo

Lanzar una **landing publica de una sola pagina** que haga cuatro cosas bien:

1. explicar rapidamente que es LifeOS
2. demostrar por que importa
3. redirigir a la gente correcta a los canales correctos
4. abrir un rail real de seguimiento y apoyo

La meta de esta landing **no** es vender una version 1.0 inexistente.
La meta es crear una **puerta de entrada clara y creible** al proyecto.

---

## 2. Decisiones Cerradas

### Repo

- nombre recomendado: **`lifeos-site`**
- visibilidad: **publico**
- separado del repo principal de LifeOS

### Hosting

- **Vercel**

### Dominio inicial

- **`lifeos.hectormr.com`**

### Superficie

- **1 sola pagina**
- sin blog
- sin auth
- sin docs complejas
- sin portal de descargas todavia

---

## 3. Stack Recomendado

### Recomendacion principal

- **Next.js**
- **TypeScript**
- **App Router**
- **deploy en Vercel**

### Por que esta es la mejor opcion

- encaja perfecto con Vercel
- da previews faciles
- es flexible si luego la landing crece a sitio real
- facilita forms, MDX, changelogs o docs ligeras despues
- no te mete en una migracion temprana si el sitio escala

### No hace falta meter de inicio

- CMS
- base de datos
- auth
- dashboard
- analytics pesadas

### Analitica recomendada

Si mas adelante quieres analitica:

- usar algo privacy-friendly
- no meter Google Analytics como default

Por ahora incluso puede salir sin analitica.

---

## 4. Estrategia de Idioma

### Recomendacion

**v1 en ingles, con tono claro y directo**

### Por que

- grants, OSS, sponsors, prensa tech y contributors globales entienden mejor esa capa
- el sitio solo necesita unas cuantas secciones y copy muy controlado
- tu contenido continuo puede seguir siendo **espanol mexicano primero**

### Traduccion operativa

- **landing:** ingles primero
- **YouTube / Twitch / newsletter:** espanol primero
- **v2:** pagina o toggle en espanol

Esto te permite maximizar alcance sin obligarte a vivir creando contenido en ingles.

### Guardrail de posicionamiento

Si la landing menciona el origen del proyecto, el framing correcto es:

- **built in Mexico**
- **open to anyone**

No debe presentar a LifeOS como algo regionalmente exclusivo ni usar lenguaje turistico o folklorico.

---

## 5. CTA Strategy

La landing debe tener **3 CTAs principales** y nada mas.

### CTA 1

**Get updates**

Destino:
- newsletter
- waitlist
- simple email capture

### CTA 2

**View on GitHub**

Destino:
- repo principal

### CTA 3

**Support LifeOS**

Destino:
- GitHub Sponsors
- o pagina de apoyo si ya existe

### CTA secundaria opcional

**Watch demos**

Destino:
- YouTube

No mas CTAs en v1. Si metes demasiados, se diluye el foco.

---

## 6. Sitemap de 1 Pagina

La pagina debe tener esta estructura:

### 1. Hero

Contenido:
- headline
- subheadline
- 2 botones principales
- 1 enlace secundario
- mockup visual / screenshot / composicion heroica

### 2. Why LifeOS

Tres columnas o cards:
- local-first AI
- privacy by default
- AI-native operating system

### 3. What Works Today

Solo lo real y defendible:
- local inference (`validated on host`)
- encrypted local memory foundations (`integrated in repo`)
- desktop control plane foundations (`integrated in repo`)
- Telegram remote loop (`validated on host`)
- voice / vision / automation foundations (`experimental`)

### 4. Why This Matters

Un bloque corto que contraste:
- cloud assistants
- vendor lock-in
- proprietary ecosystems

### 5. Road to Public Beta

Tres bullets maximo:
- stabilize public beta
- improve accessibility and desktop control
- grow public documentation and community

### 6. Follow the Project

Links a:
- GitHub
- YouTube
- Twitch
- newsletter

### 7. Support LifeOS

Un bloque muy claro:
- GitHub Sponsors
- support / donations
- sponsor / partner interest

### 8. Footer

- attribution
- repo
- creator link
- privacy note

---

## 7. Copy Recomendado para la Home

### Hero

**Headline**

`A local-first AI operating system for sovereign personal computing.`

**Subheadline**

`LifeOS is an AI-native Linux distribution exploring a local-first assistant that runs on your own machine, keeps core data local, and is being hardened across desktop control and remote interaction.`

**Primary CTA**

`Get updates`

**Secondary CTA**

`View on GitHub`

**Support link**

`Support LifeOS`

### Section: Why LifeOS

**Local-first AI**

`Run open-weight models on your own hardware instead of depending on a remote black box.`

**Private by default**

`Keep memory, context, and control on your machine with a privacy-first architecture.`

**AI-native OS**

`LifeOS is not just an app. It is a Linux system designed around the assistant from the ground up.`

### Section: What Works Today

Suggested intro:

`LifeOS is already more than a concept. The current system includes host-validated local inference and Telegram interaction, plus repo-integrated foundations for encrypted memory, desktop control, and voice/vision/automation work that is still being hardened.`

### Section: Why This Matters

Suggested text:

`Most assistants are cloud-dependent, locked to vendor ecosystems, and designed around surveillance-friendly defaults. LifeOS explores a different path: your assistant, your machine, your data, your control.`

### Section: Road to Public Beta

Suggested bullets:

- `Stabilize the public beta experience`
- `Improve universal desktop control and accessibility`
- `Expand documentation, onboarding, and public demos`

### Section: Follow the Project

Suggested text:

`Follow LifeOS in public as it moves from ambitious prototype to real public beta.`

### Section: Support

Suggested text:

`LifeOS is being built in public. If you want to help make a privacy-first AI operating system real, follow the project, share it, and support its development.`

---

## 8. Version en Espanol para referencia

No hace falta lanzarla en v1, pero sirve como referencia de tono.

### Hero ES

**Headline**

`Un sistema operativo con IA local para computacion personal soberana.`

**Subheadline**

`LifeOS es una distribucion Linux AI-native donde tu asistente vive en tu propia maquina, recuerda localmente y te ayuda en el escritorio sin mandar tu vida a la nube.`

---

## 9. Visual Direction

La landing debe usar el lenguaje visual ya definido:

- fondo dark-first
- `Teal Axi` como accent principal
- `Rosa Axi` como accent secundario, no dominante
- superficies oscuras con sensacion de sistema vivo
- tipografia limpia y tecnica

### Sensacion visual buscada

- soberano
- elegante
- tecnico
- vivo
- confiable
- no corporate bland
- no gamer overload

### Referencia obligatoria

- [brand-guidelines.md](../../branding/brand-guidelines.md)

---

## 10. Assets Minimos para Lanzar

Necesitas estos assets minimos:

1. logo LifeOS
2. favicon
3. 1 screenshot real del sistema
4. 1 composicion hero simple
5. links reales a:
   - GitHub
   - newsletter o waitlist
   - YouTube
   - Twitch
   - support

Si no existen esos links todavia, la landing debe salir con CTA limitados y honestos.

---

## 11. Lo que NO debe decir la landing

No pongas claims como:

- “download now” si aun no hay beta descargable
- “works everywhere” si todavia no esta validado
- “your AI for everything” si no quieres sonar vaporware
- comparativas exageradas o hype estilo startup vacia

Si una capability no esta validada en host, integrada en repo, o shipped por default de forma clara, no debe sonar como algo plenamente disponible hoy.

La fuerza de LifeOS debe venir de:

- claridad
- singularidad
- realidad tecnica
- ambicion creible

---

## 12. Conversion Path

El flujo ideal del visitante debe ser:

1. entra
2. entiende la tesis en menos de 10 segundos
3. ve que no es humo
4. elige una accion:
   - seguir el proyecto
   - ver GitHub
   - ver demos
   - apoyar

Si el visitante no entiende eso en una visita, la landing fallo.

---

## 13. Definition of Done para v1

La landing v1 esta lista cuando:

- existe el repo `lifeos-site`
- la pagina esta deployada
- responde en `lifeos.hectormr.com`
- tiene hero + pilares + estado actual + follow + support
- los links funcionan
- el mensaje central se entiende rapido
- se ve bien en desktop y mobile

No hace falta que tenga:

- blog
- changelog
- docs
- login
- SEO perfecto
- dashboards

---

## 14. Siguiente paso despues de la landing

Despues del lanzamiento v1:

1. agregar newsletter real
2. conectar GitHub Sponsors
3. publicar 1 video en YouTube
4. hacer 1 directo tecnico en Twitch/YouTube
5. revisar si la gente entiende el mensaje
6. iterar copy

Solo despues de eso conviene decidir si:

- compras dominio
- haces una version en espanol
- conviertes la landing en sitio mas grande

---

## 15. Recomendacion Final

Si optimizeamos por velocidad y claridad, el mejor siguiente movimiento es:

1. **repo publico `lifeos-site`**
2. **Next.js + TypeScript**
3. **deploy en Vercel**
4. **subirlo a `lifeos.hectormr.com`**
5. **hero claro + follow + support**

Eso te da una presencia publica real sin distraerte del desarrollo principal.
