# Análisis Competitivo Basado en Datos: OpenClaw vs LifeOS

Este documento resume lecciones prácticas del ecosistema de agentes autónomos en 2026 y cómo convertirlas en decisiones técnicas para **LifeOS**.

## 1. El Fenómeno OpenClaw

OpenClaw demostró que existe demanda real por agentes que ejecutan tareas completas (shell, browser, APIs) con proactividad.

- **Qué popularizó:** ejecución autónoma + *heartbeats* + cron para seguimiento sin intervención continua.
- **Qué expuso:** superficie de ataque muy grande cuando el agente puede invocar tools poderosas sin controles fuertes por capa.

## 2. Alternativas en el ecosistema (y por qué importan)

1. **NanoClaw:** prioriza aislamiento estricto por contenedor para reducir blast radius.
2. **Nanobot (MCP):** minimalismo + estandarización de tools vía Model Context Protocol.
3. **SuperAGI:** enfoque enterprise para orquestación multi-agente especializada.

## 3. Ventaja estructural de LifeOS

Las alternativas anteriores son aplicaciones sobre sistemas generalistas. **LifeOS es plataforma + política + runtime**.

### A. Aislamiento por diseño

Con `bootc/composefs` y raíz inmutable, un agente comprometido tiene menos capacidad de mutar el sistema base.

### B. Broker de permisos como control de daño

El riesgo principal de prompt injection se reduce cuando toda acción sensible pasa por `life-intents` + broker D-Bus + consentimiento verificable.

### C. Runtime nativo y controlable

`llama-server` (llama.cpp) + orquestación en Rust da mejor control de recursos y superficie operativa más predecible.

## 4. Brechas críticas de LifeOS frente al estado del arte

1. **MCP y extensibilidad real:** tools tipadas, versionadas y con UI nativa (MCP-UI).
2. **Heartbeats productivos:** tareas de bajo consumo con auditoría y límites de frecuencia.
3. **Swarm local jerárquico:** NPU/CPU para clasificación y GPU para carga pesada.
4. **Hardening continuo:** red-team harness estable, pruebas anti-prompt-injection, y SLO operativo de vulnerabilidades.

## 5. Decisiones recomendadas para roadmap

1. **Modelo de confianza de Skills (híbrido):**
   - `core` firmado por LifeOS.
   - `verified` por maintainers delegados y validados por pipeline oficial.
   - `community/local` habilitado con sandbox estricto y permisos mínimos.
2. **SLO CVE por severidad:**
   - `critical`: mitigación <= 24h, parche <= 48h.
   - `high`: parche <= 72h.
   - `medium`: <= 14 días.
3. **Gates obligatorios en CI para agente/runtime:**
   - pruebas de prompt injection indirecta,
   - path traversal,
   - spoofing de identidad de emisor,
   - confusión `rawCommand` vs `argv`.

## Conclusión

OpenClaw validó el mercado, pero también dejó claro que autonomía sin gobernanza degrada seguridad. La apuesta ganadora de LifeOS es: **autonomía útil + riesgo acotado y auditable**, no autonomía ciega.
