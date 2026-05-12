# PRD — LifeOS Personal Runtime Pivot

**Status:** Draft v1 · 2026-05-11  
**Owner:** LifeOS Lab  
**Decision:** LifeOS deja de competir como distro completa y pasa a ser un **sistema operativo para tu vida**: una capa/runtime Linux-first que corre sobre la distro que el usuario elija.

---

## 1. Resumen ejecutivo

LifeOS no debe seguir intentando ganar en la capa de kernel, drivers, paquetes, imagen bootc o distribución base. Esa capa ya la hacen mejor Fedora, CachyOS, Arch, Ubuntu, NixOS y otros proyectos dedicados a operar sistemas Linux.

La nueva tesis es:

> **LifeOS es el sistema operativo para tu vida digital: una capa local-first sobre Linux que organiza memoria, contexto, agentes, comunicación privada y acciones en tu computadora sin reemplazar tu distro.**

Esto preserva el nombre y la ambición de “LifeOS”, pero corrige el alcance técnico: LifeOS no pretende ser “otro Linux”. LifeOS pretende ser la capa personal de IA, memoria y agencia que vive arriba de Linux.

La primera plataforma de referencia será el entorno real de Hector, empezando por CachyOS, porque resuelve mejor el daily driver: paquetes frescos, NVIDIA, Steam, kernel moderno y hardware al máximo. CachyOS es host de referencia, **no identidad del producto**.

---

## 2. Problema

### El enfoque anterior

LifeOS nació como una distribución Linux AI-native basada en Fedora bootc, COSMIC Desktop, servicios del sistema, imagen OCI, actualizaciones bootc y rollback.

Después de meses de trabajo, el aprendizaje real fue claro:

| Dolor | Impacto |
|------|---------|
| Rebuilds de imagen completa | Cada cambio pequeño podía arrastrar kernel, desktop, drivers y servicios. |
| Acoplamiento a NVIDIA/desktop/bootc | El proyecto invertía energía en operar una distro, no en mejorar Axi. |
| Laptop diaria como campo de pruebas | Programar y jugar quedaban condicionados por la estabilidad de LifeOS OS. |
| Paquetes y drivers | Un programador/gamer necesita moverse rápido con Steam, NVIDIA, kernel y tooling moderno. |
| Mensaje público difícil de sostener | “AI-native Linux distribution” obliga a demostrar una distro completa, no solo una experiencia inteligente. |

### El problema real del usuario

El usuario no necesita otra distro. Necesita que Axi:

- recuerde sin olvidar silenciosamente;
- entienda interrupciones y retome contexto;
- hable por canales privados como SimpleX;
- use memoria corta y larga;
- delegue trabajo a subagentes para no bloquearse;
- procese en background cuando el usuario no está mirando;
- vea, escuche, hable y entienda el entorno local cuando el host lo permita;
- respete la GPU, el gaming y los recursos de la máquina.

Nada de eso requiere que LifeOS controle el kernel o sea la distro principal.

---

## 3. Objetivo

Reposicionar LifeOS como un **runtime personal Linux-first** que se instala sobre cualquier distro moderna y entrega la experiencia de Axi.

### Objetivos principales

1. **Separar LifeOS de la distro base.** Fedora bootc, NixOS y CachyOS pasan a ser hosts o empaquetados, no la identidad central.
2. **Preservar la marca “LifeOS”.** LifeOS sigue siendo un sistema operativo, pero en el sentido de sistema operativo personal/de vida digital, no kernel+distro.
3. **Actualizar GitHub y la web pública.** El repo ya no debe presentarse como una imagen bootc que se construye y actualiza como producto principal.
4. **Reducir el v1 a una demostración creíble.** Menos promesas, más loop funcional: Axi + memoria + acciones locales + SimpleX + host validation.
5. **Mantener LifeOS Lab creíble.** El cambio se comunica como aprendizaje estratégico, no como abandono.

---

## 4. No objetivos

- No construir una nueva distro completa basada en CachyOS.
- No continuar la migración NixOS como camino principal del producto.
- No mantener Fedora bootc como la promesa pública principal.
- No prometer “multimodal always-on” como estable antes de validarlo.
- No reescribir todo el backend antes de actualizar la narrativa pública.
- No acoplar LifeOS a CachyOS; CachyOS es referencia, no dependencia.

