# LifeOS: AI-Native Linux Distribution

## Especificacion de Producto y Arquitectura

**Version:** 6.1.0 - "Aegis-Implementer"
**Fecha:** 2026-02-23
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

1. Imagen OCI de LifeOS construye en CI sin errores.
2. ISO generada arranca en VM y en al menos un equipo real soportado.
3. `life status`, `life update --dry`, `life rollback` funcionan end-to-end.
4. Update atomico + rollback validado por test automatizado.
5. Permisos multimodales (mic/camara/pantalla) auditables y revocables.
6. Life Capsule export/restore funcional.
7. Sync instalado por defecto, pero solo activado tras consentimiento explicito.
8. Pipeline de firma/verificacion de imagen activo.
9. Suite minima de tests pasando en CI.

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
local_model = "qwen3:8b"
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
│         API unificada (D-Bus)        │
├──────────────────────────────────────┤
│       Orquestador de modelos         │
│  ┌─────────┬──────────┬───────────┐  │
│  │ Ollama  │ llama.cpp│  Nube     │  │
│  │ (facil) │(avanzado)│(opcional) │  │
│  └─────────┴──────────┴───────────┘  │
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

- **Ollama como runtime principal:** modelo de gestion simple y API REST estable para integracion.
- **llama.cpp como backend de rendimiento:** acceso directo para usuarios avanzados, soporte GGUF, optimizacion por hardware (CUDA, ROCm, Vulkan, Metal).
- **Nube opcional:** solo se activa si el usuario la configura explicitamente. Todas las consultas en nube son cifradas E2E.
- **Enrutador inteligente:** tareas simples (clasificacion, OCR) van a modelos pequenos locales; tareas complejas (generacion larga, analisis multi-documento) pueden ir a modelos grandes locales o nube segun politica del usuario.

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

### 5.5 Matriz inicial recomendada (baseline fecha 2026-02-23)

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

| Capa             | Eleccion                                  | Razon                                                                                             | Estado    |
| ---------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------- | --------- |
| Base OS          | Fedora Image Mode + bootc                 | Actualizaciones atomicas OCI, CNCF sandbox (ene 2025). Nota: produccion plena apunta a Fedora 45. | Madurando |
| Kernel           | Linux mainline 6.x + parches desktop      | Compatibilidad amplia y baja latencia.                                                            | Estable   |
| Filesystem raiz  | composefs + fs-verity (sobre Btrfs)       | Inmutabilidad verificable a nivel kernel para `/usr`.                                             | Estable   |
| Filesystem datos | Btrfs                                     | Snapshots, subvolumenes, compresion zstd para `/home` y `/var`.                                   | Estable   |
| Desktop          | **COSMIC Epoch 1** (estable dic 2025)     | Rust, tiling nativo, extensible, sync en roadmap.                                                 | Estable   |
| Audio/Video      | PipeWire + WirePlumber                    | Stack unificado de multimedia, baja latencia, estandar en todas las distros mayores.              | Estable   |
| Apps GUI         | Flatpak + xdg-desktop-portal              | Aislamiento + permisos declarativos.                                                              | Estable   |
| Dev Envs         | Toolbx (principal) + Podman directo       | Containers mutables sin romper base. Toolbx mantenido por Red Hat.                                | Estable   |
| AI Runtime       | Ollama (principal) + llama.cpp (avanzado) | Ollama: gestion facil. llama.cpp: rendimiento maximo. vLLM solo para serving multi-usuario.       | Estable   |
| Update Trust     | TUF + Sigstore + in-toto                  | Cadena de supply chain verificable de extremo a extremo.                                          | Estable   |
| Observabilidad   | OpenTelemetry + panel local               | Diagnostico continuo y accionable sin enviar datos a terceros.                                    | Estable   |

### 12.1 Estrategia de base: Fedora bootc directo

**Decision:** LifeOS construye directamente sobre `quay.io/fedora/fedora-bootc:42`, sin capas intermedias de terceros para la imagen base.

**Implementacion:**

