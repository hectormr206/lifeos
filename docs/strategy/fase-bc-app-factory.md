# Fase BC — Axi App Factory: Creacion Personalizada de Aplicaciones

> El usuario describe lo que necesita. Axi lo construye, lo despliega, lo evoluciona.
> Todo local. Todo del usuario. Cero dependencia de plataformas externas.

## Vision

Convertir a Axi en una **fabrica personal de aplicaciones**. Cada usuario puede:
1. Describir en lenguaje natural lo que necesita (por Telegram, voz, o en una reunion)
2. Axi entiende, planifica, construye y despliega la aplicacion
3. El usuario la prueba y da retroalimentacion ("me gusta", "cambia esto", "agrega esto")
4. Axi itera hasta que el usuario esta satisfecho
5. La aplicacion evoluciona con el tiempo (nuevas funciones, correcciones)
6. Todo protegido: nunca se pierde el trabajo, siempre hay backups

## Por que esto es revolucionario

**Ningun sistema existente combina estas 5 cosas:**
1. Agente AI que construye apps completas
2. Gestion de proyectos para esas apps
3. Despliegue auto-hospedado (sin cloud obligatorio)
4. Seguridad por defecto en cada app
5. Evolucion/iteracion via lenguaje natural

Los mas cercanos (Bolt.new, Lovable, Replit Agent) son **todos SaaS cloud**:
- Bolt.new: ~$40M ARR, prototipo en ~28 min
- Lovable: $100M ARR en 8 meses, $1.8B valuacion, 2.3M MAU
- Replit Agent: autonomo hasta 200 min por sesion

**Pero ninguno es local-first, ninguno es privado, ninguno vive en tu OS.**

## Estado del arte (investigacion)

### Agentes de codigo open-source (candidatos para Axi)

| Herramienta | Licencia | MCP | Subprocess | Recomendacion |
|---|---|---|---|---|
| **OpenCode** | Open source (Go) | SI, nativo | SI, CLI | **CANDIDATO #1** — MCP nativo, multi-modelo, YAML subagents |
| **OpenHands** | MIT, 68k stars | Via tools | SI, REST API + SDK | **CANDIDATO #2** — sandbox Docker, SDK, model-agnostic |
| **Aider** | Open source (Python) | No nativo | SI, CLI | Bueno para git-integrated generation |
| **SWE-Agent** | Open source (Princeton) | No | SI, Python | Mejor para bug-fixing que para creacion |
| ~~Claude Code CLI~~ | **Propietario** | SI | SI | **NO USAR** — all rights reserved, no redistribuible |
| **Claude Agent SDK** | Propietario pero uso comercial permitido | SI | SI, npm/pip | **OPCION PREMIUM** — legal para productos de terceros (ver seccion legal) |

### Precision actual de la generacion AI

- SWE-bench Verified: Claude Code 80.9%, GPT-5 88%
- **45% del codigo generado por AI tiene vulnerabilidades de seguridad**
- **Lovable: 10.3% de apps tenian fallos criticos de seguridad en Supabase**
- Ahorro realista: **80% del tiempo, no 100% automatizacion**
- Siempre necesita revision humana antes de produccion

### MCP (Model Context Protocol)

MCP es el "USB-C del AI" — protocolo estandar para que agentes AI interactuen con herramientas externas. **OpenCode ya lo soporta nativamente.**

MCP Servers disponibles para App Factory:
- **Filesystem**: Lectura/escritura de archivos con permisos
- **Git**: Clone, commit, branch, diff, push, pull
- **Terminal**: Ejecucion de comandos, procesos
- **GitHub**: Issues, PRs, repos
- **DeployHQ**: Gestion de despliegues
- **Docker/Podman**: Gestion de contenedores

## Marco legal y licenciamiento (CRITICO)

### Regla de oro: Solo herramientas open-source (MIT/Apache) o APIs con uso comercial permitido