---

## 5. Nueva definición de producto

### Frase canónica

> **LifeOS es un sistema operativo personal de IA para tu vida digital, instalado sobre Linux: memoria persistente, agencia local, comunicación privada y contexto continuo sin obligarte a cambiar de distro.**

### Taglines posibles

| Idioma | Tagline |
|--------|---------|
| ES | El sistema operativo para tu vida digital. |
| ES | Tu memoria, tus agentes y tu contexto sobre el Linux que ya usás. |
| EN | The personal operating system for your digital life. |
| EN | Memory, agents, and context over the Linux you already use. |

### Qué es LifeOS ahora

| Capa | Responsabilidad |
|------|-----------------|
| Distro host | Kernel, drivers, paquetes, Steam, desktop base, hardware. |
| LifeOS Runtime | Daemon local, memoria, herramientas, SimpleX, eventos, agentes, background jobs. |
| Axi | Interfaz/orquestador conversacional. |
| Web app/dashboard | Configuración, estado, memoria, conversaciones, controles y onboarding. |
| Host profiles | Instaladores/configuración por distro: CachyOS primero, otras después. |

---

## 6. Arquitectura objetivo

```text
┌────────────────────────────────────────────┐
│ Usuario                                    │
│ - Chat local / web app                     │
│ - SimpleX remoto privado                   │
│ - Voz / escritorio / acciones              │
└──────────────────────┬─────────────────────┘
                       │
┌──────────────────────▼─────────────────────┐
│ Axi                                        │
│ - Orquestador                              │
│ - Delegación a subagentes                  │
│ - Continuidad conversacional               │
│ - Respuesta final al usuario               │
└──────────────────────┬─────────────────────┘
                       │
┌──────────────────────▼─────────────────────┐
│ LifeOS Runtime                             │
│ - lifeosd                                  │
│ - memoria local                            │
│ - tools del sistema                        │
│ - SimpleX bridge                           │
│ - jobs/background processing               │
│ - runtime profile / GPU guard              │
└──────────────────────┬─────────────────────┘
                       │
┌──────────────────────▼─────────────────────┐
│ Linux host                                 │
│ CachyOS, Fedora, Ubuntu, Arch, NixOS, etc. │
│ - kernel                                   │
│ - drivers                                  │
│ - desktop                                  │
│ - Steam/gaming                             │
│ - paquetes                                 │
└────────────────────────────────────────────┘
```

---

## 7. Producto v1

El v1 NO debe intentar entregar toda la visión. Debe demostrar el loop único de LifeOS.

### V1 mínimo creíble

| Capability | Estado objetivo | Razón |
|------------|-----------------|-------|
| Axi local runtime | Funcional en host Linux | Es el punto de entrada al producto. |
| Memoria persistente real | Guardar, recuperar y corregir memoria | Diferenciador contra chatbots que olvidan. |
| SimpleX remote loop | Chat remoto privado con continuidad | Canal soberano y útil fuera de la laptop. |
| Acciones locales seguras | Ejecutar tools limitadas y auditables | Demuestra agencia sin vender humo. |
| CachyOS host profile | Instalación validada en una máquina real | Primer host de referencia para desarrollo diario. |
| Dashboard/web app | Estado, configuración y onboarding básicos | Necesario para usuarios y demos públicas. |

### Fuera de v1 estable

- Visión por cámara always-on.
- Captura permanente de pantalla/audio.
- “Dreaming” avanzado sin definición operativa.
- Marketplace de agentes.
- Soporte oficial multi-distro completo.
- ISO propia como canal principal.

Estas capacidades pueden existir como experimentales, pero no deben ser la promesa estable inicial.

---

## 8. Implicaciones para GitHub

El repo principal de LifeOS ya no debe abrir con “AI-native Linux distribution built on Fedora bootc”. Esa frase quedó histórica.

### Cambios requeridos en README

