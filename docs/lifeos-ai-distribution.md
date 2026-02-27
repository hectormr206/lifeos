# LifeOS: AI-Native Linux Distribution

## Especificacion de Producto y Arquitectura

**Version:** 0.1.0 - "Aegis"
**Fecha:** 2026-02-26
**Estado:** Blueprint ejecutable (MVP + Roadmap 24 meses)
**Audiencia:** usuarios principiantes, power users, developers, empresas

---

## 0. Contrato de ejecucion para LLM implementador

Este documento esta escrito para un agente de implementacion (LLM + herramientas) que debe construir LifeOS hasta dejarlo funcional.

### 0.1 Regla principal

- No detenerse en "propuesta" o "borrador": ejecutar, validar y cerrar cada entregable con evidencia.

### 0.2 Criterios operativos obligatorios

1. No introducir placeholders ejecutables (`<...>`, `TBD`, `TODO`) en comandos, scripts, CI o archivos de build.
2. No declarar tareas completas sin pruebas de ejecucion reproducibles.
3. Cada cambio de arquitectura debe reflejarse en:
   - archivos de implementacion,
   - pruebas automatizadas,
   - documentacion de uso.
4. Si una tarea bloquea, continuar con el resto del backlog y registrar bloqueo con causa, impacto y accion siguiente.

### 0.3 Definicion de "100% funcional" para este proyecto

Se considera completado cuando se cumplen todos:

1. [x] Imagen OCI de LifeOS construye en CI sin errores. *`docker.yml` activo.*
2. [ ] ISO generada arranca en VM y en al menos un equipo real soportado. *Pendiente prueba sistematica.*
3. [x] `life status`, `life update --dry`, `life rollback` funcionan end-to-end. *CLI implementado.*
4. [ ] Update atomico + rollback validado por test automatizado. *CLI listo, falta test E2E en VM.*
5. [x] Permisos multimodales (mic/camara/pantalla) auditables y revocables. *Broker D-Bus con prompt real y persistencia de politicas en disco.*
6. [x] Life Capsule export/restore funcional. *Cifrado con `age` + tar + flatpak.*
7. [x] Sync instalado por defecto, pero solo activado tras consentimiento explicito. *`sync.enabled = false` en config.*
8. [x] Pipeline de firma/verificacion de imagen activo. *Cosign + OIDC en CI.*
9. [x] Suite minima de tests pasando en CI. *Tests unitarios + integracion + cargo-audit + CodeQL.*

### 0.4 Modo de lectura para LLM implementador

1. Este documento es **normativo**: implementar lo que esta definido, no reinterpretarlo.
2. Priorizar secciones de ejecucion: `13`, `14`, `18`, `19`, `20`, `21`, `22`, `27`, `28`, `29`.
3. Si hay conflicto entre narrativa y contrato tecnico, gana el contrato tecnico (`life-intents`, `life-id`, CI, tests).
4. No agregar nuevas decisiones de producto sin dejar evidencia tecnica y actualizar este spec.

---

## 1. Vision

LifeOS busca ser la primera distro Linux AI-first realmente masiva:

- Tan facil de usar como macOS/Windows para un usuario nuevo.
- Tan potente como Linux para desarrollo, automatizacion y control total.
- Tan confiable que actualizar deje de dar miedo.
- Tan inteligente que entienda pantalla, voz, camara y contexto (con consentimiento explicito).

**Objetivo de producto:** crear una experiencia "instalas y trabajas" para cualquier nivel, sin sacrificar libertad ni rendimiento.

**Diferenciador clave:** no es una distro con IA encima — es un sistema operativo donde la IA es ciudadano de primera clase en cada capa (shell, escritorio, actualizaciones, diagnostico), pero el usuario siempre decide que se activa.

**Modelo cognitivo:** LifeOS se inspira en un modelo biologico (ver `docs/lifeos_biological_model.md`) donde el sistema tiene:
- **Soul** (ADN): identidad, estilo de interaccion y limites de autonomia por usuario.
- **Skills** (memoria muscular): habilidades aprendidas, reutilizables y firmadas.
- **Workplace** (habitat): contexto digital activo que determina permisos y comportamiento.
- **Agents** (sistema inmunologico): enjambre de agentes especializados gobernados por politicas.
- **Life Capsule** (mitosis): replicacion y recuperacion del organismo completo en otro hardware.

---

## 2. Principios no negociables

1. **No romper produccion:** actualizaciones atomicas, rollback automatico, pruebas previas obligatorias.
2. **Privacidad local-first:** procesamiento local por defecto; nube opcional y cifrada.
3. **IA util, no invasiva:** todo acceso a pantalla/camara/microfono requiere permisos claros, auditables y revocables.
4. **UX sin fatiga:** tipografia, contraste, color y animaciones adaptativas para jornadas largas.
5. **Un sistema para todos:** modo simple para principiantes, modo pro para expertos, mismo core.
6. **Reproducibilidad:** estado del sistema declarativo y portable entre equipos.
7. **Offline-first:** todas las funciones esenciales deben operar sin conexion a internet.

---

## 3. Experiencia para todos los niveles

### 3.1 Tres modos de experiencia

| Modo        | Perfil                    | Que ve el usuario                                                               |
| ----------- | ------------------------- | ------------------------------------------------------------------------------- |
| **Simple**  | Principiantes, uso diario | Interfaz limpia, centro de tareas AI, ajustes guiados, lenguaje natural.        |
| **Pro**     | Power users, sysadmins    | Accesos rapidos, paneles avanzados, observabilidad de sistema, metricas.        |
| **Builder** | Developers, DevOps        | Toolchains, contenedores dev, automatizacion, pipelines locales, depuracion AI. |

El usuario puede cambiar de modo en cualquier momento, sin reinstalar. Los modos son capas de UI sobre el mismo sistema, no builds separados.

### 3.2 Escritorio + consola como un solo flujo

- **Desktop AI-first:** launcher semantico (busca por intencion, no solo por nombre), panel de acciones, asistencia contextual.
- **Terminal de nueva generacion:** texto, imagenes, tablas, logs enriquecidos, acciones en lenguaje natural integradas.
- **Comando unificado `life`:** API humana del sistema.

```
life status          # estado general del sistema
life recover         # recuperar de un fallo
life sync            # sincronizar con otros dispositivos
life focus           # activar modo Flow
life update --dry    # simular actualizacion sin aplicar
life ai ask "..."    # pregunta al asistente local
life capsule export  # exportar estado completo
```

### 3.3 Onboarding inteligente

El primer arranque incluye un asistente que:

1. Detecta hardware y configura drivers automaticamente.
2. Pregunta perfil de uso (personal, desarrollo, creativo, servidor).
3. Sugiere modo de experiencia y apps basadas en el perfil.
4. Configura backup cifrado y Life Capsule.
5. Explica Sync y solicita consentimiento explicito para activarlo.
6. Ofrece tutorial interactivo adaptado al nivel del usuario.

### 3.4 Despliegue administrado: `trust_me_mode`

Para laboratorios, empresas o despliegues internos controlados:

1. `trust_me_mode` existe, pero inicia en `false` por defecto.
2. Solo puede activarse con politica firmada (`consent_bundle`) por administrador autorizado.
3. Al activarse, permite auto-habilitar perfil AI-first (`voice` + `screen_capture`) tras primer login.
4. Nunca omite el `kill switch`, la auditoria ni la revocacion de permisos.
5. Debe quedar evidencia en ledger de quien activo el modo, cuando y con que politica.

---

## 4. Arquitectura base (inmutable y autocurativa)

### 4.1 Modelo del sistema

```
┌─────────────────────────────────────────────┐
│              Espacio de usuario              │
│  /home (datos)  /var (estado)  /etc (config) │
├─────────────────────────────────────────────┤
│         Capa inmutable (composefs)           │
│  /usr (sistema, solo lectura, verificado)    │
├─────────────────────────────────────────────┤
│     Slots A/B (imagenes OCI via bootc)       │
├─────────────────────────────────────────────┤
│   OSTree (almacenamiento + deduplicacion)    │
├─────────────────────────────────────────────┤
│         Btrfs (subvolumenes + snapshots)     │
├─────────────────────────────────────────────┤
│    Secure Boot + TPM + cifrado de disco      │
└─────────────────────────────────────────────┘
```

- **Base inmutable:** imagen OCI firmada desplegada via bootc. La capa `/usr` es de solo lectura en composefs con fs-verity (errores de I/O a nivel kernel si alguien intenta modificarla).
- **Despliegue atomico** en slots A/B gestionados por bootc.
- **Separacion estricta:** sistema (`/usr`) inmutable, estado de usuario (`/var`, `/home`, `/etc`) mutable y versionado.
- **Snapshots Btrfs** antes de cada cambio critico en `/var` y `/home`.

### 4.2 Politica de actualizacion segura

```
Descargar imagen OCI firmada
        │
        ▼
Verificar firma + integridad (Sigstore + composefs/fs-verity)
        │
        ▼
Instalar en slot inactivo (bootc switch)
        │
        ▼
Correr pruebas de salud en slot inactivo
        │
        ▼
Reiniciar al nuevo slot
        │
        ▼
    ¿Arranco OK?
   /          \
  SI           NO
  │            │
  ▼            ▼
Confirmar   Rollback automatico
slot        al slot previo (<60s)
```

### 4.3 Aislamiento de aplicaciones

| Tipo                | Tecnologia                       | Uso                                                                          |
| ------------------- | -------------------------------- | ---------------------------------------------------------------------------- |
| Apps graficas       | Flatpak + xdg-desktop-portal     | Aislamiento sandbox + permisos declarativos.                                 |
| Entornos dev        | Toolbx + Podman                  | Containers mutables sin tocar el sistema base. Toolbx mantenido por Red Hat. |
| Servicios sensibles | microVMs (cloud-hypervisor/QEMU) | Aislamiento fuerte para cargas no confiables.                                |
| AI models           | Contenedores OCI dedicados       | Runtime aislado con acceso controlado a GPU/NPU.                             |

**Resultado:** instalar software nunca rompe el sistema base.

### 4.4 Gestion de configuracion declarativa

El estado del sistema se describe en un archivo `lifeos.toml`:

```toml
[system]
channel = "stable"
mode = "pro"
locale = "es_MX.UTF-8"

[apps]
flatpak = ["org.mozilla.Firefox", "com.spotify.Client"]
toolbox = ["ubuntu-dev", "fedora-build"]

[ai]
enabled = true
provider = "llama-server"
model = "qwen3-8b-q4_k_m.gguf"
llama_server_host = "http://localhost:8080"
voice = false
screen_capture = false
camera = false

[sync]
enabled = false
targets = []
```

Este archivo es portable: restaurar un equipo es `life capsule restore`.

---

## 5. IA multimodal real (pantalla, voz, camara, contexto)

### 5.1 Arquitectura de IA

```
┌──────────────────────────────────────┐
│          Aplicaciones/CLI            │
│    (life ai, launcher, terminal)     │
├──────────────────────────────────────┤
│     API unificada (D-Bus + REST)     │
├──────────────────────────────────────┤
│       Orquestador de modelos         │
│  ┌──────────────┬─────────────────┐  │
│  │ llama-server │  Nube (opcional) │  │
│  │ (por defecto)│  cifrada E2E     │  │
│  └──────────────┴─────────────────┘  │
├──────────────────────────────────────┤
│      Enrutador de tareas             │
│  (selecciona por costo/latencia/     │
│   calidad/privacidad)                │
├──────────────────────────────────────┤
│   Memoria local cifrada (SQLite +    │
│   embeddings vectoriales)            │
├──────────────────────────────────────┤
│   Hardware: CPU / GPU / NPU          │
└──────────────────────────────────────┘
```

- **llama-server (llama.cpp) como unico runtime local:** API OpenAI-compatible en puerto 8080, soporte GGUF nativo, optimizacion por hardware (CUDA, ROCm, Vulkan). Sin dependencias externas. El modelo por defecto es `qwen3-8b-q4_k_m.gguf` con fallback a `qwen3-1.7b-q4_k_m.gguf` en equipos con poca RAM.
- **Nube opcional:** solo se activa si el usuario la configura explicitamente. Todas las consultas en nube son cifradas E2E.
- **Enrutador inteligente:** tareas simples (clasificacion, OCR) van a modelos pequenos locales; tareas complejas (generacion larga, analisis multi-documento) pueden ir a modelos grandes locales o nube segun politica del usuario.
- **Nota:** Ollama fue evaluado y descartado como dependencia por riesgo de continuidad (startup con funding limitado, sin modelo de ingresos claro). llama-server ofrece el mismo rendimiento con comunidad mas grande y sin single point of failure.

### 5.2 Capacidades nativas

| Modalidad | Funcion                                           | Tecnologia                              | Requisito                      |
| --------- | ------------------------------------------------- | --------------------------------------- | ------------------------------ |
| Vision    | Analisis de pantalla, OCR en tiempo real          | Modelos vision-language locales         | Permiso explicito por sesion   |
| Voz       | Hotword local, dictado, comandos conversacionales | Whisper.cpp / modelos STT locales       | Permiso de microfono           |
| Camara    | Deteccion de postura/fatiga                       | Modelos ligeros de pose                 | Opt-in, nunca obligatorio      |
| Contexto  | Correlacion entre apps, archivos y actividad      | Embeddings locales + grafo de actividad | Permiso de lectura de contexto |

### 5.3 Privacidad y control de usuario

- Acceso a camara/mic/pantalla **desactivado antes del consentimiento inicial**.
- En modo AI-first, tras consentimiento en onboarding, se activa el perfil `always-on` (voz+pantalla) automaticamente.
- Permisos **por aplicacion, por sesion y por modalidad**.
- Indicador visual permanente (LED de notificacion en COSMIC) cuando hay captura activa.
- Boton **"kill switch" global** para sensores (atajo de teclado + widget).
- Log auditable: que proceso accedio a que recurso, cuando y por cuanto tiempo.
- **Exportacion de logs** para auditoria externa.

### 5.4 Politica de seleccion automatica de modelos locales (obligatoria)

El sistema **no** fija un solo modelo para todos. Debe seleccionar automaticamente segun hardware real y pruebas locales.

Regla de producto:

1. En primer arranque, ejecutar `life ai profile` para detectar RAM, VRAM, NPU, CPU, almacenamiento y energia disponible.
2. Cargar `model-catalog` firmado (con fallback local embebido en la ISO si no hay red).
3. Ejecutar `life ai benchmark --short` sobre candidatos por rol (`general`, `reasoning`, `vision`, `embeddings`).
4. Elegir el mejor candidato que cumpla umbrales de UX (latencia, memoria, estabilidad), no solo benchmark de calidad.
5. Persistir resultado en `lifeos.toml` + `model-profile.toml`.
6. Re-evaluar semanalmente o cuando cambie hardware/driver/model-catalog.

### 5.5 Matriz inicial recomendada (baseline fecha 2026-02-26)

Esta matriz es semilla de arranque. En runtime manda el autoselector.

| Clase de hardware                          | General (chat/codigo)                | Reasoning                     | Vision/OCR             | Embeddings         |
| ------------------------------------------ | ------------------------------------ | ----------------------------- | ---------------------- | ------------------ |
| `lite` (8-16 GB RAM, sin GPU dedicada)     | `qwen3:4b` (o `qwen3:0.6b` fallback) | `deepseek-r1:1.5b` (opcional) | `gemma3:4b`            | `nomic-embed-text` |
| `balanced` (16-32 GB RAM, iGPU o GPU 8 GB) | `qwen3:8b`                           | `deepseek-r1:8b`              | `gemma3:4b`            | `nomic-embed-text` |
| `pro` (32-64 GB RAM, GPU 12-24 GB)         | `qwen3:14b`                          | `deepseek-r1:14b`             | `gemma3:12b`           | `nomic-embed-text` |
| `workstation` (>=64 GB RAM o GPU >=24 GB)  | `qwen3:30b`                          | `deepseek-r1:32b`             | `gemma3:27b` (si cabe) | `nomic-embed-text` |

Notas operativas:

1. `general` debe priorizar experiencia en espanol e instrucciones largas.
2. `reasoning` se activa por politica, no para cada prompt (control de costo/latencia).
3. Si vision grande no cabe, degradar a modelo menor y mantener UX estable.
4. Los modelos se descargan on-demand; no bloquear onboarding por descargas largas.

### 5.6 Criterios de eleccion del autoselector

Un candidato solo califica si cumple simultaneamente:

1. `first_token_ms_p95 <= 1800` en perfil `balanced` (ajustable por clase).
2. `tokens_per_sec >= 12` para `general` en perfil `balanced`.
3. `peak_memory <= 70%` del presupuesto AI configurado.
4. `crash_rate = 0` en benchmark corto.
5. Calidad minima en suite local (`lifeos-eval`) por rol.

Si ningun candidato pasa:

1. degradar de tamano,
2. desactivar `reasoning` por defecto,
3. ofrecer cloud fallback solo si el usuario lo permite.

### 5.7 Runtime AI-first en tiempo real (sin saturar hardware)

Regla operativa clave: **no cargar todos los modelos grandes a la vez**.

Arquitectura de ejecucion:

1. **Sensores always-on (post-consent):** captura de audio/pantalla/camara en modo liviano y event-driven.
2. **Micro-modelos residentes:** VAD/hotword, intent classifier corto, embedding incremental.
3. **Un solo slot pesado activo (`heavy_slot=1`):** `general` o `reasoning` o `vision` segun tarea activa.
4. **Conmutacion por prioridad:** si entra tarea critica (ej. reunion), se desaloja modelo pesado actual y se carga el requerido.
5. **Precalentamiento controlado:** mantener solo KV-cache y contexto minimo para reducir latencia sin duplicar carga.
6. **Degradacion automatica:** si hay presion termica/RAM, bajar tamano de modelo o frecuencia de inferencia.

Objetivo UX:

1. Hablar y escuchar desde primer minuto post-onboarding.
2. Responder rapido sin congelar escritorio.
3. Mantener bateria/temperatura dentro de limites del perfil activo.

---

## 6. Interfaz sin cansancio visual

### 6.1 Motor de confort visual

- Ajuste dinamico de temperatura de color y brillo segun hora y luz ambiental (integracion con sensores del hardware).
- Escalado tipografico adaptativo: fuentes mas grandes y contraste mas alto conforme avanza la jornada.
- Perfil de contraste por tarea: codigo (alto contraste), lectura (sepia calido), diseno (colores neutros), reuniones (bajo brillo).
- Reduccion inteligente de animaciones tras periodos largos de uso.

### 6.2 Diseno del entorno

- Jerarquia visual clara, ruido minimo, feedback inmediato.
- Temas oficiales validados para accesibilidad (WCAG 2.2 AA minimo).
- **Modo Flow:** foco profundo — silencia notificaciones, oculta distracciones, activa timer pomodoro opcional.
- **Modo Meeting:** prioriza audio/video, suprime ruido de notificaciones, activa supresion de ruido de fondo.
- **Modo Night:** reduce luz azul progresivamente, baja brillo, tipografia mas grande.

### 6.3 COSMIC como desktop base

COSMIC (Epoch 1, estable desde diciembre 2025) es el escritorio principal:

- Escrito en Rust: rendimiento predecible, menos crashes.
- Tiling + stacking nativo: productividad sin configuracion manual.
- Temas y configuracion sincronizable (COSMIC Sync, roadmap Epoch 2).
- Extensible via applets para integrar funciones AI de LifeOS.
- Disponible en multiples distros: facilita portabilidad del ecosistema.

---

## 7. Auto-mejora diaria sin romper el equipo

### 7.1 LifeOS Lab (gemelo digital)

Cada equipo incluye un entorno aislado para ensayo:

- **Container/microVM** que replica la imagen del sistema y configuracion del usuario.
- Ejecucion de pruebas antes de tocar el sistema principal.
- Benchmarks comparativos: rendimiento, bateria, temperatura, estabilidad.
- Accesible via `life lab start` / `life lab test` / `life lab report`.

### 7.2 Pipeline de mejora autonoma

```
1. Detectar problema/oportunidad (metricas, logs, errores)
        │
2. Reproducir en lifeos-lab (container aislado)
        │
3. Generar candidato de mejora (config, parche, modelo)
        │
4. Test suite: funcional + seguridad + regresion + rendimiento
        │
5. ¿Aprueba? ──NO──> Descartar + log de fallo
        │
       SI
        │
6. Canary local (1-24h de observacion)
        │
7. ¿Canary OK? ──NO──> Rollback + incidente automatico
        │
       SI
        │
8. Promover a sistema principal
```

### 7.3 SLOs de confiabilidad (objetivo)

| Metrica                            | Objetivo      | Medicion                               |
| ---------------------------------- | ------------- | -------------------------------------- |
| Exito de arranque post-update      | >= 99.95%     | Telemetria anonima + boot health check |
| Tiempo maximo de rollback          | < 60 segundos | bootc slot switch + reboot             |
| Updates bloqueadas sin pruebas     | 100%          | Pipeline obligatorio                   |
| Recuperacion de fallo critico      | < 5 minutos   | lifeos-lab + auto-repair               |
| Disponibilidad del asistente local | >= 99.9%      | Healthcheck del orquestador AI         |

---

## 8. Red global de mejora (Hive Mind) sin riesgo de malware

### 8.1 Principio rector

**P2P de parches ejecutables entre usuarios no es viable** para una distro masiva. Toda mejora pasa por un pipeline central verificado.

### 8.2 Modelo hibrido

- **Telemetria tecnica anonima** + deduplicacion global (opt-in en primer arranque, desactivable).
- **Contribuciones por PR firmadas** y revisadas por maintainers (obligatorio para cambios al sistema).

### 8.3 Que SI comparten las instalaciones

- Fingerprints anonimos de errores (sin datos personales).
- Metricas de exito/fracaso por perfil de hardware.
- Evidencia de reproduccion (logs saneados, hashes, trazas minimizadas).
- Estado de "trabajo en progreso" para evitar duplicar esfuerzos entre contribuidores.

### 8.4 Que NO comparten las instalaciones

- Binarios sin firma.
- Scripts autoejecutables de otros usuarios.
- Cambios al sistema base fuera del pipeline oficial.
- Datos de usuario, historiales o contexto del asistente AI.

### 8.5 Flujo de gobierno de mejoras

```
1. Nodo reporta problema (anonimo, deduplicado, hash unico)
        │
2. Plataforma central agrupa incidencias similares
        │
3. Se crea issue tecnico global con prioridad calculada
        │
4. Maintainers/comunidad envian PR firmadas (Sigstore)
        │
5. CI valida: pruebas + seguridad + reproducibilidad + SLSA attestation
        │
6. Release firmada se despliega: canary (1%) → candidate (10%) → stable (100%)
```

---

## 9. Seguridad de extremo a extremo

### 9.1 Cadena de confianza

```
Hardware (TPM) → Firmware → Secure Boot → Kernel firmado
    → initramfs verificado → composefs + fs-verity (sistema)
    → Flatpak (apps) → xdg-desktop-portal (permisos)
```

- Secure/Measured Boot + TPM 2.0.
- Cifrado de disco por defecto (LUKS2 + TPM unlock opcional).
- Actualizaciones firmadas y verificadas en cada capa.
- Revocacion de artefactos comprometidos via TUF.

### 9.2 Seguridad de supply chain

| Framework           | Funcion                                                                        | Estado de adopcion                            |
| ------------------- | ------------------------------------------------------------------------------ | --------------------------------------------- |
| **TUF**             | Metadatos de actualizacion con proteccion contra replay/rollback/mix-and-match | CNCF graduated, usado por Sigstore y PyPI     |
| **Sigstore/Cosign** | Firmas keyless de artefactos OCI                                               | Estandar en cloud-native, integrado en Podman |
| **in-toto**         | Attestations del pipeline de build                                             | CNCF project, adoption creciente              |
| **SLSA**            | Niveles de madurez de build (target: Level 3)                                  | Spec v1.0 estable, GitHub Actions compatible  |

### 9.3 Seguridad en tiempo de ejecucion

- Politicas de sandbox por app (Flatpak portals + SELinux/AppArmor).
- Minimo privilegio por defecto.
- Escaneo de vulnerabilidades continuo de la imagen base.
- Respuesta automatizada: aislamiento → rollback → hotfix.

### 9.4 Modo Jarvis: permisos maximos, ejecucion controlada

Para lograr una experiencia tipo Jarvis (IA con control amplio del sistema), LifeOS implementa un modelo de **privilegios temporales auditables**:

- **Permiso potencial total:** el usuario puede autorizar control amplio de sistema.
- **Sesiones temporales:** 15-60 minutos con expiracion automatica. No hay modo "Jarvis permanente".
- **Separacion de funciones:** el modelo AI propone planes; un daemon privilegiado (`lifeosd`) ejecuta acciones tipadas y auditables.
- **Tokens de capacidad:** cada accion se firma con alcance, contexto y TTL (camara, mic, pantalla, red, system-write).
- **Politica por riesgo:**
  - Lectura / acciones reversibles: auto-aprobadas.
  - Acciones destructivas, red externa, cambios criticos: confirmacion biometrica o PIN.
- **Kill switch global:** desactiva en un paso todos los sensores y la autonomia (atajo: `Super+Escape`).
- **Log completo:** cada sesion Jarvis genera un reporte auditable exportable.

### 9.5 Capacidades de auto-defensa (inspiradas en sistemas autonomos)

**Lo que SI implementamos:**

- Conciencia situacional unificada (estado de sistema, apps, sensores, red).
- Coordinacion distribuida para deduplicar incidentes y acelerar mejoras.
- Auto-reparacion guiada por pruebas con rollback obligatorio.
- Operacion degradada offline (sin perder funciones esenciales).
- Respuesta proactiva ante anomalias (aislar, contener, remediar).

**Lo que excluimos explicitamente:**

- Sin autopreservacion del agente (el usuario puede apagar la IA en cualquier momento).
- Sin auto-replicacion de codigo.
- Sin ejecucion de binarios/parches P2P no firmados.
- Sin bypass del consentimiento del usuario en acciones de alto impacto.
- Sin recoleccion de datos sin consentimiento, bajo ninguna circunstancia.

### 9.6 Identidad agentica, delegacion y anti-prompt-injection

Para operar autonomia amplia sin romper seguridad, LifeOS separa identidad humana e identidad de agentes:

1. **Agent ID obligatoria por proceso:** cada agente corre con identidad propia (`agent://<name>/<instance>`) y nunca reutiliza identidad humana.
2. **Delegacion explicita:** el usuario delega capacidades concretas (`calendar.read`, `mail.send`, `fs.write`, `ssh.exec`) con TTL y alcance.
3. **Tokens de capacidad firmados:** toda accion privilegiada exige token con `who/what/why/ttl/risk`.
4. **Workspace aislado por objetivo:** tareas de alto riesgo o externas corren en workspace/sandbox separado del sistema principal.
5. **Poliza anti-inyeccion:** contenido no confiable (web, correo, documentos) no puede invocar acciones directas sin pasar por `plan -> preview -> policy`.
6. **Trazabilidad juridica/forense:** cada accion guarda cadena de decision completa y evidencia reproducible.

---

## 10. Continuidad total: tu sistema en 1 o 10 PCs

### 10.1 LifeOS ID + Life Capsule

Cada usuario tiene una identidad y un estado portable:

| Componente    | Contenido                                     | Sync                 |
| ------------- | --------------------------------------------- | -------------------- |
| Configuracion | `lifeos.toml` + settings de COSMIC            | Tiempo real          |
| Apps          | Lista de Flatpaks + Toolbx configs            | Bajo demanda         |
| Dotfiles      | Shell, editor, git, SSH configs               | Tiempo real          |
| Secretos      | Llaves, tokens, credenciales (cifrado E2E)    | Manual o tiempo real |
| Datos         | Por politicas: trabajo/personal/media/pesados | Configurable         |
| AI Context    | Memoria del asistente (cifrada, local)        | Opcional, cifrada    |

### 10.2 Sync por defecto (feature instalada, activacion explicita)

- El cliente de Sync viene instalado por defecto en todas las instalaciones.
- `sync.enabled` inicia en `false` hasta consentimiento explicito del usuario.
- Tras login de LifeOS ID y aceptacion de terminos, se activa `sync.enabled = true`.
- Cifrado extremo a extremo (el servidor de sync nunca ve contenido en claro).
- Sincronizacion en tiempo real entre dispositivos autorizados.
- Versionado y snapshots para recuperar estados anteriores.
- Restauracion guiada en nuevo equipo: `life capsule restore` → equipo listo en minutos.
- Resolucion de conflictos por politica (ultimo dispositivo gana, merge manual, o prioridad por dispositivo).