| Herramienta | Legal para embeber? | Razon |
|---|---|---|
| **OpenCode** (MIT) | SI | Open source, libre uso comercial |
| **OpenHands** (MIT) | SI | Open source, libre uso comercial |
| **Aider** (Apache 2.0) | SI | Open source, libre uso comercial |
| **Claude Agent SDK** | SI (con condiciones) | Anthropic permite "power products for end users" |
| **APIs directas** (Claude, OpenAI, DeepSeek, Google) | SI | BYOK, uso comercial permitido |
| ~~Claude Code CLI~~ | **NO** | Propietario, all rights reserved, no redistribuible |
| ~~Cursor/Windsurf~~ | **NO** | Propietario, no redistribuible |

### Claude Agent SDK — El camino legal a Claude

Anthropic creo el Agent SDK (`@anthropic-ai/claude-agent-sdk`) especificamente para que
productos de terceros usen las capacidades de Claude. Cita textual:

> "Use of the Claude Agent SDK is governed by Anthropic's Commercial Terms of Service,
> including when you use it to **power products and services that you make available
> to your own customers and end users**."

**Capacidades del Agent SDK** (mismas que Claude Code CLI):
- Read, Write, Edit archivos
- Bash (ejecutar comandos)
- Glob, Grep (buscar archivos)
- WebSearch, WebFetch
- MCP support
- Subagents y sessions

**Reglas obligatorias:**
1. **BYOK** — El usuario provee su propia API key de console.anthropic.com
2. **Solo API key auth** — NUNCA usar OAuth de suscripciones Pro/Max (explicitamente prohibido)
3. **Branding propio** — Llamarlo "Axi", nunca "Claude Code". Puede decir "Powered by Claude"
4. **No redistribuir** — Instalar via `npm install` en setup, no bundled en la imagen del OS
5. **No competir** — LifeOS es un OS, no un servicio de AI (estamos bien)

### Precedentes legales

Asi lo hacen otros proyectos open-source exitosos:
- **Aider** (Apache 2.0): BYOK — usuario configura `--api-key anthropic=<key>`
- **Continue.dev** (Apache 2.0): BYOK — usuario configura API key en settings
- **Cursor**: Usa Claude API con keys propias + ofrece BYOK

## Costos de tokens (analisis detallado)

### Cuanto cuesta generar una app?

Una app tipica (ej. tracker de gastos con SvelteKit + PocketBase):
- ~20-30 archivos, ~5,000-15,000 lineas de codigo
- ~50,000-150,000 tokens de salida
- ~100,000-300,000 tokens de entrada
- 5-10 rondas de iteracion

| Proveedor | App simple | App compleja | 4 apps/mes |
|---|---|---|---|
| **Gemini Flash** | **$0.10-0.30** | **$0.50-1.50** | **$0.40-6** |
| **DeepSeek V3** | $0.15-0.50 | $1-3 | $0.60-12 |
| **GPT-4o mini** | $0.10-0.30 | $0.50-2 | $0.40-8 |
| **Claude Sonnet API** | $2-5 | $8-20 | $8-80 |
| **Claude Opus API** | $10-25 | $40-80 | $40-320 |
| **Modelo local (Qwen 4B)** | **$0** | **$0** | **$0** |

### Niveles de servicio para usuarios

| Nivel | Costo mensual | Que usa | Calidad |
|---|---|---|---|
| **Gratis** | $0 | Qwen/Llama local | Basica — apps simples, mas errores |
| **Economico** | $2-5 | DeepSeek + Gemini Flash | Buena — apps funcionales |
| **Estandar** | $10-20 | Claude Sonnet API | Muy buena — apps completas |
| **Premium** | $30-80 | Claude Opus API o Agent SDK | Maxima — apps complejas |

### Estrategia de ahorro de tokens