```
FROM quay.io/fedora/fedora-bootc:42    # Base oficial de Fedora (CNCF sandbox)
RUN dnf -y install cosmic-desktop && dnf clean all
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

**Ollama — startup con $500K, sin revenue model claro**

Ollama Inc tiene ~21 personas, $500K en pre-seed (Y Combinator), sin modelo de ingresos publico. Si cierra o pivotea, el proyecto open source queda sin mantenimiento. Ademas, su script de instalacion (`curl | sh`) es un vector de supply chain.

- **Nivel de riesgo:** Medio-Alto para continuidad. Medio para supply chain.
- **Alternativa:** llama.cpp (comunidad enorme, sin single point of failure).
- **Mitigacion:**
  1. El orquestador AI de LifeOS habla con Ollama **y** directamente con llama.cpp. Si Ollama desaparece, se cambia de backend sin afectar al usuario.
  2. **Prioridad de distribucion obligatoria:** `RPM oficial firmado` > `RPM interno firmado por LifeOS` > `binario release con SHA256 pinneado` (fallback).
  3. **NUNCA usar `curl | sh`** en el Containerfile.
  4. Pinear versiones de Ollama y verificar checksums en el build.

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

| Componente   | Plan B                                       | Esfuerzo de migracion                   |
| ------------ | -------------------------------------------- | --------------------------------------- |
| Fedora bootc | CentOS Stream bootc                          | Config (cambiar FROM en Containerfile)  |
| COSMIC       | GNOME Shell                                  | Config + temas (1-2 semanas)            |
| Flatpak      | RPMs en imagen base para apps criticas       | Ya mitigado desde dia 1                 |
| Ollama       | llama.cpp directo                            | Cambio de backend en orquestador (dias) |
| Distrobox    | Toolbx / Podman directo                      | Wrapper en CLI `life` (dias)            |
| PipeWire     | N/A (sin alternativa, pero estable y ubicuo) | No aplica                               |
| Sigstore     | GPG signing tradicional                      | Config en CI (horas)                    |

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

- [ ] Base inmutable bootc + composefs con slots A/B + rollback funcional.
- [ ] Flatpak + Toolbx funcionando sobre la base inmutable.
- [ ] Centro de permisos basico (D-Bus broker).
- [ ] CLI `life` con comandos nucleares: `status`, `update`, `rollback`, `recover`.
- [ ] Backup cifrado + restore basico (`life capsule export/restore`).
- [ ] Pipeline CI/CD para construir imagenes OCI firmadas.
- [ ] Definir `lifeos.toml` como formato de configuracion declarativa.

**Entregable:** imagen ISO booteable que se actualiza sin romperse.

### Fase 1 (3-6 meses): UX y confiabilidad

**Objetivo:** un escritorio usable que la gente quiera usar diario.

- [ ] COSMIC configurado con temas LifeOS (Simple/Pro).
- [ ] LifeOS Lab con pruebas previas a updates (`life lab test`).
- [ ] Canales de actualizacion: `stable`, `candidate`, `edge`.
- [ ] Metricas de estabilidad reales (telemetria anonima opt-in).
- [ ] Broker de permisos unificado para sensores y acciones AI.
- [ ] Onboarding de primer arranque.
- [ ] Documentacion de usuario y contribuidor.

**Entregable:** beta publica con canal stable funcional.

### Fase 2 (6-12 meses): IA multimodal local

**Objetivo:** asistente local util que justifique el "AI-native".

- [ ] Ollama integrado con modelos texto + vision + voz.
- [ ] Asistente accesible desde launcher, terminal y atajo de teclado.
- [ ] Memoria contextual local cifrada (embeddings + SQLite).
- [ ] Automatizaciones en lenguaje natural (`life ai do "..."`).
- [ ] Control de recursos AI por prioridad (cgroups).
- [ ] Modo Jarvis temporal con tokens de capacidad y TTL.
- [ ] `life-intents` operativo para acciones cross-app y cross-agent.
- [ ] `life-id` operativo para identidad/delegacion de agentes con auditoria.
- [ ] Motor de confort visual funcional.

**Entregable:** release 1.0 con asistente AI funcional.

### Fase 3 (12-24 meses): Hive Mind gobernado + escala

**Objetivo:** ecosistema sostenible con mejora continua.

- [ ] Dedupe global de incidencias + dashboard publico de salud.
- [ ] Plataforma de PR firmadas + CI reproducible (SLSA Level 3).
- [ ] Rollout inteligente por cohortes de hardware.
- [ ] Life Capsule sync completo (multi-dispositivo).
- [ ] COSMIC Sync integrado (cuando Epoch 2 lo entregue).
- [ ] Consola de flota para usuarios individuales y equipos/empresas.
- [ ] SDK para extensiones AI de terceros.

**Entregable:** ecosistema autosostenible con comunidad activa.

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

---

## 18. Implementacion: estructura del repositorio

```
lifeos/
├── README.md
├── lifeos-ai-distribution.md          # Este spec
├── CONTRIBUTING.md                     # Guia de contribucion
├── LICENSE                             # Apache 2.0
│
├── image/                              # Imagen OCI del sistema
│   ├── Containerfile                   # Build principal (desde fedora-bootc directo)
│   ├── build.sh                        # Script de customizacion del sistema
│   ├── cosign.pub                      # Clave publica de firma
│   ├── flatpaks.txt                    # Flatpaks incluidos por defecto
│   └── files/                          # Archivos que se copian al sistema
│       ├── etc/
│       │   └── lifeos/
│       │       └── lifeos.toml.default # Config por defecto
│       └── usr/
│           └── share/
│               └── lifeos/
│                   └── branding/       # Logos, wallpapers, temas
│
├── cli/                                # CLI `life` (Rust)
│   ├── Cargo.toml
│   ├── Cargo.lock
│   └── src/
│       ├── main.rs                     # Entry point + clap
│       ├── lib.rs                      # Core library
│       ├── commands/
│       │   ├── mod.rs
│       │   ├── status.rs               # life status
│       │   ├── update.rs               # life update [--dry]
│       │   ├── rollback.rs             # life rollback
│       │   ├── recover.rs              # life recover
│       │   ├── capsule.rs              # life capsule export/restore
│       │   ├── ai.rs                   # life ai ask "..."
│       │   ├── intents.rs              # life intents plan/apply/status
│       │   ├── identity.rs             # life id issue/list/revoke
│       │   └── workspace.rs            # life workspace run
│       ├── config/
│       │   ├── mod.rs
│       │   └── lifeos_toml.rs          # Parser de lifeos.toml
│       ├── system/
│       │   ├── mod.rs
│       │   ├── bootc.rs                # Wrapper sobre bootc CLI
│       │   ├── flatpak.rs              # Gestion de Flatpaks
│       │   └── health.rs               # Health checks post-boot
│       └── ai/
│           ├── mod.rs
│           └── ollama.rs               # Cliente REST para Ollama
│
├── daemon/                             # lifeosd (Rust)
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs
│       ├── dbus_api.rs                 # API D-Bus para el orquestador
│       ├── permissions.rs              # Broker de permisos
│       ├── health_monitor.rs           # Watchdog de salud del sistema
│       ├── update_scheduler.rs         # Planificador de actualizaciones
│       ├── intent_bus.rs               # life-intents: validacion, estado, ledger
│       ├── identity_plane.rs           # life-id: emision/revocacion/validacion
│       ├── policy_engine.rs            # Evaluacion de riesgo y politicas
│       └── executor.rs                 # Ejecutor tipado con rollback
│
├── contracts/                          # Contratos de integracion estables
│   ├── intents/
│   │   └── v1/
│   │       ├── intent.schema.json
│   │       ├── plan.schema.json
│   │       └── result.schema.json
│   └── identity/
│       └── v1/
│           ├── capability-token.schema.json
│           └── delegation.schema.json
│
├── onboarding/                         # Asistente de primer arranque
│   ├── Cargo.toml                      # Rust + iced (recomendado)
│   └── src/
│
├── tests/                              # Tests de integracion del sistema
│   ├── test_boot.sh                    # Verifica que la imagen arranca
│   ├── test_rollback.sh                # Verifica rollback A/B
│   ├── test_flatpak.sh                 # Verifica instalacion de apps
│   └── test_life_cli.sh                # Verifica comandos del CLI
│
└── .github/
    └── workflows/
        ├── build-image.yml             # CI: construir imagen OCI
        ├── sign-image.yml              # CI: firmar con Sigstore
        ├── test-image.yml              # CI: correr tests en VM
        └── release.yml                 # CI: publicar en GHCR