### 10.3 Escenarios clave

| Escenario              | Solucion                                                                                                            |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------- |
| **Equipo robado**      | Instalar LifeOS en otro equipo → autenticar LifeOS ID → restaurar Life Capsule → revocar equipo robado remotamente. |
| **2+ PCs en paralelo** | Mismo entorno, mismas apps, misma configuracion, conflictos resueltos por politica.                                 |
| **Modo viaje/USB**     | Entorno portable cifrado para uso temporal sin contaminar host.                                                     |
| **Onboarding empresa** | Nuevo empleado recibe una Life Capsule corporativa → equipo productivo en <30 minutos.                              |

---

## 11. Paralelismo y uso total del hardware

### 11.1 Gestion de recursos

- Scheduler con cgroups v2 para repartir CPU/GPU/NPU por prioridad.
- Jobs AI en background solo cuando no afectan trabajo interactivo.
- Deteccion automatica de hardware: NVIDIA (CUDA), AMD (ROCm), Intel (oneAPI), NPUs.

### 11.2 Perfiles de rendimiento

| Perfil          | CPU         | GPU/NPU           | AI                    | Ventiladores |
| --------------- | ----------- | ----------------- | --------------------- | ------------ |
| **Rendimiento** | Sin limites | Prioridad alta    | Sin limites           | Maximo       |
| **Balanceado**  | Normal      | Compartido        | Background throttled  | Auto         |
| **Bateria**     | Limitado    | Solo bajo demanda | Modelos pequenos      | Minimo       |
| **Silencioso**  | Limitado    | Solo bajo demanda | Background suspendido | Pasivo       |

### 11.3 Telemetria de hardware

- Monitoreo termico para evitar thermal throttling agresivo.
- Colas paralelas para compilacion, indexado, inferencia y sync.
- Panel de observabilidad en tiempo real (modo Pro/Builder).

### 11.4 Planificador heterogeneo AI (NPU/GPU/CPU)

LifeOS adopta un modelo de enrutamiento inspirado en sistemas comerciales AI-first:

1. **Ruta preferente NPU** para tareas de inferencia continua y baja potencia.
2. **Fallback deterministico** a GPU/CPU cuando no hay NPU compatible o el modelo no cabe.
3. **Politica por objetivo:** latencia, consumo, privacidad y costo definen el device target.
4. **No bloqueo del usuario:** cargas AI de background se degradan o pausan si afectan la UX interactiva.

### 11.5 Gaming y Gráficos Híbridos (Nvidia Optimus)

Dado que muchos usuarios de alto rendimiento utilizan hardware híbrido (como Intel + Nvidia RTX para gaming en laptops con pantallas de altas tasas de refresco):

- **Soporte Out-of-the-box para Gaming AAA:** LifeOS vendrá con Steam instalado vía Flatpak u opcional integrado, pre-configurado para aprovechar **Proton** para juegos de Windows (como la saga **Resident Evil**).
- **GPU Switching Transparente (Optimus/PRIME):** Integración nativa a través del CLI y la UI de COSMIC para conmutar modos de GPU (Modo Híbrido, Modo Dedicado Nvidia, Modo Integrado Intel para ahorro máximo de batería).
  - En modo automático, LifeOS usará la GPU dedicada (Nvidia) al lanzar Steam o juegos pesados y volverá a Intel para escritorio normal.
  - La instalación detectará drivers propietarios de Nvidia y los desplegará correctamente vía bootc para no romper en actualizaciones.
- **Sincronización Avanzada:** Soporte para displays de 240Hz, G-Sync (Nvidia) y Adaptive-Sync nativo con Wayland en escritorio COSMIC.

---

## 12. Stack tecnico (actualizado febrero 2026)

| Capa             | Eleccion                              | Razon                                                                                                                 | Estado    |
| ---------------- | ------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | --------- |
| Base OS          | Fedora Image Mode + bootc             | Actualizaciones atomicas OCI, CNCF sandbox (ene 2025). Nota: produccion plena apunta a Fedora 45.                     | Madurando |
| Kernel           | Linux mainline 6.x + parches desktop  | Compatibilidad amplia y baja latencia.                                                                                | Estable   |
| Filesystem raiz  | composefs + fs-verity (sobre Btrfs)   | Inmutabilidad verificable a nivel kernel para `/usr`.                                                                 | Estable   |
| Filesystem datos | Btrfs                                 | Snapshots, subvolumenes, compresion zstd para `/home` y `/var`.                                                       | Estable   |
| Desktop          | **COSMIC Epoch 1** (estable dic 2025) | Rust, tiling nativo, extensible, sync en roadmap.                                                                     | Estable   |
| Audio/Video      | PipeWire + WirePlumber                | Stack unificado de multimedia, baja latencia, estandar en todas las distros mayores.                                  | Estable   |
| Apps GUI         | Flatpak + xdg-desktop-portal          | Aislamiento + permisos declarativos.                                                                                  | Estable   |
| Dev Envs         | Toolbx (principal) + Podman directo   | Containers mutables sin romper base. Toolbx mantenido por Red Hat.                                                    | Estable   |
| AI Runtime       | llama-server (llama.cpp)              | API OpenAI-compatible (puerto 8080), rendimiento maximo, GGUF nativo, sin dependencias externas.                      | Estable   |
| Update Trust     | TUF + Sigstore + in-toto              | Cadena de supply chain verificable de extremo a extremo.                                                              | Estable   |
| Observabilidad   | OpenTelemetry + panel local           | Diagnostico continuo y accionable sin enviar datos a terceros.                                                        | Estable   |

### 12.1 Estrategia de base: Fedora bootc directo

**Decision:** LifeOS construye directamente sobre `quay.io/fedora/fedora-bootc:42`, sin capas intermedias de terceros para la imagen base.

**Implementacion actual:**

```dockerfile
# Stage 1: compilacion de CLI y Daemon (Rust)
FROM fedora:42 AS builder
RUN dnf -y install cargo gcc ... && cargo build --release

# Stage 2: imagen del sistema
FROM quay.io/fedora/fedora-bootc:42
RUN dnf -y install cosmic-desktop ...
# + llama-server (binario pre-compilado o compilado desde fuente)
# + Nvidia drivers (akmod-nvidia, supergfxctl)
# + Herramientas del sistema (toolbox, podman, fish, bat, ripgrep...)
COPY --from=builder life lifeosd  # Binarios Rust compilados
```

Esto nos da:

- **Independencia total** de cualquier proyecto comunitario intermedio.
- **Base mantenida por Red Hat/Fedora** (empresa con compromiso a largo plazo).
- **Control total** del Containerfile y la cadena de firma.

### 12.2 Cadena de confianza propia

LifeOS debe controlar su propia cadena de firma desde dia 1:

```
Fedora base (quay.io/fedora/fedora-bootc:42)
    │ verificar hash SHA256 conocido
    ▼
LifeOS Containerfile (nuestro, auditado, en repo publico)
    │ build en CI aislado (GitHub Actions / self-hosted)
    ▼
Imagen OCI de LifeOS
    │ firmar con Cosign (clave privada en KMS, no en GitHub Secrets)
    ▼
Publicar en GHCR con firma verificable
    │ usuarios verifican con clave publica incluida en la ISO
    ▼
bootc upgrade verifica firma antes de aplicar
```

**Propiedades de la cadena de confianza de LifeOS:**

- Clave privada en KMS (AWS KMS, GCP KMS o Vault), no en GitHub Secrets en claro.
- Verificacion de hash de la imagen base de Fedora antes de construir.
- Build reproducible: cualquiera puede reconstruir la misma imagen desde el Containerfile.
- Log publico de builds con attestations in-toto.

### 12.3 Nota sobre bcachefs

bcachefs fue **removido del kernel Linux (6.18, septiembre 2025)** y ahora es un modulo externo. No debe considerarse como opcion para LifeOS. Btrfs sigue siendo la opcion madura y estable.

### 12.4 Auditoria de dependencias criticas

Cada dependencia del stack fue evaluada por riesgo de abandono, riesgo de supply chain y disponibilidad de alternativas.

#### Dependencias seguras (backing corporativo o CNCF)

| Dependencia          | Quien mantiene               | Backing             | Riesgo |
| -------------------- | ---------------------------- | ------------------- | ------ |
| Fedora bootc         | Red Hat → CNCF Sandbox       | IBM/Red Hat         | Bajo   |
| composefs            | Red Hat → CNCF Sandbox       | IBM/Red Hat         | Bajo   |
| OSTree               | Red Hat                      | IBM/Red Hat         | Bajo   |
| Btrfs                | Meta, SUSE, comunidad kernel | Corporativo diverso | Bajo   |
| PipeWire             | Wim Taymans (Red Hat)        | IBM/Red Hat         | Bajo   |
| Sigstore/TUF/in-toto | CNCF/Google                  | CNCF graduated      | Bajo   |

#### Dependencias con riesgo que requieren mitigacion

**Flatpak — desarrollo estancado, reviewer unico**

Sebastian Wick (Red Hat) declaro en abril 2025 que Flatpak "no esta siendo desarrollado activamente". Alexander Larsson (creador) salio del proyecto. PRs tardan meses. Hubo reactivacion a finales de 2025, pero con un solo reviewer principal.

- **Nivel de riesgo:** Medio-Alto para desarrollo futuro. Bajo para funcionalidad actual.
- **Alternativa:** No hay alternativa real para apps sandbox en Linux (Snap = vendor lock-in de Canonical).
- **Mitigacion:** Aceptar con riesgo consciente. Nunca poner funcionalidad critica del OS detras de Flatpak. Apps esenciales (terminal, archivos, editor) van como parte de la imagen base, no como Flatpaks. RHEL 10 incluye Flatpak, lo que asegura mantenimiento minimo.

**Ollama — descartado como dependencia (decision febrero 2026)**

Ollama Inc tiene ~21 personas, $500K en pre-seed (Y Combinator), sin modelo de ingresos publico. Ademas, su script de instalacion (`curl | sh`) es un vector de supply chain. Tras evaluacion, **LifeOS descarto Ollama** y adopto llama-server (llama.cpp) como unico runtime local.

- **Riesgo residual:** Ninguno. Ollama no es dependencia del sistema.
- **Razon de la decision:** llama.cpp tiene comunidad mas grande, API OpenAI-compatible nativa, soporte GGUF directo y sin single point of failure corporativo.
- **Regla:** NUNCA reintroducir Ollama como dependencia critica sin reevaluacion formal de riesgo.

**Distrobox — eliminado como dependencia, reemplazado por Toolbx**

Distrobox (mantenido por 2 personas, sin funding) fue evaluado como riesgo alto de abandono. Toolbx (Red Hat, incluido en Fedora) ofrece funcionalidad equivalente con respaldo corporativo. Decision: **Toolbx como herramienta principal de containers de desarrollo.** Distrobox puede ser instalado por el usuario si lo prefiere, pero no es parte del sistema base.

**COSMIC desktop — empresa pequena, producto joven**

System76 (~40-60 empleados, ~$5-10M revenue) vende hardware Linux. COSMIC es su apuesta estrategica para Pop!\_OS. Epoch 1 estable desde diciembre 2025.

- **Nivel de riesgo:** Medio para continuidad (depende de ventas de hardware).
- **Alternativa:** GNOME Shell (maduro, respaldado por Red Hat/GNOME Foundation).
- **Mitigacion:** El spec ya incluye fallback a GNOME. Las integraciones AI de LifeOS usan D-Bus (desktop-agnostic), no APIs especificas de COSMIC. Si COSMIC muere, migrar a GNOME requiere solo cambiar la imagen base y temas, no reescribir codigo.

#### Principio general

**Ninguna dependencia critica debe tener un solo punto de fallo sin alternativa documentada.** Para cada componente del stack:

1. Existe un plan B concreto?
2. El plan B requiere reescribir codigo o solo cambiar configuracion?
3. Cuanto tiempo tomaria ejecutar el plan B?

| Componente     | Plan B                                       | Esfuerzo de migracion                  |
| -------------- | -------------------------------------------- | -------------------------------------- |
| Fedora bootc   | CentOS Stream bootc                          | Config (cambiar FROM en Containerfile) |
| COSMIC         | GNOME Shell                                  | Config + temas (1-2 semanas)           |
| Flatpak        | RPMs en imagen base para apps criticas       | Ya mitigado desde dia 1                |
| llama-server   | Compilar desde fuente llama.cpp              | Ya implementado como fallback en build |
| Distrobox      | Toolbx / Podman directo                      | Wrapper en CLI `life` (dias)           |
| PipeWire       | N/A (sin alternativa, pero estable y ubicuo) | No aplica                              |
| Sigstore       | GPG signing tradicional                      | Config en CI (horas)                   |

---

## 13. Decisiones cerradas para implementacion

Esta seccion reemplaza analisis de mercado y deja solo reglas ejecutables para el LLM implementador.

### 13.1 Arquitectura obligatoria

1. **Base inmutable + rollback:** imagen bootc con slots A/B y recuperacion automatica.
2. **Runtime en 3 capas:** `ui`, `agent-orchestrator`, `privileged-executor`.
3. **Contrato unico de accion:** toda accion pasa por `life-intents` y nunca por ejecucion libre fuera del contrato.
4. **Identidad agentica obligatoria:** toda accion privilegiada requiere token valido de `life-id`.
5. **Aislamiento por riesgo:** `sandbox/container/microVM` segun impacto de la accion.

### 13.2 Modos operativos obligatorios

1. `interactive`
2. `run-until-done`
3. `silent-until-done`

Regla: `high/critical` siempre solicita aprobacion humana o politica firmada.

### 13.3 Reglas de entrega tecnica

1. Todo cambio autonomo debe generar evidencia: `plan + acciones + artefactos + resultado`.
2. Todo claim de rendimiento debe tener benchmark reproducible en `lifeos-bench`.
3. Ningun componente critico entra sin alternativa documentada y plan de migracion.
4. El camino de release siempre es: `lab -> candidate -> stable`.

### 13.4 Backlog tecnico minimo (bloqueante)