1. **Templates pre-hechos** — El scaffolding viene de templates, no se genera. Ahorra ~40% tokens
2. **Cache de generacion** — Apps similares reutilizan codigo. Si ya genero un "tracker", reutiliza
3. **Modelo local para planificacion** — Qwen planifica gratis, modelo cloud solo genera codigo
4. **Estimador de costos** — Antes de generar: "Esta app costara ~$0.30. Proceder?"
5. **Modo ahorro** — Usa solo modelo local, acepta menor calidad
6. **Ediciones incrementales** — Para cambios pequenos, usa modelo local. Solo cambios grandes van a cloud

### Arquitectura multi-proveedor

```
Axi (orquestador, Qwen local, gratis)
  |
  ├── Planificacion ──────── Qwen 3.5 4B local ($0)
  |     Entiende peticion, genera requisitos, elige template
  |
  ├── Generacion pesada ──── Multiples opciones (BYOK):
  |     |
  |     ├── Claude Agent SDK ──── Si tiene API key Anthropic (premium)
  |     ├── OpenCode (MIT) ─────── Multi-proveedor via MCP
  |     |     ├── DeepSeek API ($0.14-0.28/M tokens)
  |     |     ├── Gemini Flash ($0.075-0.30/M tokens)
  |     |     ├── OpenAI GPT-4o mini ($0.15-0.60/M tokens)
  |     |     └── Modelo local (Qwen/Llama)
  |     |
  |     └── Aider (Apache 2.0) ── Alternativa con git auto-commit
  |
  ├── Ediciones simples ──── Qwen local ($0)
  |     Cambios de 1-3 archivos, fixes menores
  |
  └── Tests + Deploy ─────── Local (Podman, Caddy) ($0)
```

**Principio: Nunca depender de un solo proveedor. El LLM Router de Axi ya soporta 13+ proveedores.**

## Arquitectura propuesta

### Stack tecnologico

| Componente | Herramienta | Por que |
|---|---|---|
| **Apps generadas** | SvelteKit + PocketBase | SvelteKit: modelo simple, menos errores de AI. PocketBase: binario unico ~15MB, auth incluido, SQLite, API REST |
| **Apps simples** | HTML + Alpine.js + PocketBase SDK | Cero build step, menor tasa de error |
| **Backend universal** | PocketBase | Auth, base de datos, archivos, admin dashboard, real-time — todo en un binario |
| **Agente de codigo** | OpenCode (MIT) via MCP + Claude Agent SDK (BYOK) + Aider (Apache) | Multi-proveedor, multi-agente, el usuario elige segun presupuesto |
| **Aislamiento** | Podman (rootless) | Cada app en su propio contenedor, SELinux, sin daemon root |
| **Reverse proxy** | Caddy | HTTPS automatico, cert renewal, config simple |
| **Control de versiones** | Git auto-commit | Cada cambio committed automaticamente |
| **Proteccion** | chattr +i + Btrfs snapshots | Archivos inmutables + snapshots antes de modificar |
| **Backup** | restic (encriptado) | Backup incremental a storage del usuario |

### Por que SvelteKit y no Next.js

- Next.js tiene demasiados modos de renderizado (SSR, SSG, ISR, RSC, Server Actions)
- Los agentes AI frecuentemente configuran mal estos modos
- SvelteKit: modelo mental simple, file-based routing, single-file components
- **Menor superficie de error para generacion AI**

### Por que PocketBase y no Supabase/Firebase

- PocketBase: un solo binario Go (~15MB), corre en cualquier maquina
- Auth integrado (email + OAuth2 para Google/GitHub)
- SQLite (perfecto para apps personales de un usuario)
- Dashboard admin incluido
- API REST out-of-the-box
- **Cero dependencia de cloud**

### Por que web apps y no Flatpak

- Flatpak: overhead de packaging alto para apps personales rapidas
- Flatpak: temas, integracion de archivos, permisos — complicaciones innecesarias
- PWAs: un codebase, instalables, offline-capable, actualizacion instantanea
- Si el usuario quiere acceso remoto: ya es una URL
- **Web es el formato ideal para apps personales generadas por AI**

## Flujo de trabajo