```

---

## 19. Implementacion: imagen OCI base

### 19.1 Containerfile principal (build directo desde Fedora)

```dockerfile
# image/Containerfile
# LifeOS: construido directamente sobre Fedora bootc, sin intermediarios.

# Stage 1: archivos de configuracion
FROM scratch AS ctx
COPY files /ctx/files
COPY scripts /ctx/scripts

# Stage 2: imagen del sistema
FROM quay.io/fedora/fedora-bootc:42

# --- Repositorios adicionales ---
# COSMIC desktop (COPR o repo oficial segun disponibilidad)
RUN dnf -y install dnf5-plugins && \
    dnf -y copr enable ryanabx/cosmic-epoch

# --- Desktop environment ---
RUN dnf -y install \
    cosmic-desktop \
    cosmic-files \
    cosmic-terminal \
    cosmic-text-editor \
    cosmic-store \
    xdg-desktop-portal-cosmic \
    xdg-user-dirs \
    NetworkManager \
    bluez \
    && dnf clean all

# --- Herramientas del sistema ---
RUN dnf -y install \
    toolbox \
    btrfs-progs \
    smartmontools \
    podman \
    buildah \
    flatpak \
    fish \
    bat \
    ripgrep \
    fd-find \
    htop \
    fastfetch \
    age \
    && dnf clean all

