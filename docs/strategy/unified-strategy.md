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

## Estado de Fases (resumen rapido)

| Fases | Estado | Descripcion |
|-------|--------|-------------|
| A-M | COMPLETADAS | Core: LLM router, Telegram, supervisor, browser, self-improvement, multimodal |
| N-AA | COMPLETADAS | Desktop operator, gaming, MCP, meetings, security AI, visual identity (657 SVGs) |
| AB-AG | COMPLETADAS | WebSocket gateway, session store, plugin SDK, first-boot, Slack/Discord, dedupe |
| **AK** | **COMPLETADA** | Project Axolotl: 5-layer self-healing (watchdog, safe mode, config store, circuit breaker, sentinel, SQLite) |
| **AL** | **COMPLETADA** | Hardening: SSRF guard, security tests, coverage ratchet, progress events, enhanced doctor, troubleshooting |
| **AM** | **COMPLETADA** | Reloj Perfecto: timezone-aware time en system prompts, memorias, calendario, cron |
| **AN** | **COMPLETADA** | Provider Marketplace: agregar/quitar modelos via Telegram, hot-reload, auto-discovery |
| **AO** | **COMPLETADA** | Telegram UX: reply-to-bot, set_my_commands, markdown, threads, send_file |
| **AP** | **COMPLETADA** | **Axi Siempre Libre: async workers + sub-agentes + clasificador rapido** |
| **AQ** | **PROXIMA** | **Experiencias Personalizadas: User Model, adaptacion de tono, prediccion proactiva, contextos, workflows** |
| *AH/AI/AJ* | *Vision futura* | *Firefox ext, LibreOffice AI, Cloud hosting — sacadas del consecutivo, revisar post-launch* |

## Como usar esta documentacion

- **Quieres saber si algo ya existe?** Busca en las fases con `grep "keyword" docs/strategy/fases-*.md`
- **Quieres ver la competencia?** `competencia.md`
- **Quieres ver la vision y reglas?** `vision-y-decisiones.md`
- **Quieres ver los gaps de OpenClaw?** `fases-ab-aj.md` (tabla comparativa al inicio)

Ultima actualizacion: 2026-03-28