```
1. Usuario: "Necesito una app para rastrear mis gastos del mes"
   |
2. Axi: Busca en registro de proyectos si ya existe algo similar
   | (embedding similarity > 0.85)
   |
3a. Si existe similar: "Ya tienes 'Mi Presupuesto' que hace algo parecido.
    Quieres que le agregue esta funcion?"
   |
3b. Si es nuevo: Genera requirements, elige template, planifica
   |
4. Axi: Genera codigo via OpenCode/LLM
   | - Scaffolding desde template SvelteKit
   | - PocketBase collections para datos
   | - UI personalizada segun necesidades
   | - Middleware de seguridad inyectado automaticamente
   |
5. Axi: Build + tests automaticos
   | - npm build + type checking
   | - Smoke tests (pagina carga, auth funciona, CRUD opera)
   | - Scan de seguridad (secretos hardcodeados, endpoints abiertos)
   |
6. Axi: Deploy local
   | - Build container Podman
   | - Genera quadlet systemd (auto-start)
   | - Actualiza config de Caddy (subdomain routing)
   | - Health check
   |
7. Axi por Telegram: "Tu app esta lista: https://gastos.local.lifeos
   Pruebala y dime que cambiar."
   |
8. Usuario: "Me gusta pero quiero agregar categorias de gastos"
   |
9. Axi: Nueva iteracion → modifica → re-deploy → notifica
   |
10. Ciclo continuo de mejora
```

## Estructura de archivos

```
/var/lib/lifeos/apps/
  factory/                    # El sistema de factory
    factory.db                # PocketBase — registro de proyectos
    templates/                # Templates base (SvelteKit, HTML+Alpine)
    security/                 # Middleware de seguridad compartido
    caddy/                    # Configuracion de reverse proxy
  projects/
    mi-presupuesto/           # Cada app es self-contained
      .git/                   # Control de versiones automatico
      src/                    # Codigo SvelteKit
      pb_data/                # PocketBase data (SQLite)
      Containerfile           # Para build Podman
      project.json            # Metadata del proyecto
      CHANGELOG.md            # Historial legible
    rastreador-lecturas/
      ...
    dieta-gym/
      ...
  shared/                     # Componentes compartidos
    ui/                       # UI components reutilizables
    auth/                     # Auth middleware
```

## Proteccion de proyectos (CRITICO)

### Capa 1: Prevencion de borrado accidental
- `chattr +i` (flag inmutable) en cada directorio de proyecto
- Axi remueve temporalmente el flag antes de modificar, lo re-establece despues
- **Ni siquiera root puede borrar sin remover el flag primero**

### Capa 2: Control de versiones
- Git auto-commit en cada cambio (como Aider)
- Git reflog preserva historial incluso despues de operaciones destructivas
- Remote mirror opcional (GitHub, GitLab, Gitea self-hosted)

### Capa 3: Snapshots
- **Btrfs snapshot** antes de cada modificacion mayor
- Copy-on-write = overhead minimo de espacio
- Rollback instantaneo si algo sale mal
- Snapshots programados cada 6 horas

### Capa 4: Backup encriptado
- `restic` para backups incrementales encriptados
- Destino: storage del usuario (disco externo, S3, Backblaze B2, MinIO)
- **Usuario posee la llave de encriptacion** — nadie mas puede leer los backups
- Programado via systemd timers

### Capa 5: Confirmacion humana
- **Nunca borrar un proyecto sin confirmacion explicita del usuario**
- Papelera de reciclaje de 30 dias antes de borrado real
- Preguntar por Telegram: "Seguro que quieres eliminar 'Mi Presupuesto'? Esto borrara todos los datos."

## Seguridad por defecto

### Principio: La seguridad es infraestructura, no codigo de la app

El AI **nunca escribe codigo de autenticacion**. La seguridad viene de la infraestructura:

1. **Caddy**: HTTPS automatico + rate limiting + security headers
2. **PocketBase**: Auth + sesiones como servicio compartido
3. **Template de seguridad**: Inyectado automaticamente al crear cada app
4. **CSRF, XSS, input validation**: Middleware pre-hecho, no generado