# --- AI Runtime ---
# IMPORTANTE: NO usar curl|sh (vector de supply chain).
# Prioridad de empaquetado: RPM oficial firmado > RPM interno firmado > binario con SHA256 pinneado (fallback).
# Este ejemplo usa la ruta fallback (binario + checksum verificado).
ARG OLLAMA_VERSION=0.5.1
ARG OLLAMA_SHA256
RUN test -n "${OLLAMA_SHA256}" && \
    curl -fsSL -o /tmp/ollama "https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/ollama-linux-amd64" && \
    echo "${OLLAMA_SHA256}  /tmp/ollama" | sha256sum -c - && \
    install -m 755 /tmp/ollama /usr/bin/ollama && \
    rm /tmp/ollama

# --- Configuracion del sistema ---
COPY --from=ctx /ctx/files/ /

# --- CLI life (binario pre-compilado desde CI) ---
COPY --from=ctx /ctx/scripts/install-life-cli.sh /tmp/
RUN chmod +x /tmp/install-life-cli.sh && /tmp/install-life-cli.sh && rm /tmp/install-life-cli.sh

# --- Servicios systemd ---
RUN systemctl enable sddm.service && \
    systemctl enable NetworkManager.service && \
    systemctl enable bluetooth.service && \
    systemctl enable flatpak-system-update.timer && \
    systemctl enable lifeosd.service && \
    systemctl enable ollama.service

# --- Flatpaks por defecto (se instalan en primer arranque via firstboot service) ---
# La lista esta en /usr/share/lifeos/flatpaks-default.txt
# Un servicio systemd oneshot los instala en el primer boot.

# --- Limpieza y verificacion ---
RUN dnf clean all && \
    bootc container lint
```

### 19.2 Por que usamos Fedora bootc directo como base

Ver seccion 12.1. Resumen implementador:

1. La imagen base se construye directamente desde `quay.io/fedora/fedora-bootc:42`.
2. Se evita una capa intermedia de imagen para reducir riesgo operativo y complejidad.
3. El equipo controla de extremo a extremo `build -> sign -> verify -> upgrade`.
4. El resultado tecnico es equivalente, con menor superficie de falla en la cadena de confianza.

### 19.3 Como construir y probar localmente

```bash
# 1. Construir la imagen OCI
podman build -t localhost/lifeos:dev -f image/Containerfile image/

# 2. Generar ISO instalable (requiere bootc-image-builder)
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

---

## 20. Implementacion: CLI `life`

### 20.1 Diseno general

El CLI `life` es la interfaz humana del sistema. Escrito en Rust con `clap` para parsing de argumentos.

**Principios:**

- Cada comando es un wrapper inteligente sobre herramientas existentes (bootc, flatpak, ollama, btrfs).
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

life ai ask "..."        Preguntar al asistente local (Ollama).
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
reqwest = { version = "0.12", features = ["json"] }  # Para Ollama API
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
runtime = "ollama"                     # ollama | llama-cpp | disabled
default_model = "qwen3:8b"            # Fallback si el autoselector esta desactivado
reasoning_model = "deepseek-r1:8b"     # Fallback reasoning
vision_model = "gemma3:4b"             # Fallback vision/OCR
voice_model = "whisper:small"          # Modelo para voz
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

| Componente  | Alcance MVP                                         | NO incluye aun                           |
| ----------- | --------------------------------------------------- | ---------------------------------------- |
| Imagen base | COSMIC + Ollama + Toolbx sobre Fedora bootc directo | Branding completo, temas custom          |
| CLI `life`  | `status`, `update`, `rollback`                      | `recover`, `capsule`, `ai`, `lab`        |
| lifeos.toml | Seccion `[system]` y `[apps]` funcionales           | `[ai]`, `[sync]`, `[display]`            |
| Updates     | bootc upgrade + rollback manual                     | Auto-update, canales, health checks      |
| Apps        | Flatpak funcional, lista en lifeos.toml             | Auto-instalacion desde config            |
| AI          | Ollama instalado y funcional via terminal           | Integracion con CLI, permisos, enrutador |
| Tests       | Boot test + rollback test                           | Suite completa                           |
| CI/CD       | Build image + push a GHCR                           | Firma Sigstore, tests en VM              |