| Sección actual | Cambio requerido |
|----------------|------------------|
| Hero / descripción | Reemplazar distro bootc por runtime personal Linux-first. |
| What Makes LifeOS Different | Cambiar “OS-level architecture” por “personal runtime layer”. |
| Building with Nix | Mover a sección histórica/experimental; no canonical path. |
| Quick Start bootc | Reemplazar por “Runtime quick start” cuando exista instalador. |
| Repository Layout | Marcar `image/` como legacy/archived path si queda en repo. |
| Tech Stack | Separar host OS de runtime stack. |
| Update docs | Dejar claro que bootc update flow ya no es producto principal. |

### Cambios requeridos en GitHub Actions

| Workflow | Decisión |
|----------|----------|
| Rust CI/test/lint | Mantener. Es el core runtime. |
| Docker/service images | Mantener si sirven para servicios del runtime. |
| bootc image build/release | Archivar, desactivar o mover a manual/legacy. |
| release channels bootc | Reescribir o congelar como legacy. |
| nightly OS image | Desactivar hasta nueva decisión. |
| truth/docs drift | Actualizar reglas para detectar claims obsoletos de distro. |

### Nueva taxonomía pública

Para evitar repetir el error de mezclar repo capability con producto estable:

- **validated on host** — integrado y probado recientemente en hardware real.
- **integrated in repo** — existe en código/runtime, pero no validado recientemente end-to-end.
- **experimental** — base parcial o spike.
- **legacy / archived** — pertenece al camino Fedora bootc/NixOS anterior.

---

## 9. Implicaciones para la web de LifeOS

La landing actual también debe dejar de vender una distribución Linux como promesa central.

### Cambios requeridos en copy

| Área | Cambio |
|------|--------|
| SEO title | De “AI-native Linux” a “personal AI runtime for Linux”. |
| Meta description | Enfatizar runtime/capa personal local-first. |
| Hero | “AI that lives with you” puede quedarse; el body debe decir que corre sobre Linux. |
| Proofs | Reemplazar “Immutable + rollback base” por “Runs over your Linux host”. |
| Principles | Cambiar “AI-native operating system” por “personal operating system layer”. |
| Roadmap | Pasar de estabilizar install/boot/update a estabilizar runtime/onboarding. |
| GitHub CTA | Apuntar a la nueva narrativa del repo. |

### Mensaje web recomendado

> LifeOS is the personal operating system for your digital life: a local-first AI runtime that runs on Linux, remembers with you, acts through Axi, and keeps your context under your control.

Versión español:

> LifeOS es el sistema operativo para tu vida digital: un runtime de IA local-first que corre sobre Linux, recuerda con vos, actúa mediante Axi y mantiene tu contexto bajo tu control.

---

## 10. Implicaciones para LifeOS Lab

Este pivot debe contarse como una evolución, no como fracaso.

### Narrativa pública honesta

> LifeOS Lab empezó explorando qué pasaría si la IA personal viviera en la capa del sistema operativo. Después de construir una base real con Fedora bootc, servicios locales, memoria, SimpleX y control de escritorio, la conclusión fue clara: el valor no está en reemplazar tu distro, sino en llevar esa capa personal a cualquier Linux moderno.

### Cómo se preserva la credibilidad

- No se borra la historia Fedora bootc; se archiva como aprendizaje.
- No se afirma que LifeOS sea kernel/distro completa.
- Se mantiene el término OS como metáfora de producto: sistema operativo para la vida digital.
- Se publican estados reales por capability.
- Se muestra un host real validado: CachyOS primero.

---

## 11. Roadmap de lanzamiento

### Fase 0 — Decisión y freeze

- [ ] Congelar nuevas inversiones en bootc como producto principal.
- [ ] Congelar NixOS migration como spike histórico, no roadmap principal.
- [ ] Mantener backups antes de tocar la laptop o borrar state.

### Fase 1 — Narrativa pública

- [ ] Actualizar README principal.
- [ ] Actualizar landing page.
- [ ] Agregar este PRD al índice de docs.
- [ ] Marcar bootc/NixOS docs como legacy/transitional.
- [ ] Crear una nota pública corta: “LifeOS is becoming a personal AI runtime for Linux”.

### Fase 2 — GitHub/runtime cleanup