### Login por defecto

Cada app tiene login por defecto usando PocketBase:
- Email/password (default)
- OAuth2 opcional (Google, GitHub)
- Passkeys (futuro)
- **Sin login = sin acceso** (zero-trust)

## Despliegue

### Opcion 1: Local (default, sin costo)
- Cada app corre en Podman rootless
- Caddy enruta `appname.local.lifeos` al contenedor correcto
- systemd mantiene los contenedores corriendo
- Solo accesible desde la maquina local o LAN

### Opcion 2: Acceso remoto via Tailscale (sin cloud publico)
- Tailscale conecta dispositivos del usuario
- App accesible desde celular/tablet via tailnet
- Sin servidor publico, sin puertos abiertos

### Opcion 3: VPS propio del usuario
- Axi guia al usuario para configurar un VPS (Hetzner ~$4/mes)
- Instala Coolify (PaaS open-source, self-hosted Vercel)
- Deploy automatico via git push
- Coolify maneja SSL, dominios, contenedores

### Opcion 4: Plataformas cloud (para quien lo quiera)
- Vercel, Railway, Fly.io, Render — todos tienen APIs
- Axi pide las API keys al usuario una sola vez
- Deploy automatizado via API
- El usuario solo ve su app corriendo en una URL publica

## Gestion de proyectos (Centro de Operaciones)

### Cada proyecto tiene:
- **Estado**: borrador → activo → archivado
- **Requisitos**: peticion original + requisitos parseados
- **Historial de decisiones**: que se decidio y por que
- **Iteraciones**: cada cambio con diff y razon
- **Feedback**: lo que al usuario le gusta/no le gusta
- **Metricas**: uso, uptime, ultimo acceso

### Deteccion de duplicados
- Antes de crear proyecto nuevo, Axi embede la peticion
- Compara con descripciones de proyectos existentes (cosine similarity > 0.85)
- Si hay coincidencia: "Ya tienes una app parecida. Quieres mejorar esa?"
- Evita proliferacion de proyectos duplicados

### Desde Telegram
- `/apps` — lista tus apps activas
- `/app status <nombre>` — estado de una app
- `/app feedback <nombre> <texto>` — dar retroalimentacion
- `/app rollback <nombre>` — revertir ultimo cambio

## Casos de uso reales

| Necesidad del usuario | App que Axi crea |
|---|---|
| "Quiero rastrear mis gastos del mes" | App de contabilidad personal con categorias, graficas, exportar a CSV |
| "Entro al gym y necesito seguir mi dieta" | Tracker de nutricion + rutinas + progreso con graficas |
| "Necesito aprender ingles" | App de flashcards personalizada + quiz + progreso diario |
| "Lista del super que se pueda compartir" | Lista de compras con checkboxes, compartible por link |
| "Registro de pagos de clientes" | CRM mini con facturacion, recordatorios, historial |
| "Agenda de citas para mi consultorio" | Sistema de citas con calendario, recordatorios, historial pacientes |
| "Quiero un blog personal" | Blog con markdown, categorias, RSS, SEO |

## Fases de implementacion

### Fase BC.1 — Fundacion (mes 1-2)
- [ ] Estructura de `/var/lib/lifeos/apps/`
- [ ] PocketBase integrado como servicio del sistema
- [ ] Template base SvelteKit + PocketBase SDK
- [ ] Caddy como reverse proxy con routing de subdomains
- [ ] Proteccion con chattr + git auto-commit
- [ ] Telegram tools: `/app create`, `/app list`, `/app status`
- [ ] BYOK setup flow: Axi guia al usuario a configurar API keys
- [ ] Estimador de costos por generacion

### Fase BC.2 — Generacion de codigo (mes 2-3)
- [ ] Integracion de OpenCode (MIT) via MCP
- [ ] Integracion opcional de Claude Agent SDK (BYOK, API key auth)
- [ ] Scaffolding desde templates
- [ ] Generacion de PocketBase collections desde requisitos
- [ ] Build automatico + smoke tests
- [ ] Deploy local via Podman + quadlet systemd