- [ ] Definir y versionar `contracts/intents/v1` y `contracts/identity/v1`.
- [ ] Implementar `life intents plan/apply/status/validate/log`.
- [ ] Implementar `life id issue/list/revoke`.
- [ ] Implementar `life workspace run` con aislamiento por objetivo.
- [ ] Implementar ledger cifrado y exportable de ejecucion AI.
- [ ] Implementar suite `lifeos-bench` (latencia, energia, calidad por backend).

---

## 14. Roadmap

### Fase 0 (0-3 meses): Fundacion tecnica

**Objetivo:** un sistema que arranca, se actualiza y se recupera de forma confiable.

**Estado:** **100% completado** (27 febrero 2026). Fase 0 cerrada con build reproducible, servicios endurecidos y suite de seguridad automatizada.

**Sistema base:**

- [x] Base inmutable bootc + slots A/B + rollback funcional. *Containerfile sobre `fedora-bootc:42`; CLI `life rollback` llama `bootc rollback` real.*
- [x] Flatpak + Toolbx funcionando sobre la base inmutable. *Instalados en Containerfile; Flathub configurado en first-boot.*
- [x] Btrfs snapshots automaticos antes de cambios criticos. *`lifeos-btrfs-snapshot.sh` + `lifeos-btrfs-snapshot.timer` en imagen y hook pre-update en CLI (`life update`).*
- [x] fs-verity para verificacion de integridad de `/usr`. *Chequeo explicito via `lifeos-integrity-check.sh` y health check `filesystem-integrity` en daemon.*

**Seguridad fundacional:**

- [x] LUKS2 cifrado de disco con desbloqueo TPM opcional. *Enforcement en runtime via `lifeos-security-baseline.service` + `lifeos-security-baseline-check.sh` (falla si root no es LUKS2).*
- [x] Secure Boot + Measured Boot con TPM 2.0. *Enforcement en runtime: validacion de Secure Boot habilitado y deteccion TPM en baseline check.*
- [x] Pipeline CI/CD para construir imagenes OCI firmadas (Sigstore/cosign). *`docker.yml` firma con cosign + OIDC, genera SBOM y provenance.*
- [x] Supply chain security basico: firmas de imagen + TUF. *`lifeosd` valida metadata TUF (`root/timestamp/snapshot/targets`), expiracion y anti-rollback antes de updates.*
- [x] Threat model formal (STRIDE). *`docs/threat_model_stride.md` completo con las 6 categorias y matriz de controles.*
- [x] Endpoints de control en loopback + tokens de bootstrap. *Daemon y llama-server en `127.0.0.1`; middleware obligatorio de bootstrap token en `/api/v1/*`.*
- [x] Suite de regresion de seguridad minima en CI. *`tests/security_tests.sh` valida token bootstrap, bloqueo de path traversal y fail-closed de AI endpoint; job `runtime-security` activo en CI.*

**AI runtime:**

- [x] llama-server (llama.cpp) como runtime AI por defecto con API OpenAI-compatible. *Compilado/descargado en Containerfile; `llama-server.service` systemd funcional.*
- [x] Modelo GGUF default (Qwen3-8B Q4_K_M) descargado en primer arranque. *`lifeos-ai-setup.sh` con deteccion de RAM y fallback a modelo pequeno.*
- [x] Deteccion automatica de GPU (NVIDIA/AMD/Intel) y configuracion de offload. *Implementada en first-boot, daemon y CLI.*
- [x] `llama-server.service` con security hardening. *Incluye `PrivateUsers`, `SystemCallFilter`, `MemoryMax` y bind loopback (`LIFEOS_AI_HOST=127.0.0.1`).*
- [x] API REST del daemon (`lifeosd`) con endpoints de sistema, AI y health. *Chat conectado a `llama-server` real, metricas de recursos reales y token bootstrap enforceado.*

**CLI y configuracion:**

- [x] `lifeos.toml` como formato de configuracion declarativa. *Structs tipados con load/save/get/set por dotted key.*
- [x] CLI `life` con comandos nucleares: `status`, `update`, `rollback`, `recover`. *Todos implementados con logica real.*
- [x] CLI `life ai`: `start`, `stop`, `status`, `ask`, `chat`, `models`, `pull`. *Todos implementados incluyendo streaming SSE y deteccion de GPU.*
- [x] Backup cifrado + restore basico (`life capsule export/restore`). *Usa `age` para cifrado + tar + flatpak restore.*

**Permisos:**

- [x] Centro de permisos basico (D-Bus broker). *Prompt real (`zenity` / `systemd-ask-password`) y persistencia de politicas en `/var/lib/lifeos/permissions-policy.json`.*

**Health checks:**

- [x] `life recover` con diagnostico automatico y reparacion. *Reporte con checks por nombre, pass/fail, reparaciones y reboot flag.*
- [x] Health checks de servicios criticos. *Checks reales de `bootc`, disco con umbral, red, estado AI, integridad `composefs/fs-verity` y baseline de seguridad.*

**Entregable:** imagen ISO booteable con AI local funcional que se actualiza sin romperse.

**Resumen de progreso Fase 0:**

| Categoria          | Total | Done | Parcial | Faltante |
| ------------------ | ----- | ---- | ------- | -------- |
| Sistema base       | 4     | 4    | 0       | 0        |
| Seguridad          | 7     | 7    | 0       | 0        |
| AI runtime         | 5     | 5    | 0       | 0        |
| CLI y config       | 4     | 4    | 0       | 0        |
| Permisos           | 1     | 1    | 0       | 0        |
| Health checks      | 2     | 2    | 0       | 0        |
| **Total**          | **23**| **23** | **0** | **0**    |

**Bloqueantes de Fase 0 cerrados:**

1. `Btrfs snapshot automatico`: script + timer + hook pre-update implementados.
2. `llama-server` en loopback: bind `127.0.0.1` y hardening completado.
3. `Bootstrap token enforcement`: middleware activo en toda la API v1.
4. `Daemon chat endpoint`: conectado a llama-server OpenAI-compatible real.
5. `D-Bus permissions`: prompt real + persistencia de politicas.
6. `Health checks completos`: AI, red, disco (umbrales), integridad y baseline de seguridad.
7. `fs-verity explicito`: verificacion de integridad `/usr` integrada.
8. `LUKS2 + Secure Boot`: enforcement runtime como baseline obligatorio.
9. `TUF`: validacion de metadata + anti-rollback en update path.
10. `Runtime security CI`: job dedicado con pruebas de token/path traversal/fail-closed.

### Fase 1 (3-6 meses): UX y confiabilidad

**Objetivo:** un escritorio usable que la gente quiera usar diario.

**Escritorio y UX:**

- [ ] COSMIC Epoch 1 configurado con temas LifeOS.
- [ ] Tres modos de experiencia: Simple, Pro y Builder (misma base, distinta UI).
- [ ] Motor de confort visual: temperatura de color, tipografia adaptativa, perfiles de contraste.
- [ ] Modos contextuales: Focus (Deep Focus/Flow), Meeting, Night.
- [ ] Accesibilidad WCAG 2.2 AA minimo en todos los temas.
- [ ] xdg-desktop-portal integrado para sandboxing de permisos de apps.
- [ ] Applet AI del escritorio con invocacion `Super+Space` y overlay contextual sobre cualquier app.
- [ ] FollowAlong v1: acciones contextuales sobre texto seleccionado (resumir, traducir, explicar) con consentimiento y auditoria.

**Primer arranque y onboarding:**

- [ ] First-boot wizard: deteccion de hardware, seleccion de perfil, drivers, consentimiento AI/sync.
- [ ] Trust Me Mode: consent bundles firmados, activacion de perfil automatica, ledger de auditoria.

**Confiabilidad:**

- [ ] LifeOS Lab: replica en container/microVM para pruebas aisladas (`life lab test`).
- [ ] Pipeline de mejora autonoma: deteccion → reproduccion → candidato → canary test.
- [ ] Canales de actualizacion: `stable`, `candidate`, `edge`.
- [ ] SLOs definidos: >=99.95% updates exitosos, <60s rollback, <500ms arranque de app.
- [ ] Metricas de estabilidad reales (telemetria anonima opt-in).

**Daemon y permisos:**

- [ ] Daemon `lifeosd` con API D-Bus: health monitor, update scheduler, policy engine.
- [ ] Broker de permisos unificado: per-app, per-session, per-modalidad con audit logging.
- [ ] **Heartbeats y Cron (Proactividad base):** Hilos de bajo consumo para despertar al agente, revisar notificaciones/logs y lanzar alertas sin peticion del usuario.
- [ ] Politicas por Workplace (desarrollo/finanzas/gaming): perfiles de permisos, red y sensores aplicados por contexto activo.
- [ ] Prompt Shield v1: separacion estricta entre instrucciones confiables y contenido externo no confiable (etiquetado + aislamiento de contexto).

**Recursos de hardware:**

- [ ] Perfiles de recursos: Performance, Balanced, Battery, Silent (CPU/GPU/AI throttling).
- [ ] Telemetria de hardware: monitoreo termico, deteccion de anomalias.
- [ ] Scheduler heterogeneo AI: NPU preferido → GPU fallback → CPU.

**Documentacion:**

- [ ] Documentacion de usuario y contribuidor.
- [ ] Matriz de compatibilidad de hardware publicada.

**Entregable:** beta publica con canal stable funcional y escritorio personalizable.

### Fase 2 (6-12 meses): IA multimodal local

**Objetivo:** asistente local util que justifique el "AI-native".

**AI runtime avanzado:**

- [ ] llama-server con modelos texto + vision + voz (GGUF nativo).
- [ ] Auto-selector de modelo: deteccion de hardware → benchmark → seleccion por umbral.
- [ ] Catalogo de modelos firmado con fallback offline para bootstrap.
- [ ] Captura sensorial en tiempo real post-consentimiento (audio/pantalla/camara).
- [ ] Micro-modelos always-on: VAD, hotword, clasificacion de intents.
- [ ] Switching de modelo pesado por prioridad con degradacion automatica bajo carga.
- [ ] Control de recursos AI por prioridad (cgroups).

**Capacidades multimodales y Automatizacion Visual:**

- [ ] Vision/OCR a nivel de OS: analisis de pantalla, OCR en tiempo real (Wayland/grim).
- [ ] Whisper.cpp para STT (voz local).
- [ ] Embeddings + busqueda semantica local cifrada (SQLite + vectores/Qdrant).
- [ ] Correlacion contextual cross-app/cross-archivo (grafo de actividad).
- [ ] Deteccion de postura/fatiga via camara (wellness).
- [ ] **Computer Use API:** Modulo en `lifeosd` para control programatico del raton y teclado via `libei`/ydotool, permitiendo simulacion de clics y escritura en apps de terceros.

**Asistente e interaccion:**

- [ ] Asistente accesible desde launcher, terminal y atajo de teclado.
- [ ] Automatizaciones en lenguaje natural (`life ai do "..."`).
- [ ] Memoria contextual local cifrada persistente (memory-plane con CLI/API/MCP).
- [ ] `life ai autotune`: benchmarking local y optimizacion automatica de modelo.
- [ ] `Soul Plane` v1 por usuario en `~/.config/lifeos/soul/`, con guardrails opcionales en `/etc/lifeos/soul.defaults/` y merge determinista (global -> usuario -> workplace).
- [ ] `Skills Plane` v1: `~/.local/share/lifeos/skills/` con ciclo generar -> validar -> sandbox -> firmar -> reutilizar y niveles `core/verified/community`.
- [ ] Adaptadores AI por app (email, visor de imagenes, busqueda global) para paridad funcional con flujos UOS AI.
- [ ] Awareness de COSMIC Workspaces en el enrutador de agente para sugerencias/acciones segun habitat activo.

**Arquitectura Cognitiva y de Memoria (El Cerebro LifeOS "Estilo Jarvis"):**

- **Memoria a Corto Plazo (Context Window):** Mantenimiento del hilo de voz o texto actual. Se borra al terminar la sesión o tras X minutos de inactividad para no saturar el LLM.
- **Memoria a Medio Plazo (Session & Task State):** Ledger temporal donde el Agente anota los pasos intermedios de una tarea compleja (Ej. "Instalando dependencias... Resolviendo errores de compilación..."). Le permite retomar tareas tras un reinicio.
- **Memoria a Largo Plazo (Vector RAG Database local):** Base de datos vectorial (SQLite-vec/Qdrant) donde LifeOS almacena hábitos, comandos frecuentes ("A Héctor le gusta el brillo al 30% en la noche"), historial de programas usados, y _memoria de resoluciones_ (cómo arregló un bug hace 3 meses). Totalmente cifrado y consultable.
- **Bucle de Ejecución Autónoma (Agentic Loop):** Capacidad del sistema para recibir un objetivo abstracto ("Despliega el backend en el servidor X"), trazar un plan de 10 pasos, y ejecutarlos _sin preguntar al usuario entre cada paso_, corrigiendo sus propios errores de terminal hasta reportar "100% completado".

**Autonomia y seguridad:**

- [ ] Modo Jarvis temporal: tokens de capacidad con TTL (15-60 min), aprobacion biometrica/PIN para acciones destructivas.
- [ ] Workspace isolation: sandbox/container/microVM por objetivo de intent.
- [ ] Auto-defensas: awareness situacional, auto-reparacion con rollback, operacion degradada offline.
- [ ] Modos de ejecucion: interactive, run-until-done, silent-until-done.
- [ ] Ledger cifrado y exportable de todas las acciones autonomas.
- [ ] Harness de red-team continuo con corpus de ataques agenticos reales (prompt injection, tool abuse, exfiltracion encubierta, cadena de deep links).
- [ ] SLO CVE por severidad en dependencias criticas de agente/runtime: `critical` mitigacion <=24h y parche <=48h; `high` <=72h; `medium` <=14 dias.

**Protocolos y Estandares:**

- [ ] `life-intents` v1: envelope, plan, resultado; workflow plan → policy → execute.
- [ ] `life-id` v1: identidad de agentes, delegation tokens, revocacion CRL, auditoria.
- [ ] **Model Context Protocol (MCP):** Integracion nativa para extensibilidad estandar, permitiendo a LifeOS usar _Skills_ de terceros sin acoplar codigo y renderizar UI (MCP-UI) nativamente en COSMIC.

**CLI extendido:**

- [ ] `life focus`, `life meeting`, `life sync`, `life permissions`, `life workspace`.
- [ ] `life onboarding trust-mode` para configuracion de autonomia.

**Entregable:** release 1.0 con asistente AI multimodal funcional.