- [ ] Revisar GitHub Actions y desactivar builds de imagen OS por default.
- [ ] Mantener CI de Rust/runtime.
- [ ] Separar workflows de imágenes de servicio vs imagen OS legacy.
- [ ] Crear `docs/operations/runtime-install.md`.
- [ ] Definir un primer instalador/profile para CachyOS.

### Fase 3 — CachyOS host profile

- [ ] Documentar prerequisitos: GPU/NVIDIA, audio, desktop, systemd user, Podman/Docker según decisión.
- [ ] Instalar lifeosd + CLI + dashboard como runtime local.
- [ ] Validar memoria persistente.
- [ ] Validar SimpleX loop.
- [ ] Validar GPU Game Guard o degradarlo a experimental si no se valida.

### Fase 4 — Runtime v1 demo

- [ ] Demo: usuario habla con Axi local.
- [ ] Demo: Axi recuerda un dato y lo recupera después.
- [ ] Demo: SimpleX interrumpe y luego la conversación original continúa.
- [ ] Demo: una acción local segura se ejecuta con audit trail.
- [ ] Demo: dashboard muestra estado del runtime.

---

## 12. Métricas de éxito

| Métrica | Target |
|---------|--------|
| Mensaje público consistente | README, landing y docs no se contradicen. |
| Bootc no es producto principal | Workflows OS image no corren por default. |
| CachyOS validated host | Runtime probado en laptop real. |
| Instalación reproducible | Documentación suficiente para repetir setup. |
| Loop de memoria | Guardar/recuperar/corregir memoria funciona end-to-end. |
| SimpleX loop | Usuario puede escribir remoto y Axi responde con contexto. |
| Demo pública | Una demo muestra el loop sin prometer capacidades no validadas. |

---

## 13. Riesgos

| Riesgo | Severidad | Mitigación |
|--------|-----------|------------|
| Parecer que LifeOS “abandonó” el OS | Alta | Comunicar como evolución de arquitectura, no retirada. |
| CachyOS absorbe la identidad | Media | Usar “reference host”, no “LifeOS basado en CachyOS”. |
| Scope v1 demasiado grande | Alta | V1 limitado a Axi + memoria + SimpleX + acciones locales + dashboard. |
| Multimodalidad suena a humo | Media | Clasificar como experimental hasta validación real. |
| Docs antiguas contradicen la nueva narrativa | Alta | Marcar legacy y actualizar README/web primero. |
| GitHub Actions siguen publicando OS images | Media | Desactivar builds automáticos de bootc OS y documentar legacy path. |

---

## 14. Decisiones tomadas

- LifeOS no será, por ahora, una distro completa como producto principal.
- CachyOS será el primer host de referencia de desarrollo diario.
- Fedora bootc queda como historia técnica/legacy, no como promesa pública central.
- NixOS queda como spike útil, no como dirección principal inmediata.
- LifeOS se comunicará como sistema operativo personal/de vida digital.
- El primer lanzamiento público debe enfocarse en narrativa + runtime loop, no en ISO.

---

## 15. Decisiones pendientes

- [ ] ¿El runtime se instala primero como binarios nativos, contenedores, systemd user services o mezcla?
- [ ] ¿La web app vive dentro de `lifeosd` o como app separada empaquetada?
- [ ] ¿Cuál es el primer set estable de tools locales?
- [ ] ¿Qué claims actuales del README se degradan a experimental?
- [ ] ¿Se archivan workflows bootc o se dejan manuales para investigación?
- [ ] ¿Cómo se va a nombrar públicamente el canal legacy? (`LifeOS OS Legacy`, `LifeOS bootc prototype`, etc.)

---

## 16. Primer paso de implementación

El primer PR no debe tocar lógica de runtime. Debe ser un PR de narrativa y verdad pública:

1. Actualizar README principal.
2. Actualizar landing page copy.
3. Linkear este PRD desde `docs/README.md`.
4. Marcar NixOS/bootc docs como transitional/legacy.
5. No borrar workflows todavía; solo dejar claro qué está activo y qué queda legacy.

Después de ese PR, el segundo PR debe revisar GitHub Actions y separar runtime CI de OS image legacy.
