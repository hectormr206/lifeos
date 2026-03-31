# LifeOS Estrategia Unificada

Este documento fue dividido en archivos mas pequenos para facilitar la lectura por LLMs y humanos.

## Indice

| Archivo | Contenido | Lineas |
|---------|-----------|--------|
| [vision-y-decisiones.md](vision-y-decisiones.md) | Estrategia core, metricas, riesgos, reglas (secciones 1-12) | ~655 |
| [fases-a-m.md](fases-a-m.md) | Fases completadas A-M (core development) | ~364 |
| [fases-n-aa.md](fases-n-aa.md) | Fases N-AA (desktop operator, gaming, MCP, meetings, security, visual identity) | ~830 |
| [fases-ab-aj.md](fases-ab-aj.md) | Fases AB-AL (roadmap activo) + vision futura (AH/AI/AJ sacadas del consecutivo) | ~460 |
| [competencia.md](competencia.md) | Analisis competitivo detallado (OpenClaw, Devin, Replit, gigantes tech) | ~292 |
| [fase-aq-personalizacion.md](fase-aq-personalizacion.md) | Fase AQ: experiencias personalizadas (10 sub-fases, User Model, adaptacion, proactividad) | ~160 |
| [fase-ar-custom-training.md](fase-ar-custom-training.md) | Fase AR: entrenamiento local de modelos (LoRA/QLoRA, Unsloth, distillation, DPO) | ~280 |
| [mejoras-memoria.md](mejoras-memoria.md) | Mejoras al memory_plane: filtro basura, decay exponencial, dedup, resumen, permanentes | ~80 |
| [fase-as-lifeos-android.md](fase-as-lifeos-android.md) | Fase AS: LifeOS Mobile para Pixel (GrapheneOS, hibrido local+server) | ~120 |
| [fase-at-android-app-nativa.md](fase-at-android-app-nativa.md) | Fase AT: App Android nativa con todos los sentidos de Axi (cualquier telefono) | ~420 |
| [fase-au-seguridad-por-defecto.md](fase-au-seguridad-por-defecto.md) | Fase AU: seguro desde primer boot (firewall, sysctl, SSH, auditd, DNS, USB) | ~130 |
| [fase-av-financiamiento.md](fase-av-financiamiento.md) | Fase AV: financiamiento y sostenibilidad (NLnet, grants, sponsors, monetizacion) | ~60 |
| [fase-aw-cross-platform.md](fase-aw-cross-platform.md) | Fase AW: cross-platform controller (Windows, Mac, Android, iOS clients) | ~80 |

## Estado de Fases (resumen rapido)

### Fases Completadas (A-AP)

| Fases | Descripcion |
|-------|-------------|
| A-M | Core: LLM router, Telegram, supervisor, browser, self-improvement, multimodal |
| N-AA | Desktop operator, gaming, MCP, meetings, security AI, visual identity (657 SVGs) |
| AB-AG | WebSocket gateway, session store, plugin SDK, first-boot, Slack/Discord, dedupe |
| AK | Project Axolotl: 5-layer self-healing (watchdog, safe mode, config store, circuit breaker, sentinel, SQLite) |
| AL | Hardening: SSRF guard, security tests, coverage ratchet, progress events, enhanced doctor, troubleshooting |
| AM | Reloj Perfecto: timezone-aware time en system prompts, memorias, calendario, cron |
| AN | Provider Marketplace: agregar/quitar modelos via Telegram, hot-reload, auto-discovery |
| AO | Telegram UX: reply-to-bot, set_my_commands, markdown, threads, send_file |
| AP | Axi Siempre Libre: async workers + sub-agentes + clasificador rapido |

### Fases Consecutivas Proximas (implementables sin investigacion profunda)

| Fase | Descripcion |
|------|-------------|
| **AQ** | **Experiencias Personalizadas: User Model, adaptacion de tono, prediccion proactiva, contextos, workflows** |
| **AU** | **Seguridad por Defecto: firewall, sysctl, SSH hardening, auditd, DNS seguro, USB guard** |

### Fases de Investigacion (requieren mas research antes de implementar)

| Fase | Descripcion |
|------|-------------|
| **AR** | **Entrenamiento Local: QLoRA fine-tuning, knowledge distillation, DPO, modelos especializados** |
| **AV** | **Financiamiento y Sostenibilidad: NLnet (URGENTE), grants, sponsors, monetizacion** |

### Vision Futura (ideas a largo plazo, no para desarrollo inmediato)

| Fase | Descripcion |
|------|-------------|
| *AH* | *Firefox extension: Axi dentro del navegador* |
| *AI* | *LibreOffice AI: asistente en documentos, hojas de calculo, presentaciones* |
| *AJ* | *Cloud hosting: LifeOS como servicio hospedado* |
| *AS* | *LifeOS Android: companion app + ROM para Pixel 7 Pro* |
| *AT* | *App Android nativa: todos los sentidos de Axi en cualquier telefono* |
| *AW* | *Cross-Platform Controller: LifeOS gobierna Windows, Mac, Android, iOS* |

## Como usar esta documentacion

- **Quieres saber si algo ya existe?** Busca en las fases con `grep "keyword" docs/strategy/fases-*.md`
- **Quieres ver la competencia?** `competencia.md`
- **Quieres ver la vision y reglas?** `vision-y-decisiones.md`
- **Quieres ver los gaps de OpenClaw?** `fases-ab-aj.md` (tabla comparativa al inicio)

Ultima actualizacion: 2026-03-30