### Fase 3 (12-24 meses): Hive Mind gobernado + escala

**Objetivo:** ecosistema sostenible con mejora continua.

**Hive Mind:**

- [ ] Dedupe global de incidencias + dashboard publico de salud por perfil de hardware.
- [ ] Telemetria agregada anonima: fingerprint de fallos, priorizacion automatica.
- [ ] Rollout inteligente: canary → candidate → stable por cohortes de hardware.

**Supply chain y CI:**

- [ ] CI reproducible SLSA Level 3 con attestations completas.
- [ ] Plataforma de PR firmadas con auto-reviewer gate AI.

**Sincronizacion y multi-dispositivo:**

- [ ] Life Capsule sync completo (multi-dispositivo E2E cifrado).
- [ ] COSMIC Sync integrado (cuando Epoch 2 lo entregue).
- [ ] Device mesh: identidad de nodo, delegacion remota, revocacion.
- [ ] Life Capsule v2: incluir `soul`, `skills`, memoria vectorial y politicas firmadas con restauracion selectiva por componente.

**Extensibilidad:**

- [ ] SDK para extensiones AI de terceros.
- [ ] Marketplace de skills/extensiones: niveles core/verified/community con aislamiento por defecto.
- [ ] Visual workflow builder (no-code) para construccion de agentes.
- [ ] Browser operator para tareas web multi-paso con politicas y auditoria.
- [ ] Pipeline de confianza de skills (modelo hibrido): raiz de confianza LifeOS + mantenedores delegados (`verified`) + transparencia de firmas + revocacion.

**Multi-agente y orquestacion:**

- [ ] Sistema multi-agente especializado (client-ops, delivery, QA, finance, health, executive).
- [ ] Consola de flota para usuarios individuales y equipos/empresas.
- [ ] **Enjambre Jerarquico Local (Local Swarm):** Co-procesadores NPU running micro-agentes (1B-3B) "always-on" para clasificacion de intents/routing, delegando tareas complejas al `llama-server` pesado (8B+ GPU) para optimizar bateria e interrupciones.

**Voz y accesibilidad:**

- [ ] Control por voz: dictado tecnico, macros de comandos, modo low-write.
- [ ] Co-piloto de salud: tracking de habitos, alertas ergonomicas, deteccion de fatiga.

**Benchmark y calidad:**

- [ ] `lifeos-bench`: suite de benchmarks reproducibles (latencia/energia/calidad).
- [ ] Bootstrap reproducible: TUI installer con setup automatico de entorno.

**Entregable:** ecosistema autosostenible con comunidad activa y marketplace.

---

## 15. KPIs de exito

### Confiabilidad

| KPI                          | Objetivo    | Frecuencia |
| ---------------------------- | ----------- | ---------- |
| Updates exitosas en stable   | >= 99.95%   | Semanal    |
| Rollback automatico exitoso  | >= 99.9%    | Por evento |
| Tiempo medio de recuperacion | < 2 minutos | Por evento |
| Uptime post-update (7 dias)  | >= 99.99%   | Semanal    |

### Experiencia de usuario

| KPI                                | Objetivo                          | Frecuencia |
| ---------------------------------- | --------------------------------- | ---------- |
| Tiempo "nuevo equipo → trabajando" | < 30 minutos                      | Por evento |
| Tasa de abandono en onboarding     | < 10%                             | Mensual    |
| Usuarios activos mensuales         | Crecimiento >20% m/m (primer ano) | Mensual    |

### IA

| KPI                                 | Objetivo     | Frecuencia          |
| ----------------------------------- | ------------ | ------------------- |
| Latencia del asistente local (p95)  | < 3 segundos | Continuo            |
| Tareas completadas sin intervencion | >= 70%       | Semanal             |
| Satisfaccion con respuestas AI      | >= 4/5       | Encuesta trimestral |

---

## 16. Riesgos y mitigaciones

| Riesgo                                        | Impacto | Probabilidad | Mitigacion                                                                                                 |
| --------------------------------------------- | ------- | ------------ | ---------------------------------------------------------------------------------------------------------- |
| Fedora Image Mode no madura a tiempo          | Alto    | Media        | Plan B: CentOS Stream bootc (o Fedora n+1 estable) como base.                                              |
| COSMIC tiene bugs criticos                    | Alto    | Baja         | Fallback a GNOME Shell con las mismas extensiones AI.                                                      |
| Hardware AI insuficiente en equipos baratos   | Alto    | Alta         | Modelos cuantizados (4-bit GGUF), CPU-only mode, cloud fallback opcional.                                  |
| Modelos locales no son suficientemente buenos | Medio   | Media        | Enrutamiento hibrido local/nube. Actualizar modelos conforme mejoran.                                      |
| Falta de contribuidores                       | Alto    | Media        | Documentacion excelente desde dia 1, CLI facil de extender, SDK publico.                                   |
| Problemas de privacidad / percepcion          | Alto    | Media        | Privacidad local-first no es opcional. Auditorias de seguridad externas.                                   |
| Dependencia upstream abandonada               | Critico | Media        | Construir sobre Fedora (Red Hat). No depender de proyectos comunitarios sin backing para componentes base. |
| Supply chain attack en la imagen base         | Critico | Baja         | Cadena de firma propia (Cosign+KMS). Verificar hashes de Fedora base. Builds reproducibles.                |
| Competidor fuerte entra al mercado            | Medio   | Baja         | Velocidad de ejecucion + comunidad + diferenciacion (inmutabilidad + sync).                                |

---

## 17. Decisiones tecnicas confirmadas

1. **Base:** `quay.io/fedora/fedora-bootc:42` directamente, sin capas intermedias en la imagen base.
2. **Build system:** Containerfile propio + GitHub Actions como ruta oficial unica.
3. **Desktop:** COSMIC Epoch 1 (estable dic 2025). Fallback a GNOME documentado como ruta de contingencia desde Fase 1.
4. **CLI `life`:** Rust (coherente con COSMIC, rendimiento, binario estatico).
5. **Firma:** Cosign con clave en KMS (no en GitHub Secrets). Cadena de confianza propia.
6. **Prioridad:** confiabilidad (A/B + rollback) antes de funciones AI.
7. **Life Capsule** como feature por defecto desde el MVP.
8. **Sync** instalado por defecto, pero desactivado hasta consentimiento explicito.
9. **Contrato de permisos multimodales** definido desde dia 1.
10. **Autonomia tipo Jarvis** solo como sesion temporal auditable, nunca permanente.
11. **Sin dependencias criticas en proyectos sin respaldo operativo suficiente** para componentes base.
12. **Intent Bus nativo (`life-intents`)** como contrato estable de acciones para UI/CLI/agentes/apps.
13. **Identity Plane de agentes (`life-id`)** con tokens de capacidad firmados y revocables.
14. **Execution Plane heterogeneo (`life-ep`)** con preferencia NPU y fallback deterministico.
15. **AI Runtime unico: llama-server (llama.cpp).** Ollama descartado por riesgo de continuidad. Modelos en formato GGUF descargados de HuggingFace.
16. **Modelo biologico como framework cognitivo:** Soul, Skills, Workplace, Agents, Life Capsule (ver `docs/lifeos_biological_model.md`).

---

## 18. Implementacion: estructura del repositorio

```
lifeos/
├── README.md
├── CONTRIBUTING.md
├── LICENSE                                # Apache 2.0
├── Cargo.toml                             # Workspace root
│
├── docs/                                  # Documentacion del proyecto
│   ├── lifeos-ai-distribution.md          # Este spec
│   ├── lifeos_biological_model.md         # Modelo biologico (Soul/Skills/Workplace/Agents)
│   └── deepin_comparison.md              # Analisis competitivo vs Deepin/UOS AI
│
├── image/                                 # Imagen OCI del sistema
│   ├── Containerfile                      # Build multi-stage (Rust builder + sistema)
│   └── files/                             # Archivos copiados al sistema
│       ├── etc/
│       │   ├── lifeos/
│       │   │   ├── lifeos.toml.default    # Config declarativa por defecto
│       │   │   └── llama-server.env       # Variables de entorno del runtime AI
│       │   └── systemd/system/
│       │       ├── llama-server.service   # Servicio AI (llama-server)
│       │       └── lifeos-first-boot.service  # Onboarding de primer arranque
│       └── usr/local/bin/
│           ├── lifeos-ai-setup.sh         # Descarga de modelos GGUF
│           ├── lifeos-first-boot.sh       # Script de primer arranque (GPU, AI, completions)
│           └── llama-server-health-check.sh  # Health check del runtime AI
│
├── cli/                                   # CLI `life` (Rust)
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs                        # Entry point + clap (incluye Beta, Feedback, Lab)
│       ├── lib.rs                         # Core library
│       ├── main_tests.rs                  # Tests unitarios
│       ├── commands/
│       │   ├── mod.rs
│       │   ├── ai.rs                      # life ai (start/stop/ask/do/chat/models/pull/status)
│       │   ├── capsule.rs                 # life capsule export/restore
│       │   ├── config.rs                  # life config show/set/apply
│       │   ├── first_boot.rs              # life first-boot
│       │   ├── id.rs                      # life id issue/list/revoke
│       │   ├── init.rs                    # life init
│       │   ├── intents.rs                 # life intents plan/apply/status
│       │   ├── recover.rs                 # life recover
│       │   ├── rollback.rs                # life rollback
│       │   ├── status.rs                  # life status
│       │   ├── store.rs                   # life store
│       │   ├── theme.rs                   # life theme
│       │   └── update.rs                  # life update [--dry]
│       ├── config/
│       │   ├── mod.rs                     # LifeConfig, AiConfig (provider=llama-server)
│       │   └── tests.rs                   # Tests de config
│       └── system/
│           ├── mod.rs                     # Health checks del sistema
│           └── tests.rs
│
├── daemon/                                # lifeosd (Rust + Axum)
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs                        # Entry point, inicia todos los servicios
│       ├── ai.rs                          # AiManager (llama-server lifecycle)
│       ├── api/mod.rs                     # REST API (Axum + Swagger UI)
│       ├── health.rs                      # HealthMonitor
│       ├── models/mod.rs                  # ModelRegistry (catalogo de 11 modelos GGUF)
│       ├── notifications.rs               # Sistema de notificaciones
│       ├── permissions.rs                 # D-Bus Permission Broker (org.lifeos.Permissions)
│       ├── system.rs                      # Metricas del sistema
│       └── updates.rs                     # Auto-update checker
│
├── contracts/                             # Contratos de integracion estables
│   ├── intents/v1/
│   │   ├── intent.schema.json             # Schema de intent v1
│   │   └── result.schema.json             # Schema de resultado
│   └── onboarding/
│       └── first-boot-config.schema.json  # Schema de configuracion de primer arranque
│
├── tests/                                 # Tests de integracion
│   ├── Cargo.toml
│   └── integration/
│       └── main.rs                        # Tests E2E (boot, CLI, config, daemon, Containerfile)
│
├── scripts/                               # Scripts auxiliares
│   ├── generate-iso.sh                    # Generacion de ISO con bootc-image-builder
│   ├── generate-iso-simple.sh             # Version simplificada
│   └── beta-feedback.sh                   # Recoleccion de feedback
│
└── .github/workflows/
    ├── ci.yml                             # Build + test + audit + coverage
    ├── docker.yml                         # Build y push imagen OCI a GHCR
    ├── release.yml                        # Release con binarios multi-arch
    ├── nightly.yml                        # Builds nocturnos
    └── codeql.yml                         # Escaneo de seguridad CodeQL
```

---

## 19. Implementacion: imagen OCI base

### 19.1 Containerfile principal (build multi-stage desde Fedora)

El Containerfile real usa un build multi-stage: Stage 1 compila los binarios Rust (CLI `life` y daemon `lifeosd`), Stage 2 construye la imagen del sistema. Consultar `image/Containerfile` para la version canonica.

Estructura simplificada:

```dockerfile
# image/Containerfile
# LifeOS: build multi-stage sobre Fedora bootc.

# Stage 1: compilacion de CLI y Daemon
FROM fedora:42 AS builder
RUN dnf -y install cargo gcc openssl-devel pkg-config dbus-devel sqlite-devel ...
COPY cli/ /build/cli/
COPY daemon/ /build/daemon/
RUN cargo build --release --manifest-path /build/cli/Cargo.toml && \
    cargo build --release --manifest-path /build/daemon/Cargo.toml

# Stage 2: imagen del sistema
FROM quay.io/fedora/fedora-bootc:42

# --- Repositorios adicionales (COSMIC via COPR) ---
RUN dnf -y install dnf5-plugins && dnf -y copr enable ryanabx/cosmic-epoch

# --- Desktop environment ---
RUN dnf -y install cosmic-desktop cosmic-files cosmic-terminal \
    cosmic-text-editor cosmic-store xdg-desktop-portal-cosmic \
    NetworkManager bluez pipewire wireplumber && dnf clean all

# --- Nvidia Optimus (GPU hibrida) ---
RUN dnf -y install akmod-nvidia xorg-x11-drv-nvidia-cuda supergfxctl && dnf clean all

# --- Herramientas del sistema ---
RUN dnf -y install toolbox btrfs-progs podman buildah flatpak \
    fish bat ripgrep fd-find htop fastfetch age jq sqlite && dnf clean all

# --- AI Runtime (llama-server via llama.cpp) ---
# Estrategia: descarga binario pre-compilado, fallback a compilacion desde fuente.
# NUNCA usar curl|sh.
RUN set -eux && \
    RELEASE_URL="$(curl -fsSL https://api.github.com/repos/ggerganov/llama.cpp/releases/latest | \
        jq -r '...')" && \
    # Intenta binario pre-compilado, si falla compila desde fuente
    ...
    install -m 0755 llama-server /usr/bin/llama-server

# --- Binarios Rust (CLI + Daemon) ---
COPY --from=builder /build/cli/target/release/life /usr/bin/life
COPY --from=builder /build/daemon/target/release/lifeosd /usr/bin/lifeosd

# --- Configuracion y scripts ---
COPY files/ /

# --- Servicios systemd ---
RUN systemctl enable cosmic-greeter.service && \
    systemctl enable NetworkManager.service && \
    systemctl enable bluetooth.service && \
    systemctl enable lifeosd.service && \
    systemctl enable llama-server.service && \
    systemctl enable lifeos-first-boot.service

# --- Verificacion ---
RUN dnf clean all && bootc container lint
```

