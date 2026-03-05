# LifeOS SOP por Fases (0/1/2)

## 1. Proposito

Estandarizar como ejecutar, validar y cerrar cada fase del roadmap de LifeOS con evidencia tecnica reproducible.

Este SOP complementa:

- `docs/lifeos-ai-distribution.md` (vision + roadmap)
- `docs/BOOTC_LIFEOS_PLAYBOOK.md` (flujo tecnico Bootc)

## 2. Regla general de operacion

Cada item de fase solo se marca como cerrado si incluye:

1. Codigo en repositorio.
2. Prueba automatizada o check reproducible.
3. Evidencia de ejecucion (salida de comando, log o artefacto CI).
4. Documento actualizado (spec, guia o changelog tecnico).

## 3. Fase 0 SOP - Fundacion tecnica

### 3.1 Objetivo

Sistema instalable que arranca, se actualiza y se recupera sin romper seguridad base.

### 3.2 Checklist operativo

- [ ] `podman build -t localhost/lifeos:latest -f image/Containerfile .` exitoso.
- [ ] `bootc container lint` pasa al final del build.
- [ ] Generacion ISO/qcow2 funciona con scripts del repo.
- [ ] `life`, `lifeosd`, `llama-server` presentes en imagen.
- [ ] `llama-server` corre en loopback (`127.0.0.1`).
- [ ] API del daemon requiere bootstrap token.
- [ ] Health checks reportan bootc/disco/red/AI/integridad/baseline.
- [ ] Baseline de seguridad activo: Secure Boot + LUKS2.
- [ ] Validacion TUF previa a update activa.
- [ ] Snapshots Btrfs pre-update operativos.
- [ ] Suite runtime de seguridad pasa en local/CI.

### 3.3 Pruebas minimas obligatorias

```bash
cargo check -p life
cargo check -p lifeosd
cargo test -p life
cargo test -p lifeosd
bash tests/security_tests.sh
podman build -t localhost/lifeos:latest -f image/Containerfile .
```

### 3.4 Evidence pack minimo

- Build log OCI.
- Resultado de tests CLI/daemon.
- Resultado `tests/security_tests.sh`.
- Hash/metadata de ISO generada.

## 4. Fase 1 SOP - UX y confiabilidad

### 4.1 Objetivo

Experiencia diaria usable, rapida y estable para usuario final.

### 4.2 Checklist operativo

- [ ] Overlay AI (`Super+Space`) funcional con latencia objetivo.
- [ ] FollowAlong basico (resumir/traducir/explicar) con consentimiento.
- [ ] Modos de experiencia (Simple/Pro/Builder) funcionales.
- [ ] Politicas por contexto (Workplace) aplicadas por perfil.
- [ ] Scheduler de updates por canal (`stable/candidate/edge`) probado.
- [ ] Telemetria local opt-in para estabilidad (sin exfiltracion por defecto).
- [ ] Accesibilidad minima (WCAG AA) validada en temas principales.
- [ ] Matriz de hardware actualizada y publicada.

### 4.3 Pruebas minimas obligatorias

- Bench p95 de apertura overlay.
- Test de regresion de permisos por contexto.
- Test de update en canal `candidate` + rollback.
- Test de arranque y primer uso en VM limpia.

### 4.4 Evidence pack minimo

- Capturas/video corto de UX clave.
- Reporte de latencias p95.
- Resultado de pruebas de canal de update.
- Documento de compatibilidad de hardware.

## 5. Fase 2 SOP - IA multimodal local

### 5.1 Objetivo

Asistente local multimodal util en tareas reales sin comprometer privacidad.

### 5.2 Checklist operativo

- [ ] Pipeline de modelos local-first con fallback por hardware.
- [ ] Indexado semantico local cifrado (documentos/notas).
- [ ] Capacidades multimodales (texto + contexto de pantalla) bajo permiso.
- [ ] Intents nativos OS con politica y auditoria.
- [ ] `Soul` por usuario y `Skills` versionadas operativas.
- [ ] Life Capsule incluye identidad + skills + memoria (selectivo/restaurable).
- [ ] Medicion de calidad/respuesta en tareas reales definida y activa.

### 5.3 Pruebas minimas obligatorias

- Benchmark local por modelo/perfil.
- Pruebas de permisos para capacidades multimodales.
- Prueba de recuperacion de memoria/skills tras restore.
- Pruebas de seguridad sobre prompt injection indirecta.

### 5.4 Evidence pack minimo

- Reporte de benchmarks por hardware.
- Logs de auditoria de intents sensibles.
- Prueba de restore con estado cognitivo conservado.
- Matriz de riesgo actualizada.

## 6. Fase 2.5 SOP - Identidad visual y ergonomia

### 6.1 Objetivo

Entregar una experiencia visual de calidad producto (consistente, accesible y comoda por horas) sobre COSMIC, con evidencia medible.

### 6.2 Checklist operativo

- [ ] Design tokens oficiales publicados y versionados.
- [ ] Temas LifeOS (dark/light/high-contrast) coherentes en COSMIC y `life theme`.
- [ ] Night Mode desktop completo y validado en entorno grafico real.
- [ ] Motor visual-comfort validado en Wayland (incluyendo manejo explicito de escenarios headless).
- [ ] Presets UX (`balanced/focus/vivid`) disponibles y documentados.
- [ ] Paquete de wallpapers/iconografia LifeOS consistente con la marca.
- [ ] Auditoria WCAG 2.2 AA ejecutada en pantallas/comandos clave.

### 6.3 Pruebas minimas obligatorias

- Pruebas visuales golden + diff en pantallas clave (launcher, terminal, settings, overlay).
- Validacion manual en hardware real: sesion continua >= 3 horas (fatiga visual y legibilidad).
- Benchmark de latencia UI (p95) sin regresion frente a baseline previo.
- Prueba de onboarding visual con usuarios nuevos (tareas guiadas y tasa de exito).

### 6.4 Evidence pack minimo

- Reporte de auditoria de contraste y accesibilidad.
- Capturas/video comparativo antes/despues.
- Resultados de beta UX (SUS y feedback de fatiga visual).
- Changelog de tokens/presets visuales y decisiones de diseno.

## 7. Plantilla de cierre de tarea (usar siempre)

```text
Tarea:
Fase:
Archivos tocados:
Pruebas ejecutadas:
Resultado:
Riesgos residuales:
Docs actualizadas:
```

## 8. Criterio de avance entre fases

1. No avanzar de fase con bloqueantes criticos abiertos de la fase anterior.
2. Si hay bypass temporal de seguridad para laboratorio, debe estar documentado y con fecha de remediacion.
3. Toda metrica objetivo nueva debe tener comando/test para reproducirse.
