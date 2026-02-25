# LifeOS: AI-Native Linux Distribution

**Versión:** 0.1.0-alpha  
**Estado:** En desarrollo activo  
**Fecha de inicio:** Febrero 2026  

## 🎯 Visión

Primera distribución Linux AI-first realmente masiva:
- Tan fácil de usar como macOS/Windows para usuarios nuevos
- Tan potente como Linux para desarrollo y control total
- Tan confiable que actualizar deje de dar miedo
- Tan inteligente que entienda pantalla, voz, cámara y contexto

## 📁 Estructura del Proyecto

```
lifeos/
├── image/                    # Imagen OCI del sistema
│   ├── Containerfile         # Build principal
│   ├── build.sh             # Script de customización
│   └── files/               # Archivos del sistema
├── cli/                     # CLI `life` (Rust)
├── daemon/                  # lifeosd (Rust)
├── contracts/               # Schemas JSON para intents/identity
├── onboarding/              # Asistente de primer arranque
├── tests/                   # Tests de integración
└── .github/workflows/       # CI/CD
```

## 🚀 Estado Actual

### En Progreso 🟡
- [ ] Fase 0: Fundación técnica (0-3 meses)
  - [ ] Base inmutable bootc + composefs
  - [ ] CLI `life` básico
  - [ ] Pipeline CI/CD

### Pendiente ⚪
- [ ] Fase 1: UX y confiabilidad (3-6 meses)
- [ ] Fase 2: IA multimodal local (6-12 meses)
- [ ] Fase 3: Hive Mind gobernado (12-24 meses)

## 📚 Documentación

- [Especificación completa](../../borradores/lifeos-ai-distribution.md)

## 🤝 Contribuir

Ver `CONTRIBUTING.md` (próximamente)

## 📄 Licencia

Apache 2.0