**Nota:** el Containerfile real incluye verificacion final de que todos los binarios y archivos de configuracion existen. Consultar el archivo fuente para detalles completos.

### 19.2 Por que usamos Fedora bootc directo como base

Ver seccion 12.1. Resumen implementador:

1. La imagen base se construye directamente desde `quay.io/fedora/fedora-bootc:42`.
2. Se evita una capa intermedia de imagen para reducir riesgo operativo y complejidad.
3. El equipo controla de extremo a extremo `build -> sign -> verify -> upgrade`.
4. El resultado tecnico es equivalente, con menor superficie de falla en la cadena de confianza.

### 19.3 Como construir y probar localmente

```bash
# 1. Construir la imagen OCI (el build multi-stage compila CLI y daemon)
podman build -t localhost/lifeos:dev -f image/Containerfile .

# 2. Generar ISO instalable (ver scripts/generate-iso.sh para la version completa)
sudo podman run --rm -it --privileged --pull=newer \
    --security-opt label=type:unconfined_t \
    -v ./output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type iso \
    --chown $(id -u):$(id -g) \
    localhost/lifeos:dev

# 3. La ISO queda en ./output/ — probar en VM:
qemu-system-x86_64 -m 4096 -enable-kvm -cdrom output/bootiso/*.iso -boot d

# 4. O rebasar un sistema Fedora Atomic existente (sin ISO):
sudo bootc switch localhost/lifeos:dev
```

**Nota:** el contexto de build es la raiz del repositorio (no `image/`) porque el Stage 1 necesita acceso a `cli/` y `daemon/` para compilar los binarios Rust.

---

## 20. Implementacion: CLI `life`

### 20.1 Diseno general

El CLI `life` es la interfaz humana del sistema. Escrito en Rust con `clap` para parsing de argumentos.

**Principios:**

- Cada comando es un wrapper inteligente sobre herramientas existentes (bootc, flatpak, llama-server, btrfs).
- No reinventa: orquesta.
- Salida legible para humanos por defecto, JSON con `--json` para scripts.
- Colores y formato enriquecido en terminal, degradado graceful en pipes.

### 20.2 Comandos MVP (Fase 0)

```
life status              Estado general: OS version, slot activo, salud, disco, updates pendientes.
                         Internamente: bootc status + df + systemctl is-system-running

life update              Descargar e instalar update en slot inactivo.
                         Internamente: bootc upgrade
                         Flags: --dry (simular), --now (reboot inmediato), --channel <ch>

life rollback            Volver al slot previo.
                         Internamente: bootc rollback + systemctl reboot

life recover             Diagnosticar y reparar problemas comunes.
                         Internamente: serie de health checks + acciones correctivas automaticas.

life capsule export      Exportar configuracion + apps + dotfiles a un archivo cifrado.
                         Internamente: tar + age (cifrado) de lifeos.toml + flatpak list + /home dotfiles

life capsule restore     Restaurar desde un export previo.
                         Internamente: descifrar + aplicar lifeos.toml + instalar flatpaks + restaurar dotfiles

life config show         Mostrar lifeos.toml actual.
life config set <k> <v>  Modificar un valor en lifeos.toml.
life config apply        Aplicar configuracion declarativa (instalar apps faltantes, etc).
```

### 20.3 Comandos Fase 1+

```
life lab start           Iniciar entorno de pruebas (container/VM).
life lab test            Correr test suite en el lab.
life lab report          Generar reporte del lab.

life ai ask "..."        Preguntar al asistente local (llama-server).
life ai do "..."         Ejecutar accion en lenguaje natural.
life ai models           Listar modelos disponibles/instalados.
life ai pull <model>     Descargar un modelo.
life ai profile          Detectar clase de hardware para IA local.
life ai benchmark        Medir latencia/calidad de candidatos locales.
life ai autotune         Seleccionar y aplicar mejores modelos por rol.
life ai pin <rol> <modelo>     Fijar modelo manual para un rol (override).
life ai unpin <rol>            Quitar override y volver a autoseleccion.
life ai realtime on      Activar modo AI-first always-on (post-consent).
life ai realtime off     Desactivar captura/reaccion en tiempo real.
life ai realtime status  Ver estado de sensores, slot pesado y latencia.
life onboarding trust-mode enable --policy /ruta/policy.toml --sig /ruta/policy.sig
                         Activar trust_me_mode con politica firmada.
life onboarding trust-mode disable
                         Desactivar trust_me_mode y volver a consentimiento interactivo.

life focus               Activar modo Flow.
life meeting             Activar modo Meeting.

life sync status         Estado de sincronizacion.
life sync now            Forzar sync inmediato.

life permissions show    Mostrar permisos activos.
life permissions revoke  Revocar un permiso.
life permissions log     Ver log de accesos.

life intents plan "..."               Generar plan tipado desde una intencion natural.
life intents apply <intent-id>        Ejecutar plan aprobado (o pedir aprobacion segun riesgo).
life intents status <intent-id>       Ver estado de ejecucion y evidencias.
life intents validate <file.json>     Validar payload contra schema v1.
life intents log [--since 24h]        Auditar intents/acciones/diffs.

life id issue --agent <name>          Emitir token de capacidad temporal.
life id list                           Listar identidades y delegaciones activas.
life id revoke <token-id>              Revocar token/delegacion en caliente.

life workspace run --intent <id>       Ejecutar en sandbox por objetivo.
```

### 20.4 Ejemplo de implementacion: `life status`

```rust
// cli/src/commands/status.rs
use crate::system::bootc::BootcStatus;
use crate::system::health::HealthCheck;
use crate::config::lifeos_toml::LifeOSConfig;
use clap::Args;
use colored::Colorize;

#[derive(Args)]
pub struct StatusArgs {
    /// Output in JSON format
    #[arg(long)]
    json: bool,
}

pub async fn execute(args: StatusArgs) -> anyhow::Result<()> {
    let bootc = BootcStatus::get().await?;
    let health = HealthCheck::run().await?;
    let config = LifeOSConfig::load()?;

    if args.json {
        let output = serde_json::json!({
            "version": bootc.version,
            "slot": bootc.active_slot,
            "channel": config.system.channel,
            "mode": config.system.mode,
            "health": health.summary(),
            "updates_available": bootc.updates_available,
        });
        println!("{}", serde_json::to_string_pretty(&output)?);
    } else {
        println!("{}", "LifeOS Status".bold());
        println!("  Version:    {}", bootc.version);
        println!("  Slot:       {}", bootc.active_slot);
        println!("  Channel:    {}", config.system.channel);
        println!("  Mode:       {}", config.system.mode);
        println!("  Health:     {}", health.colored_summary());
        if bootc.updates_available {
            println!("  Updates:    {}", "Available".yellow());
        } else {
            println!("  Updates:    {}", "Up to date".green());
        }
    }
    Ok(())
}
```

### 20.5 Dependencias Rust (Cargo.toml)

```toml
# cli/Cargo.toml
[package]
name = "life"
version = "0.1.0"
edition = "2021"
description = "LifeOS system CLI"

[dependencies]
clap = { version = "4", features = ["derive"] }
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
toml = "0.8"
anyhow = "1"
colored = "3"
reqwest = { version = "0.12", features = ["json"] }  # Para llama-server API (http://localhost:8080)
dirs = "6"
```

### 20.6 Especificacion ejecutable: `life-intents` v1

`life-intents` es el contrato canonico para ejecutar acciones en LifeOS. Nada se ejecuta fuera de este contrato.

**Estados validos del intent:**

`draft -> planned -> awaiting_approval -> approved -> executing -> succeeded | failed | rolled_back | blocked`

**Campos obligatorios del intent envelope (`contracts/intents/v1/intent.schema.json`):**

1. `intent_id` (ULID)
2. `schema_version` (`"life-intents/v1"`)
3. `created_at` (RFC3339 UTC)
4. `requested_by` (`user://...` o `agent://...`)
5. `objective_id` (ID de objetivo/sesion)
6. `action` (verbo tipado: `calendar.read`, `mail.send`, `fs.write`, `ssh.exec`, etc)
7. `input` (payload tipado por accion)
8. `risk` (`low|medium|high|critical`)
9. `required_capabilities` (lista de capacidades)
10. `dry_run` (bool)
11. `idempotency_key` (string estable)
12. `constraints` (`max_runtime_sec`, `max_cost_usd`, `network_policy`)

**Ejemplo minimo de intent v1:**

```json
{
  "intent_id": "01JXFV7V7M9M2R1A5R8Z4W0R7M",
  "schema_version": "life-intents/v1",
  "created_at": "2026-02-23T18:45:00Z",
  "requested_by": "agent://executive-agent/primary",
  "objective_id": "obj-client-ops-2026-02-23",
  "action": "calendar.brief_next_meeting",
  "input": { "within_minutes": 30, "include_attendees": true },
  "risk": "low",
  "required_capabilities": ["calendar.read", "notifications.send"],
  "dry_run": false,
  "idempotency_key": "obj-client-ops-2026-02-23:brief-next-meeting",
  "constraints": {
    "max_runtime_sec": 60,
    "max_cost_usd": 0.0,
    "network_policy": "default"
  }
}
```

**Contrato de plan (`contracts/intents/v1/plan.schema.json`):**

1. `steps[]` con `tool`, `args`, `expected_output`, `rollback_step`.
2. `requires_approval` calculado por politica de riesgo.
3. `evidence_plan` (que logs/artefactos se guardaran).

**Contrato de resultado (`contracts/intents/v1/result.schema.json`):**

1. `status` final.
2. `started_at`, `finished_at`, `duration_ms`.
3. `artifacts[]` (paths/hash).
4. `actions[]` (comandos ejecutados tipados, nunca texto libre sin clasificar).
5. `rollback` (si aplico: `performed`, `reason`, `rollback_artifacts[]`).
6. `error` normalizado (`code`, `message`, `retryable`).

**Invariantes obligatorios de ejecucion:**

1. Todo `intent` debe pasar `validate -> plan -> policy` antes de `execute`.
2. `risk=high|critical` nunca auto-ejecuta sin aprobacion humana o politica firmada.
3. Ninguna accion se ejecuta si falta `required_capabilities`.
4. Todo resultado se escribe en ledger local cifrado y firmado.
5. Si falla un paso reversible, ejecutar rollback automaticamente.

### 20.7 Especificacion ejecutable: `life-id` v1

`life-id` define identidad, delegacion y revocacion para agentes y servicios.

**Tipos de principal:**

1. `user://<tenant>/<user-id>`
2. `agent://<role>/<instance>`
3. `service://<component>/<node-id>`

**Delegacion (`contracts/identity/v1/delegation.schema.json`):**

Campos obligatorios:

1. `delegation_id` (ULID)
2. `delegator` (principal humano o servicio autorizado)
3. `delegatee` (agent/service)
4. `capabilities[]`
5. `scope` (objetivo, paths, dominios, repos)
6. `risk_ceiling` (`low|medium|high`)
7. `expires_at` (TTL)
8. `reason` (justificacion)
9. `signature` (firma del delegador)

**Capability token (`contracts/identity/v1/capability-token.schema.json`):**

1. Formato: PASETO v4.public (o JWT firmado equivalente si el entorno lo exige).
2. Claims minimos: `iss`, `sub`, `act`, `cap[]`, `scope`, `risk`, `iat`, `exp`, `jti`.
3. Binding opcional a dispositivo (`device_id`, `tpm_quote_hash`) para sesiones Jarvis.
4. Revocacion online/offline por `jti` contra CRL local sincronizable.

**Reglas de validacion de token:**

1. Firma valida y `exp` vigente.
2. `cap[]` cubre la accion exacta del intent.
3. `scope` permite el recurso objetivo.
4. `risk` del token >= `risk` del intent.
5. `jti` no revocado.

**Comandos CLI obligatorios (`life id`):**

```bash
life id issue --agent delivery-agent --cap fs.write --scope repo:/workspace/client-a --ttl 30m
life id list --active
life id revoke <jti>
life id rotate-keys --provider kms
```

### 20.8 Flujo E2E obligatorio (`life-intents` + `life-id`)

1. Usuario/agente define objetivo.
2. `life intents plan` genera `intent + plan`.
3. `policy_engine` calcula riesgo y decide `auto-approve` o `awaiting_approval`.
4. `life-id` emite/valida token de capacidad para cada paso.
5. `executor` corre en sandbox si aplica (`life workspace run`).
6. Se registra evidencia en ledger (`plan`, `acciones`, `artefactos`, `resultado`).
7. Si hay falla reversible, rollback automatico y estado `rolled_back`.
8. Notificacion final segun modo (`interactive`, `run-until-done`, `silent-until-done`).

---

## 21. Implementacion: lifeos.toml completo

