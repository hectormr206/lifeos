# LifeOS: Modelo de Amenazas (STRIDE)

Este documento formaliza el modelo de amenazas de **LifeOS** aplicable a los componentes de inteligencia artificial y orquestación local (Fase 0 - Aegis). Utiliza la metodología STRIDE (Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege).

## 1. Superficies de Ataque Identificadas

1.  **LifeOS Daemon (`lifeosd`):** API REST local (puerto 8081) y API D-Bus.
2.  **AI Runtime (`llama-server`):** API compatible con OpenAI (puerto 8080).
3.  **Sistema de Intents:** El mecanismo de comunicación entre comandos de usuario y ejecución de agente.
4.  **CLI `life`:** Comandos invocados localmente por el usuario.

## 2. Análisis STRIDE

### S - Spoofing (Suplantación de Identidad)

- **Amenaza:** Un proceso local o extensión de terceros se hace pasar por el CLI oficial para inyectar ordenes al `lifeosd` vía D-Bus o REST, solicitando acciones confidenciales.
- **Mitigación:**
  - **D-Bus:** Polkit (PolicyKit) y chequeo de permisos restringiendo el envío de mensajes a la interfaz `org.lifeos.Daemon` solo a binarios firmados y al usuario activo.
  - **REST API:** El demonio arranca generando un token JWT de un solo uso (bootstrap token) o token local efímero intercambiado en disco con permisos de solo lectura para el dueño (`600`). Solo las extensiones/CLI que posean el token pueden hablar con la REST API. Se debe vincular a `127.0.0.1` exclusivamente.

### T - Tampering (Manipulación)

- **Amenaza:** Un atacante modifica los modelos GGUF, los binarios en ejecución, o el registro de _Skills_ para introducir backdoors.
- **Mitigación:**
  - Inmutabilidad base (ComposeFS + fs-verity) asegura que `/usr` no se puede manipular.
  - Verificación de SHA256 contra el catálogo firmado antes de arrancar cualquier modelo de `.local/share/lifeos/models`.
  - _Skills_ requieren firma. Una skill no firmada nativamente corre en sandbox hiper-restringido (Toolbx/Podman) sin acceso a `/home`.

### R - Repudiation (Repudio)

- **Amenaza:** El agente de IA o un módulo de extensiones toma una acción destructiva (borrado de archivos, envío de criptomonedas) y no hay evidencia de quién autorizó el comando.
- **Mitigación:**
  - Implementación de un **Ledger inmutable cifrado** en `/var/log/lifeos/audit/`. Todo comando de alto riesgo despachado por el planificador AI requiere un "Intent" que se registra con firma criptográfica local antes de ejecutarse.

### I - Information Disclosure (Divulgación de Información)

- **Amenaza:** Ataques de _Prompt Injection_ (Inyección de Prompt) a través de "FollowAlong" o documentos locales escaneados por indexadores vectoriales que exfiltren datos a un atacante enviando URLs formadas. Ataque _Path Traversal_.
- **Mitigación:**
  - Validación fuerte de entrada en endpoints. Filtro de sanitización (_Prompt Shield_) para contenido proveniente de internet, encapsulado en roles de "Observador" sin permisos de acción.
  - El demonio corre bajo un usuario sin privilegios o con seccomp profiles estrictos que detengan llamadas a system calls no deseadas.

### D - Denial of Service (Denegación de Servicio)

- **Amenaza:** Consumo exhaustivo de hardware por parte de `llama-server` mediante peticiones infinitas o cargas de prompts máximos (crasheo por OOM) dejando inutilizable la computadora del usuario.
- **Mitigación:**
  - Integración estricta de **cgroups v2** aplicados por `lifeosd` para aislar el proceso de la IA. _CPUQuota_ ajustada dinámicamente según estado térmico y batería. Si se requiere uso prioritario del usuario, el OOM Killer interno del demonio liquida las peticiones del AI.

### E - Elevation of Privilege (Elevación de Privilegios)

- **Amenaza:** El agente de IA, ejecutando Bash, aprovecha un bug del kernel para escalar privilegios de _user_ a _root_.
- **Mitigación:**
  - Los Agentes Executor operan sin `sudo`. Si `lifeosd` necesita escalar privilegios (ej. `bootc update`), ocurre en un proceso externo validado _sin_ shell, recibiendo argumentos tipados y cerrados. Nunca se concatena input de LLM directo a `command -c`.

---

## 3. Matriz de Controles Activos (Fase 0)

| Control                    | Estado          | Componente                |
| :------------------------- | :-------------- | :------------------------ |
| Bind a `127.0.0.1`         | **Obligatorio** | `lifeosd`, `llama-server` |
| Verificación de firmas OCI | **Obligatorio** | Containerfile/Cosign      |
| Sanitización de path       | **Obligatorio** | Handler de Intents        |
| Ledger criptográfico       | _Fase 1_        | Auditoría                 |
