# First-IA Roadmap

## Fase 0: Fundación Técnica (0-3 meses) 🏗️

### Semana 1-2: Setup y Arquitectura Base
- [x] Crear estructura del repositorio
- [x] Definir Containerfile base
- [ ] Implementar CLI `life` básico (status, update, rollback)
- [ ] Configurar CI/CD con GitHub Actions
- [ ] Documentar arquitectura base

### Semana 3-4: Sistema Inmutable
- [ ] Configurar bootc con slots A/B
- [ ] Implementar composefs + fs-verity
- [ ] Crear sistema de rollback automático
- [ ] Tests de integración básicos

### Semana 5-6: Gestión de Configuración
- [ ] Implementar parser de `lifeos.toml`
- [ ] Crear sistema de Life Capsule (export/restore)
- [ ] Integrar Flatpak y Toolbx
- [ ] Documentar flujo de configuración

### Semana 7-8: Pipeline CI/CD Completo
- [ ] Construcción de imagen OCI firmada
- [ ] Integración con Sigstore/Cosign
- [ ] Tests automatizados en VM
- [ ] Release automatizado

### Semana 9-12: Polish y MVP
- [ ] Onboarding de primer arranque
- [ ] Documentación de usuario
- [ ] Beta interna
- [ ] ISO instalable

**Entregable Fase 0:** Imagen ISO booteable que se actualiza sin romperse

---

## Fase 1: UX y Confiabilidad (3-6 meses) 🎨

- [ ] Integrar COSMIC desktop
- [ ] Temas LifeOS (Simple/Pro)
- [ ] LifeOS Lab (pruebas previas)
- [ ] Canales de actualización (stable/candidate/edge)
- [ ] Telemetría anónima opt-in
- [ ] Broker de permisos D-Bus
- [ ] Documentación completa

**Entregable Fase 1:** Beta pública con canal stable

---

## Fase 2: IA Multimodal Local (6-12 meses) 🤖

- [ ] Integrar Ollama + llama.cpp
- [ ] Autoselector de modelos por hardware
- [ ] Asistente voz/pantalla/cámara
- [ ] Memoria contextual cifrada
- [ ] `life-intents` operativo
- [ ] `life-id` operativo
- [ ] Modo Jarvis temporal

**Entregable Fase 2:** Release 1.0 con asistente AI

---

## Fase 3: Hive Mind Gobernado (12-24 meses) 🌐

- [ ] Deduplicación global de incidencias
- [ ] CI reproducible (SLSA Level 3)
- [ ] Rollout inteligente por cohortes
- [ ] Life Capsule sync multi-dispositivo
- [ ] Consola de flota
- [ ] SDK para extensiones

**Entregable Fase 3:** Ecosistema autosostenible

---

## Progreso Actual

```
Fase 0: [██░░░░░░░░] 20% 
Fase 1: [░░░░░░░░░░] 0%
Fase 2: [░░░░░░░░░░] 0%
Fase 3: [░░░░░░░░░░] 0%
```

---

*Última actualización: Febrero 2026*