```toml
# /etc/lifeos/lifeos.toml - Configuracion declarativa del sistema

[system]
version = "0.1.0"                     # Version de LifeOS instalada (read-only, gestionada por bootc)
channel = "stable"                     # stable | candidate | edge
mode = "simple"                        # simple | pro | builder
locale = "es_MX.UTF-8"
timezone = "America/Mexico_City"
hostname = "lifeos-laptop"

[system.updates]
auto_download = true                   # Descargar updates automaticamente
auto_install = false                   # Instalar requiere confirmacion del usuario
schedule = "04:00"                     # Hora preferida para updates automaticas
snapshot_before_update = true          # Snapshot de Btrfs antes de cada update

[onboarding]
trust_me_mode = false                  # false por defecto; true solo en despliegue administrado
deployment_type = "personal"           # personal | managed
require_signed_consent_bundle = true
consent_bundle_path = "/etc/lifeos/consent-bundle.toml"
consent_bundle_sig_path = "/etc/lifeos/consent-bundle.toml.sig"

[apps]
# Flatpaks del sistema (instalados como sistema, no usuario)
flatpak_system = [
    "org.mozilla.firefox",
    "com.github.tchx84.Flatseal",
]
# Flatpaks del usuario
flatpak_user = [
    "com.spotify.Client",
    "com.discordapp.Discord",
]
# Containers de desarrollo
toolbox = [
    { name = "ubuntu-dev", image = "ubuntu:24.04" },
    { name = "fedora-build", image = "fedora:42" },
]

[ai]
enabled = true                         # Habilitar subsistema AI
runtime = "llama-server"               # llama-server | disabled
default_model = "qwen3-8b-q4_k_m.gguf"  # Fallback si el autoselector esta desactivado
reasoning_model = "deepseek-r1-8b-q4_k_m.gguf"  # Fallback reasoning
vision_model = "gemma3-4b-q4_k_m.gguf"          # Fallback vision/OCR
voice_model = "whisper-small.gguf"               # Modelo para voz
embedding_model = "nomic-embed-text"   # Modelo para embeddings

[ai.model_selector]
enabled = true
mode = "auto"                          # auto | manual
catalog_url = "https://models.lifeos.dev/catalog/v1.json"
catalog_signature_url = "https://models.lifeos.dev/catalog/v1.json.sig"
rebenchmark_on_bootstrap = true
rebenchmark_interval_days = 7
hardware_class = "auto"                # auto | lite | balanced | pro | workstation

[ai.model_selector.thresholds]
first_token_ms_p95 = 1800
tokens_per_sec_min = 12
max_peak_mem_percent = 70
max_crash_rate = 0

[ai.roles]
general = "auto"
reasoning = "auto"
vision = "auto"
embeddings = "nomic-embed-text"

[ai.realtime]
enable_after_onboarding_consent = true
always_on = true
sensor_mode = "event_driven"           # event_driven | continuous
push_to_talk = false
heavy_model_slots = 1                  # Nunca cargar >1 modelo pesado al mismo tiempo
aux_model_slots = 2                    # STT/TTS/embeddings ligeros
max_thermal_celsius = 85
max_battery_drain_watts = 18

[ai.permissions]
voice = false                          # false pre-consent; true tras onboarding AI-first
screen_capture = false                 # false pre-consent; true tras onboarding AI-first
camera = false                         # false pre-consent; configurable por usuario
context_tracking = false               # Seguimiento de actividad entre apps
cloud_fallback = false                 # Permitir enviar queries a la nube

[ai.resources]
max_ram_percent = 25                   # Maximo % de RAM para inferencia
gpu_enabled = true                     # Usar GPU si esta disponible
background_priority = "low"            # low | normal | high
max_loaded_heavy_models = 1            # Guardrail de memoria/latencia

[intents]
enabled = true                          # Activar motor life-intents
schema_version = "life-intents/v1"
default_mode = "plan_then_apply"        # plan_then_apply | auto_low_risk
ledger_path = "/var/lib/lifeos/intents/ledger.db"
max_concurrent = 8

[intents.policy]
require_preview = true
auto_approve_risk = "low"               # low | medium | high | none
require_human_for = ["high", "critical"]
idempotency_window_minutes = 120
default_max_runtime_sec = 600
default_max_cost_usd = 1.00

[identity]
enabled = true                          # Activar life-id
issuer = "life-id.local"
token_format = "paseto-v4-public"       # paseto-v4-public | jwt-es256
default_agent_ttl_minutes = 30
crl_path = "/var/lib/lifeos/identity/crl.json"

[identity.policy]
require_signed_delegation = true
require_device_binding_for_critical = true
allow_offline_tokens = true
max_offline_ttl_minutes = 15

[sync]
enabled = false                        # Sync instalado, pero deshabilitado hasta consentimiento explicito
provider = "lifeos-cloud"              # lifeos-cloud | self-hosted | disabled
targets = []                           # IDs de dispositivos a sincronizar
conflict_resolution = "last-write"     # last-write | manual | device-priority

[sync.what]
config = true                          # Sincronizar lifeos.toml
dotfiles = true                        # Sincronizar dotfiles
app_list = true                        # Sincronizar lista de apps
secrets = false                        # Sincronizar secretos (requiere setup manual)
ai_context = false                     # Sincronizar memoria AI

[display]
comfort_engine = true                  # Motor de confort visual
night_mode_auto = true                 # Modo nocturno automatico
reduce_animations_after_hours = 4      # Reducir animaciones tras N horas de uso
```

---

## 22. Implementacion: MVP minimo (Fase 0-alpha)

El MVP alpha es la version mas reducida que demuestra que LifeOS funciona. Se puede construir en **4-6 semanas** con 1-2 developers.

### 22.1 Que incluye el MVP alpha

| Componente  | Alcance MVP                                               | NO incluye aun                           |
| ----------- | --------------------------------------------------------- | ---------------------------------------- |
| Imagen base | COSMIC + llama-server + Toolbx sobre Fedora bootc directo | Branding completo, temas custom          |
| CLI `life`  | `status`, `update`, `rollback`                            | `recover`, `capsule`, `ai`, `lab`        |
| lifeos.toml | Seccion `[system]` y `[apps]` funcionales                 | `[ai]`, `[sync]`, `[display]`            |
| Updates     | bootc upgrade + rollback manual                           | Auto-update, canales, health checks      |
| Apps        | Flatpak funcional, lista en lifeos.toml                   | Auto-instalacion desde config            |
| AI          | llama-server instalado y funcional via terminal/API       | Integracion con CLI, permisos, enrutador |
| Tests       | Boot test + rollback test                                 | Suite completa                           |
| CI/CD       | Build image + push a GHCR                                 | Firma Sigstore, tests en VM              |

### 22.2 Tareas ordenadas del MVP alpha

```
Semana 1-2: Imagen base
├── Crear Containerfile sobre quay.io/fedora/fedora-bootc:42
├── Instalar COSMIC desktop + dependencias
├── Agregar llama-server (llama.cpp), toolbox, herramientas CLI
├── Agregar lifeos.toml.default en /etc/lifeos/
├── Configurar GitHub Actions para build automatico
├── Generar par de claves Cosign (KMS) y configurar firma
├── Probar: imagen construye, se firma y se publica en GHCR
└── Probar: ISO bootea en VM (QEMU) y rebase funciona

Semana 2-3: CLI life (v0.1)
├── Scaffold proyecto Rust con clap
├── Implementar `life status` (wrapper bootc status + systemd)
├── Implementar `life update` (wrapper bootc upgrade)
├── Implementar `life rollback` (wrapper bootc rollback)
├── Implementar `life config show/set`
├── Compilar como binario estatico (musl)
├── Incluir binario en la imagen OCI
└── Probar: comandos funcionan en la imagen

Semana 3-4: Integracion y tests
├── Crear test_boot.sh (imagen arranca en VM con qemu)
├── Crear test_rollback.sh (rollback funciona)
├── Crear test_life_cli.sh (comandos responden correctamente)
├── Configurar CI para correr tests en cada PR
└── Documentar: README con instrucciones de install/build/test

Semana 4-5: Polish y primer release
├── Agregar branding minimo (wallpaper, nombre en fastfetch)
├── Asegurar llama-server arranca como servicio (systemd unit)
├── Verificar Flatpak store funciona
├── Verificar Toolbx crea containers
├── Crear ISO con bootc-image-builder
├── Tag v0.1.0-alpha en GitHub
└── Release con ISO descargable

Semana 5-6: Buffer + documentacion
├── Fix bugs encontrados en testing
├── CONTRIBUTING.md con guia de build local
├── README.md con vision + como probar
└── Publicar en comunidades para feedback
```

### 22.3 Criterios de exito del MVP alpha

- [x] La imagen OCI construye sin errores en CI. *`docker.yml` activo con firma cosign.*
- [ ] La imagen ISO bootea en hardware real y en VM (QEMU/VirtualBox). *Pendiente de prueba sistematica.*
- [x] `life status` muestra version, slot activo y estado de salud. *Implementado con flag `--json`.*
- [x] `life update --dry` simula una actualizacion. *Wrapper sobre `bootc upgrade --check`.*
- [x] `life rollback` cambia al slot previo y reinicia. *Wrapper sobre `bootc rollback`.*
- [x] llama-server corre y responde a health check y chat completions. *Servicio systemd + `lifeos-ai-setup.sh` + `llama-server-health-check.sh`.*
- [x] Flatpak funciona con Flathub configurado. *Configurado en first-boot.*
- [x] Toolbx disponible para containers de desarrollo. *Instalado en imagen base.*
- [ ] El sistema sobrevive a un `bootc upgrade` sin romperse. *Pendiente de prueba automatizada en VM.*

---

### 22.4 Roadmap competitivo (vs Deepin / UOS AI)

El analisis competitivo completo esta en `docs/deepin_comparison.md`. Resumen ejecutable de las brechas a cerrar en Fase 1-2:

1. **Integracion visual profunda:** Applet COSMIC con overlay `Super+Space` (<300ms p95). Ya planificado en Fase 1.
2. **Busqueda semantica local:** Indexador vectorial cifrado (SQLite-vec/Qdrant). Ya planificado en Fase 2.
3. **Conciencia de pantalla:** Modelos vision GGUF + captura Wayland/PipeWire via `lifeosd`. Ya planificado en Fase 2.
4. **Ejecucion nativa por intents:** `life-intents` traduce lenguaje natural a acciones D-Bus/COSMIC. Contratos definidos, implementacion en Fase 2.

LifeOS gana en seguridad (inmutabilidad, rollback, audit) y privacidad (local-first). La meta es convertir esa ventaja arquitectonica en UX visible.

---

## 23. Implementacion: CI/CD pipeline

### 23.1 Pipelines implementados (GitHub Actions)

Los workflows reales estan en `.github/workflows/`. Resumen:

| Workflow       | Trigger                            | Funcion                                                              |
| -------------- | ---------------------------------- | -------------------------------------------------------------------- |
| `ci.yml`       | Push/PR a `main`/`develop`         | Build CLI + Daemon, tests, `cargo-audit`, coverage (tarpaulin), docs |
| `docker.yml`   | Push a `main` o tags `v*`, PRs     | Build y push de imagen OCI a `ghcr.io`                               |
| `release.yml`  | Push de tags `v*` o manual         | Release GitHub con binarios multi-arch (linux + macOS, x86 + arm64)  |
| `nightly.yml`  | Cron nocturno                      | Builds nocturnos para deteccion temprana de regresiones              |
| `codeql.yml`   | Push/PR                            | Escaneo de seguridad CodeQL                                          |

### 23.2 Build del CLI y Daemon

El pipeline `ci.yml` compila tanto `cli/` como `daemon/` en un solo job, corre `cargo test` en el workspace completo, ejecuta `cargo-audit` para vulnerabilidades y genera cobertura con `tarpaulin`.

### 23.3 Build y firma de imagen OCI

El pipeline `docker.yml` construye la imagen multi-stage (Stage 1: Rust, Stage 2: sistema) y la publica en GHCR. La firma con Cosign/KMS esta planificada pero aun no activa en CI — actualmente se firma manualmente.

**Pendiente de automatizar:**
- Firma Cosign con clave en KMS (no en GitHub Secrets)
- Attestations in-toto en el pipeline
- Verificacion automatica de hash de la imagen base de Fedora

---

## 24. Guia de contribucion

### 24.1 Requisitos para desarrollar

```
- Linux (cualquier distro) o WSL2
- Podman >= 4.0 (para construir imagenes OCI)
- Rust >= 1.75 (para el CLI life)
- QEMU/libvirt (para probar imagenes en VM, opcional)
- bootc-image-builder (via contenedor, no instalacion host obligatoria)
```

### 24.2 Setup rapido

```bash
# Clonar
git clone https://github.com/gama-os/lifeos.git
cd lifeos

# Construir el CLI y Daemon
cargo build --release --manifest-path cli/Cargo.toml
cargo build --release --manifest-path daemon/Cargo.toml

# Correr tests unitarios
cargo test --workspace

# Correr tests de integracion
cargo test --manifest-path tests/Cargo.toml

# Construir la imagen OCI (requiere podman; contexto = raiz del repo)
podman build -t lifeos:dev -f image/Containerfile .

# Generar ISO (requiere qemu + bootc-image-builder via contenedor)
bash scripts/generate-iso.sh
# O la version simplificada:
bash scripts/generate-iso-simple.sh

# Probar en VM:
qemu-system-x86_64 -m 4096 -enable-kvm -cdrom output/bootiso/*.iso -boot d
```

### 24.3 Estructura de PRs

- Cada PR debe tener descripcion clara del cambio.
- Tests obligatorios para cambios al CLI (`cargo test`).
- Imagen debe construir sin errores (`podman build`).
- Firma de commits recomendada (GPG o SSH).

### 24.4 Donde contribuir primero

| Area                                    | Dificultad  | Impacto |
| --------------------------------------- | ----------- | ------- |
| Comandos del CLI `life`                 | Facil-Media | Alto    |
| Branding (wallpapers, temas COSMIC)     | Facil       | Medio   |
| Tests de integracion                    | Media       | Alto    |
| Documentacion                           | Facil       | Alto    |
| Receta Containerfile (paquetes, config) | Facil       | Alto    |
| lifeosd (daemon D-Bus)                  | Alta        | Alto    |
| Integracion llama-server en CLI         | Media       | Alto    |

---

## 25. Decisiones para arrancar ya

1. **Base:** `quay.io/fedora/fedora-bootc:42` directo. Sin intermediarios.
2. **Desktop:** COSMIC Epoch 1 (estable dic 2025).
3. **CLI:** Rust con clap. Binario estatico musl.
4. **Firma:** Cosign + KMS. Cadena de confianza propia desde dia 1.
5. **Prioridad:** imagen que bootea + CLI basico + rollback funcional.
6. **Life Capsule** como feature por defecto desde el MVP.
7. **Sync** instalado por defecto, pero activado solo con consentimiento explicito.
8. **Contrato de permisos multimodales** definido desde dia 1.
9. **Hardware Compatibility Matrix** publicada antes de la beta.
10. **Autonomia tipo Jarvis** solo como sesion temporal, nunca permanente.
11. **Gobernanza abierta** desde dia 0: repo publico, issues abiertos, CONTRIBUTING.md.
12. **Principio de independencia:** nunca depender de proyectos sin backing corporativo para componentes criticos.
13. **Intent Bus primero:** acciones solo via `life-intents` con `plan -> policy -> execute`.
14. **Identidad de agentes obligatoria:** todo agente usa `life-id` con delegacion revocable y TTL.
15. **Auditoria como producto:** ledger cifrado y exportable en cada ejecucion autonoma.
16. **Auto-seleccion de modelos local-first:** catalogo firmado + benchmark local + degradacion automatica por hardware.
17. **Ollama descartado:** llama-server (llama.cpp) como unico runtime AI local. Sin dependencias de startups con funding incierto.
18. **Modelo biologico integrado:** Soul (identidad), Skills (habilidades), Workplace (contexto), Agents (enjambre) como framework cognitivo del sistema (ver `docs/lifeos_biological_model.md`).