### 22.2 Tareas ordenadas del MVP alpha

```
Semana 1-2: Imagen base
├── Crear Containerfile sobre quay.io/fedora/fedora-bootc:42
├── Instalar COSMIC desktop + dependencias
├── Agregar Ollama, toolbox, herramientas CLI
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
├── Asegurar Ollama arranca como servicio (systemd unit)
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

- [ ] La imagen ISO bootea en hardware real y en VM (QEMU/VirtualBox).
- [ ] `life status` muestra version, slot activo y estado de salud.
- [ ] `life update --dry` simula una actualizacion.
- [ ] `life rollback` cambia al slot previo y reinicia.
- [ ] Ollama corre y responde a `ollama run qwen3:8b "hola"`.
- [ ] Flatpak permite instalar Firefox desde el store.
- [ ] Toolbx crea un container de desarrollo (Fedora/Ubuntu).
- [ ] El sistema sobrevive a un `bootc upgrade` sin romperse.

---

### 22.4 Roadmap para Superar a la Competencia (ej. Deepin / UOS AI)

Para que LifeOS se posicione objetivamente por encima de los AI-OS actuales en el mercado, se deben implementar las siguientes características arquitectónicas clave, adaptándolas a nuestra visión nativa, inmutable y privada:

#### A. Integración Visual Profunda (El "AI Taskbar")

Actualmente la IA habita principalmente en la terminal (`life ai`). Se requiere una integración gráfica fluida en COSMIC:

- **Meta:** Un "Applet" o Daemon GUI en Rust integrado al entorno COSMIC.
- **Acción:** Permitir invocar a la IA (ej. `Super + Espacio`) desplegando un _overlay_ flotante sobre cualquier aplicación (estilo Spotlight/Raycast) para asistencia inmediata sin cambiar de contexto.

#### B. Búsqueda Semántica de Archivos (Local)

Ir más allá de buscar por nombres exactos de archivo.

- **Meta:** Indexador local vectorial.
- **Acción:** Integrar una pequeña base de datos vectorial local (ej. Qdrant / sqlite-vec) para indexar documentos (PDFs, Markdown) localmente. Esto permitirá que el demonio de la IA busque contexto basándose en descripciones y semántica, sin enviar los documentos a la nube.

#### C. Conciencia de Pantalla / Multimodalidad (Wayland)

Empoderar a la IA para entender lo que el usuario está viendo independientemente de la aplicación abierta.

- **Meta:** Visión de OS.
- **Acción:** Interconectar Ollama (por medio de modelos como LLaVA o Llama 3.2 Vision) con herramientas de Wayland (ej. `grim`) y Pipewire. El demonio `lifeosd` podrá "ver" la interfaz para explicarle visualmente flujos al usuario, o bien diagnosticar errores visuales en tiempo real de manera privada.

#### D. Acciones y Ejecución Nativa ("Life-Intents")

Dejar de ser sólo un asistente conversacional para ser un agente de sistema operativo.

- **Meta:** Comprensión de configuración de OS vía lenguaje natural.
- **Acción:** Finalizar el sistema `Life-Intents` para que el `lifeosd` traduzca solicitudes (ej. "Activa modo cine oscuro") directamente a comandos dbus de red o del escritorio COSMIC.

---

## 23. Implementacion: CI/CD pipeline

### 23.1 Build y publicacion (GitHub Actions)

```yaml
# .github/workflows/build-image.yml
name: Build LifeOS Image
on:
  push:
    branches: [main]
    paths: ["image/**"]
  pull_request:
    paths: ["image/**"]
  schedule:
    - cron: "0 6 * * 1" # Lunes a las 6 AM UTC

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build image
        run: podman build -t ghcr.io/${{ github.repository_owner }}/lifeos:latest -f image/Containerfile image/

      - name: Push image
        run: podman push ghcr.io/${{ github.repository_owner }}/lifeos:latest

      - name: Sign image with Cosign (KMS)
        uses: sigstore/cosign-installer@v3
      - run: cosign sign --key ${{ secrets.COSIGN_KMS_KEY }} ghcr.io/${{ github.repository_owner }}/lifeos:latest
