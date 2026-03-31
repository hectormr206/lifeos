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
| [fase-ax-auditoria-de-realidad.md](fase-ax-auditoria-de-realidad.md) | Fase AX: auditoria de realidad, verificacion por evidencia y cierre de claims rotos | ~140 |
| [auditoria-estados-reales.md](auditoria-estados-reales.md) | Matriz viva de estados reales: que esta validado en host, que esta parcial y que esta solo en repo o feature-flag | ~110 |

## Estado de Fases (resumen rapido)

### Estado Real Actual

| Fases | Descripcion |
|-------|-------------|
| A-E | Base fuerte de producto en repo; A tuvo evidencia host clara |
| F | Parcial: varios bridges existen, pero la imagen por defecto no los shippea habilitados |
| G | Repo integrado: fix de falsos positivos con tests, pendiente deploy host |
| H-M | Mayormente integradas en repo, pero aun no todas estan re-validadas por AX |
| N | Parcial: desktop operator fuerte, pero bateria/API aun tenia claims inflados |
| O | Parcial: desktop operator funciona; skill learning desde uso real no wired |
| P | Repo integrado: gaming assist y captura existen; falta validacion host dedicada |
| Q | Parcial: MCP client/server base funciona; dashboard integration basica |
| R | Repo integrado: pipeline wired end-to-end, pendiente validacion host |
| S | Parcial: health checks existen; reportes diarios/semanales por Telegram no wired |
| T | Parcial: voz funciona (wake word, STT, TTS); no es pipeline Alexa-style completo |
| U | Parcial: prompt evolution y workflow learner existen; full self-improvement loop parcial |
| V | Parcial: knowledge graph existe y se consulta; export/import no implementados |
| W | Parcial: ReliabilityTracker existe; checkpoint/resume y audit trail basicos |
| X | Parcial: traduccion existe en repo, pero no esta integrada como experiencia completa del producto |
| Y | Repo integrado: Security AI existe, pendiente validacion host dedicada |
| AB | Repo integrado: SessionStore conectado a Telegram bridge, persiste across restarts |
| AC | Parcial: registry/manifest si; `life skills doctor` no |
| AD | Parcial: guardrails y `/metrics` si; claims adicionales aun no todos comprobados |
| AE | Repo integrado con incidentes de runtime que siguen bajo vigilancia |
| AF | Repo integrado: Slack/Discord wired a startup, feature-gated; pendiente compilar en imagen |
| AG | Parcial: dedupe y pairing basico si; transcript export y parte de la narrativa de robustez menor no cerraron |
| AK | Repo integrado: `life doctor` + `life safe-mode` CLI implementados, sentinel funcional |
| AL | Parcial: seguridad si, pero doctor/eventos WS/troubleshooting aun no estaban totalmente alineados |
| AM | Repo integrado: tiempo/timezone quedaron bien aterrizados en repo; falta validacion host fina |
| AN | Repo integrado: providers y hot reload tienen evidencia fuerte |
| AO | Parcial: Telegram UX mejorada; webhook es polling-only, no webhook real |
| AP | Repo integrado: worker lifecycle events emitidos a WebSocket; sub-workers pendientes |

### Fases Consecutivas Proximas (implementables sin investigacion profunda)

| Fase | Descripcion |
|------|-------------|
| **AX** | **Auditoria de realidad: seguir corrigiendo claims, fases y docs hasta que 100% vuelva a significar “funciona de verdad”** |
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

Ultima actualizacion: 2026-03-31