---

## 26. Referencias tecnicas

- Fedora bootc/image mode: https://docs.fedoraproject.org/en-US/bootc/
- bootc project (CNCF): https://bootc-dev.github.io/bootc/
- composefs (CNCF): https://github.com/composefs/composefs
- OSTree: https://github.com/ostreedev/ostree
- Fedora bootc desktop guide: https://fedoramagazine.org/building-your-own-atomic-bootc-desktop/
- bootc-image-builder: https://github.com/osbuild/bootc-image-builder
- Fedora base bootc image (quay): https://quay.io/repository/fedora/fedora-bootc
- Toolbx: https://containertoolbx.org/
- Podman: https://podman.io/
- xdg-desktop-portal: https://flatpak.github.io/xdg-desktop-portal/
- Flatpak docs: https://docs.flatpak.org/en/latest/
- PipeWire: https://pipewire.org/
- WirePlumber: https://pipewire.pages.freedesktop.org/wireplumber/
- The Update Framework (TUF): https://theupdateframework.io/
- Sigstore: https://docs.sigstore.dev/
- in-toto: https://in-toto.io/
- SLSA: https://slsa.dev/
- COSMIC desktop: https://system76.com/cosmic
- HuggingFace GGUF models (Qwen3): https://huggingface.co/Qwen/Qwen3-8B-GGUF
- Qwen3 official announcement: https://qwenlm.github.io/blog/qwen3/
- Gemma 3 model docs (size and memory guidance): https://ai.google.dev/gemma/docs/core/model_card_3
- DeepSeek-R1 repository: https://github.com/deepseek-ai/DeepSeek-R1
- llama.cpp: https://github.com/ggml-org/llama.cpp
- MCP specification: https://modelcontextprotocol.io/specification/2025-06-18
- PASETO (Platform-Agnostic Security Tokens): https://paseto.io/
- Open Policy Agent (OPA): https://www.openpolicyagent.org/docs/latest/
- ULID spec: https://github.com/ulid/spec
- OpenTelemetry: https://opentelemetry.io/docs/
- Linux cgroups v2: https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html

---

## 27. Faltantes para completar ejecucion al 100%

Estado actual del proyecto (febrero 2026): la base tecnica esta implementada — imagen booteable, CLI funcional, daemon con API REST, CI/CD activo. Faltan entregables avanzados.

### 27.1 Entregables ya completados

1. ~~`image/Containerfile` real y booteable~~ — **Hecho.** Multi-stage build con Rust + COSMIC + llama-server + Nvidia.
2. ~~`cli/` funcional con `life status`, `life update --dry`, `life rollback`~~ — **Hecho.** Incluye `ai`, `capsule`, `config`, `intents`, `id`, `store`, `theme` y mas.
3. ~~`daemon/` con broker de permisos~~ — **Hecho.** API REST (Axum + Swagger), D-Bus permissions, health monitor, model registry, AI manager.
4. ~~`tests/` automatizados~~ — **Hecho.** Tests de integracion (boot, CLI, config, daemon, Containerfile).
5. ~~`.github/workflows/` reales~~ — **Hecho.** CI, docker, release, nightly, codeql.

### 27.2 Entregables obligatorios pendientes
1. Flujo de firma Cosign con KMS operativo en CI (actualmente manual).
2. `life capsule export/restore` funcional end-to-end (minimo config + apps + dotfiles).
3. Onboarding GUI con consentimiento explicito para activar sync (first-boot script existe, falta GUI).
4. Matriz de compatibilidad de hardware publicada.
5. Guia operativa de incidentes (rollback, recovery, revocacion de artefactos).
6. Plano de memoria persistente (`memory-plane`) con CLI/API/MCP y almacenamiento local cifrado.
7. Orquestador por equipos de agentes con modo `run-until-done` y handoff entre especialistas.
8. Registry open source de skills/capacidades con versionado, firmas y politica de confianza.
9. Gate de revision automatica pre-merge (AI reviewer) con cache, reglas y reporte auditable.
10. Bootstrap reproducible de entorno developer/user via perfil y TUI de instalacion.
11. Perfiles de runtime `lite/edge/secure/pro` con deteccion automatica de hardware.
12. Aislamiento por objetivo (sandbox/container/microVM) segun riesgo de la accion.
13. Constructor visual de workflows y agentes (no-code) para usuarios no tecnicos.
14. Browser operator seguro para tareas web multi-step con politicas y auditoria.
15. Suite de benchmarks reproducibles para validar rendimiento/latencia/consumo frente a competidores.
16. `contracts/intents/v1` completados con tests de compatibilidad de schema (intent.schema.json y result.schema.json existen, falta plan.schema.json).
17. `contracts/identity/v1` publicados y versionados con validacion de tokens/delegaciones (aun no creados).
18. `life intents` y `life id` implementados end-to-end con pruebas de aprobacion, rechazo y revocacion.
19. Ledger cifrado de ejecucion (`intents/results/artifacts`) con exportacion firmada para auditoria.
20. `device-mesh` operativo para coordinacion multi-PC con identidad de nodo, delegacion y revocacion remota.
21. Pipeline de extensiones/skills con niveles de confianza (`core`, `verified`, `community`) y aislamiento por defecto.
22. Autoselector de modelos (`life ai autotune`) implementado con benchmark local y persistencia por rol.
23. `model-catalog` firmado con versionado y fallback offline embebido en la ISO.
24. Runtime realtime AI-first implementado con `heavy_model_slots = 1` y pruebas de no regresion de latencia.
25. `trust_me_mode` implementado con validacion criptografica de `consent_bundle` y auditoria completa.
26. `Soul Plane` por usuario en `~/.config/lifeos/soul/` (ver modelo biologico en `docs/lifeos_biological_model.md`).
27. `Skills Plane` con ciclo generar -> validar -> sandbox -> firmar -> reutilizar.
28. ~~Corregir puerto del daemon `AiManager`~~ — **Corregido.** Ahora usa puerto 8080 consistente con el resto del stack.
29. Actualizar `contracts/onboarding/first-boot-config.schema.json` para usar nombres de modelos GGUF en lugar de formato Ollama.

### 27.3 Criterio de cierre de faltantes

Un faltante solo se marca cerrado si incluye:

- codigo en repo,
- prueba automatizada,
- evidencia de ejecucion (log/artefacto CI),
- documentacion de uso.

---

## 28. Prompt maestro para LLM implementador (copiar/pegar)

```text
Actua como agente implementador de LifeOS en este repositorio. Debes ejecutar el spec lifeos-ai-distribution.md hasta cumplir el 100% funcional definido en la seccion 0.3.

Reglas de ejecucion:
1) No te detengas en propuestas; implementa archivos reales y pruebas.
2) No uses placeholders ejecutables (TBD/TODO/<...>) en build, CI o codigo.
3) Cada tarea cerrada debe tener evidencia verificable: comandos ejecutados + resultado.
4) Si hay bloqueo, documenta causa y continua con tareas no bloqueadas.
5) Prioridad obligatoria: confiabilidad (build/boot/update/rollback) antes de IA avanzada.
6) Sync: cliente instalado por defecto, activacion solo tras consentimiento explicito.
7) Seguridad: firma de artefactos + verificacion en update path.
8) Persistir memoria de largo plazo por objetivo/sesion y reutilizarla en iteraciones futuras.
9) Usar especialistas (no agente monolitico) para planear, ejecutar, verificar y corregir.
10) Ejecutar revision automatica de cambios antes de marcar cualquier tarea como "done".
11) No ejecutar acciones fuera de `life-intents`; toda accion debe tener envelope validado.
12) No ejecutar acciones privilegiadas sin token `life-id` vigente y no revocado.
13) Todo cambio autonomo debe dejar evidencia en ledger auditable (plan, accion, resultado).
14) Implementar autoselector local de modelos (`profile + benchmark + catalogo firmado`) antes de declarar AI lista para produccion.
15) `trust_me_mode` solo puede activarse con `consent_bundle` firmado y debe quedar auditado.

Ciclo de trabajo obligatorio (repetir hasta terminar):
A. Implementar un bloque pequeno y funcional.
B. Ejecutar pruebas locales/CI del bloque.
C. Corregir fallas.
D. Documentar evidencias.
E. Avanzar al siguiente bloque.

No declares finalizado hasta cumplir todos los puntos de la seccion 0.3 con evidencia.
```

---

## 29. Autonomia general Jarvis-class (si o si)

### 29.1 Objetivo

LifeOS debe operar como un sistema autonomo de proposito general capaz de ejecutar, con permisos controlados, **cualquier tarea digital legitima** que una persona puede realizar desde una computadora, dentro de limites legales, de seguridad y de politica de riesgo.

Para este proyecto, eso incluye:

1. Operacion de negocio freelance end-to-end (ventas, cotizaciones, reuniones, delivery, soporte).
2. Ejecucion tecnica de proyectos (construir, probar, corregir y desplegar).
3. Administracion personal diaria (agenda, tareas, recordatorios, documentos, finanzas basicas).
4. Soporte de bienestar y salud como copiloto continuo.

Los casos anteriores son solo ejemplos de arranque. El alcance real es abierto: cada usuario define sus propios objetivos y el sistema debe adaptarse.

### 29.2 Principio "computer-complete"

El sistema debe tener capacidades para:

1. Leer, escribir y organizar informacion.
2. Usar navegador, correo, calendario y herramientas SaaS.
3. Editar codigo, ejecutar comandos, levantar servicios y validar resultados.
4. Integrar APIs externas bajo politicas de seguridad.
5. Operar en una o varias PCs coordinadas.

Si una tarea requiere una accion de alto riesgo, se solicita aprobacion segun politica; si no, ejecuta automaticamente.

### 29.3 Adaptacion por usuario (no plantillas fijas)

La distro debe tratar a cada persona como un "mundo operativo" distinto:

1. Aprende metas, contexto, herramientas y ritmo de trabajo del usuario.
2. Crea y ajusta flujos autonomos por perfil (freelance, estudio, empresa, creador, etc.).
3. Reutiliza capacidades base, pero personaliza estrategia y priorizacion.
4. No depende de ejemplos predefinidos; compone acciones nuevas desde objetivos en lenguaje natural.

### 29.4 Modos de autonomia

1. `interactive`: propone y espera confirmacion en cada paso.
2. `run-until-done`: ejecuta ciclos completos hasta terminar.
3. `silent-until-done`: no interrumpe; solo notifica en `listo` o `bloqueado`.

Contrato obligatorio por objetivo:

```toml
[objective]
mode = "run-until-done"                 # interactive | run-until-done | silent-until-done
notify_policy = "done_or_blocked_only"  # verbose | done_or_blocked_only
max_runtime_minutes = 240
risk_level = "low"                      # low | medium | high | critical
```

### 29.5 Multi-agente por rol (negocio + ejecucion)

1. `client-ops-agent`: correos, cotizaciones, agenda, seguimiento de clientes.
2. `delivery-agent`: planeacion, implementacion y entrega de features/proyectos.
3. `qa-agent`: pruebas, reproduccion de bugs, autocorreccion guiada por evidencia.
4. `finance-agent`: facturas, cobros, alertas de flujo y previsiones.
5. `health-agent`: ergonomia, pausas, habitos, seguimiento de carga/cansancio.
6. `executive-agent`: prioriza objetivos y coordina todos los agentes.

### 29.6 Caso de uso prioritario para este equipo (fundadores freelance)

Definition of Done de operacion diaria:

1. Ningun correo de cotizacion queda sin respuesta dentro de SLA definido.
2. Ninguna reunion critica se pierde; cada reunion tiene brief previo automatico.
3. Proyectos activos tienen estado, riesgos y proximos pasos actualizados.
4. Bugs criticos detectados en produccion generan incidente y plan de correccion.
5. Carga operativa manual del fundador tecnico se reduce de forma medible semana a semana.

### 29.7 Hands-free y accesibilidad (tunel carpiano)

LifeOS debe incluir modo de trabajo de baja escritura:

1. Control por voz para comandos del sistema y tareas de desarrollo.
2. Dictado tecnico para codigo/documentacion con correccion contextual.
3. Macros en lenguaje natural (ej. "prepara release y ejecuta test suite completa").
4. Atajos ergonomicos y recordatorios de descanso programados.
5. Politica de carga de teclado: limitar sesiones largas de tipeo continuo.

### 29.8 Salud y bienestar: alcance real

LifeOS puede ser copiloto de salud, pero con limites claros:

1. Si: recordatorios, seguimiento de habitos, resumen de sintomas, deteccion de patrones, recomendaciones generales.
2. No: diagnostico medico definitivo, prescripcion clinica automatica, ni reemplazo de profesionales licenciados.
3. Escalamiento: ante riesgo alto (fisico o mental), recomendar contacto profesional y activar protocolo de emergencia configurado por el usuario.

### 29.9 Politicas de riesgo para autonomia amplia

1. Todo objetivo autonomo define alcance, tiempo maximo y limites de costo.
2. Acciones destructivas, financieras o legales requieren doble confirmacion.
3. Todas las decisiones autonomas quedan auditadas (quien, que, por que, resultado).
4. Cualquier fallo critico activa rollback o aislamiento segun tipo de sistema.

### 29.10 KPI de autonomia general

1. Tasa de objetivos completados sin intervencion.
2. Tiempo medio de cierre por objetivo.
3. Incidentes evitados (reuniones perdidas, correos no respondidos, deploys fallidos).
4. Reduccion de carga manual de teclado/raton.
5. Cumplimiento de politicas de riesgo y auditoria.

### 29.11 Cierre implementador

Para este documento, el objetivo no es justificar tendencias ni comparar proyectos.
El objetivo es implementar un sistema funcional con evidencia tecnica.

Reglas finales para el LLM implementador:

1. Implementar por bloques pequenos con pruebas automatizadas.
2. No ejecutar acciones fuera de `life-intents` + `life-id`.
3. Priorizar estabilidad del sistema antes de autonomia avanzada.
4. Mantener trazabilidad completa en ledger de cada decision autonoma.
5. No marcar nada como "done" sin evidencia reproducible en CI.

---

**LifeOS no promete "nunca falla". Demuestra que se recupera solo, rapido y de forma verificable.**
Esa es la diferencia entre una distro interesante y una distro que millones de personas pueden usar todos los dias.