```

### 23.2 Build del CLI life

```yaml
# .github/workflows/build-cli.yml
name: Build life CLI
on:
  push:
    paths: ["cli/**"]
  pull_request:
    paths: ["cli/**"]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: x86_64-unknown-linux-musl
      - name: Build
        run: cargo build --release --target x86_64-unknown-linux-musl
        working-directory: cli
      - name: Test
        run: cargo test
        working-directory: cli
      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: life-cli
          path: cli/target/x86_64-unknown-linux-musl/release/life
```

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

# Construir el CLI
cd cli && cargo build && cd ..

# Construir la imagen (requiere podman)
cd image && podman build -t lifeos:dev -f Containerfile . && cd ..

# Probar en VM (requiere qemu + bootc-image-builder via contenedor)
sudo podman run --rm -it --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type iso \
  --chown $(id -u):$(id -g) \
  localhost/lifeos:dev

# Correr tests
bash tests/test_life_cli.sh
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
| Integracion Ollama en CLI               | Media       | Alto    |

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
- Ollama: https://ollama.com/
- Ollama API docs (official): https://github.com/ollama/ollama/blob/main/docs/api.md
- Ollama model library: Qwen3 https://ollama.com/library/qwen3
- Ollama model library: DeepSeek-R1 https://ollama.com/library/deepseek-r1
- Ollama model library: Gemma3 https://ollama.com/library/gemma3
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

Estado actual del proyecto: el documento esta maduro, pero faltan entregables de implementacion real en repositorio.

### 27.1 Entregables obligatorios pendientes

1. `image/Containerfile` real y booteable (no solo ejemplo en markdown).
2. `cli/` funcional con `life status`, `life update --dry`, `life rollback`.
3. `daemon/` con broker de permisos y logs auditables para sensores/acciones AI.
4. `tests/` automatizados de boot, update, rollback y CLI.
5. `.github/workflows/` reales para build, test, firma y publicacion.
6. Flujo de firma Cosign con KMS operativo en CI.
7. `life capsule export/restore` funcional (minimo config + apps + dotfiles).
8. Onboarding con consentimiento explicito para activar sync.
9. Matriz de compatibilidad de hardware publicada.
10. Guia operativa de incidentes (rollback, recovery, revocacion de artefactos).
11. Plano de memoria persistente (`memory-plane`) con CLI/API/MCP y almacenamiento local cifrado.
12. Orquestador por equipos de agentes con modo `run-until-done` y handoff entre especialistas.
13. Registry open source de skills/capacidades con versionado, firmas y politica de confianza.
14. Gate de revision automatica pre-merge (AI reviewer) con cache, reglas y reporte auditable.
15. Bootstrap reproducible de entorno developer/user via perfil y TUI de instalacion.
16. Perfiles de runtime `lite/edge/secure/pro` con deteccion automatica de hardware.
17. Aislamiento por objetivo (sandbox/container/microVM) segun riesgo de la accion.
18. Constructor visual de workflows y agentes (no-code) para usuarios no tecnicos.
19. Browser operator seguro para tareas web multi-step con politicas y auditoria.
20. Suite de benchmarks reproducibles para validar rendimiento/latencia/consumo frente a competidores.
21. `contracts/intents/v1` publicados y versionados con tests de compatibilidad de schema.
22. `contracts/identity/v1` publicados y versionados con validacion de tokens/delegaciones.
23. `life intents` y `life id` implementados end-to-end con pruebas de aprobacion, rechazo y revocacion.
24. Ledger cifrado de ejecucion (`intents/results/artifacts`) con exportacion firmada para auditoria.
25. `device-mesh` operativo para coordinacion multi-PC con identidad de nodo, delegacion y revocacion remota.
26. Pipeline de extensiones/skills con niveles de confianza (`core`, `verified`, `community`) y aislamiento por defecto.
27. Autoselector de modelos (`life ai autotune`) implementado con benchmark local y persistencia por rol.
28. `model-catalog` firmado con versionado y fallback offline embebido en la ISO.
29. Runtime realtime AI-first implementado con `heavy_model_slots = 1` y pruebas de no regresion de latencia.
30. `trust_me_mode` implementado con validacion criptografica de `consent_bundle` y auditoria completa.

### 27.2 Criterio de cierre de faltantes

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