### Fase BC.3 — Iteracion y evolucion (mes 3-4)
- [ ] Feedback loop via Telegram
- [ ] Deteccion de duplicados (embedding similarity)
- [ ] Historial de iteraciones con changelog
- [ ] Rollback via git + Btrfs snapshots
- [ ] Dashboard de gestion de apps

### Fase BC.4 — Seguridad y despliegue remoto (mes 4-5)
- [ ] Auth gateway compartido (PocketBase)
- [ ] Security middleware template
- [ ] Opcion Tailscale para acceso remoto
- [ ] Opcion Coolify para VPS
- [ ] Opcion Vercel/Railway via API

### Fase BC.5 — Intelligence avanzada (mes 5-6)
- [ ] Apps que se auto-mejoran basadas en uso
- [ ] Deteccion de patrones de uso (que pantallas visita mas el usuario)
- [ ] Sugerencias proactivas ("noté que siempre agregas la fecha manual, puedo agregarla automatica")
- [ ] Multi-app integration (datos compartidos entre apps del usuario)
- [ ] Backup encriptado automatico con restic

## Dependencias

| Componente | Tamano | Instalacion |
|---|---|---|
| PocketBase | ~15 MB | Binary download |
| Caddy | ~35 MB | Binary download |
| OpenCode | ~20 MB | Binary download |
| Node.js + npm | ~60 MB | Ya en Fedora repos |
| SvelteKit template | ~5 MB | Git clone una vez |
| restic | ~15 MB | Fedora repos |

Total: ~150 MB de herramientas adicionales.

## Riesgos y mitigaciones

| Riesgo | Mitigacion |
|---|---|
| AI genera codigo con bugs | Tests automaticos + revision humana antes de deploy |
| AI genera vulnerabilidades (45% segun estadisticas) | Seguridad como infraestructura, no como codigo generado |
| Usuario borra app accidentalmente | chattr + git + snapshots + papelera 30 dias |
| Disco se llena de proyectos | Housekeeping: archivar inactivos, limitar a N proyectos activos |
| LLM local (Qwen 4B) insuficiente para generar apps complejas | Fallback a Claude/GPT via LLM Router para tareas complejas |
| Contenedor corrupto | Rebuild automatico desde git + Containerfile |
| Problemas legales con proveedores AI | Solo usar herramientas MIT/Apache o APIs con BYOK. Nunca redistribuir software propietario |
| Cambio de terminos de servicio de Anthropic | Claude Agent SDK es solo una opcion. OpenCode (MIT) funciona con cualquier proveedor |
| Usuario no tiene API key | Modo offline con modelo local siempre disponible como fallback |

## Fuentes de la investigacion

- Bolt.new, Lovable, Replit Agent — analisis de mercado
- OpenCode, OpenHands, Aider, SWE-Agent — herramientas open-source
- MCP Protocol — modelcontextprotocol.io
- PocketBase — pocketbase.io
- Malleable Software — Ink & Switch (2025)
- Personal Software — Proximo/Girardin
- AI Code Security — CodeRabbit (45% vulnerabilities)
- Caddy, Podman, Btrfs, restic — herramientas de infraestructura

### Fuentes legales (licenciamiento)

- Claude Code LICENSE.md — "(c) Anthropic PBC. All rights reserved."
- Claude Agent SDK docs — "power products and services for your own customers and end users"
- Anthropic Commercial Terms of Service — Seccion A.1 (uso comercial permitido)
- Anthropic Legal/Compliance — "OAuth authentication is intended exclusively for Claude Code and Claude.ai"
- Anthropic Legal/Compliance — "Developers should use API key authentication through Claude Console"
- Anthropic Branding — Permitido: "Powered by Claude". Prohibido: "Claude Code"
- Precedentes: Aider (Apache 2.0, BYOK), Continue.dev (Apache 2.0, BYOK)
