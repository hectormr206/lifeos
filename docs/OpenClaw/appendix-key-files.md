# Appendix - Key Files To Read

## Ruta de lectura corta

Si alguien quiere entender OpenClaw por archivos y no por carpetas, esta es la mejor ruta inicial.

## Raiz y entrypoints

- `../openclaw-main/README.md`: define el producto completo y no solo el CLI.
- `../openclaw-main/AGENTS.md`: reglas de arquitectura y mantenimiento del repo.
- `../openclaw-main/package.json`: scripts, gates, targets y build pipeline.
- `../openclaw-main/pnpm-workspace.yaml`: forma del monorepo y dependencias build-only.
- `../openclaw-main/src/index.ts`: entrypoint dual CLI/libreria.
- `../openclaw-main/src/entry.ts`: wrapper del CLI, compile cache, respawn y fast paths.
- `../openclaw-main/src/library.ts`: facade lazy para consumo como libreria.

## Gateway y protocolo

- `../openclaw-main/docs/concepts/architecture.md`: vista arquitectonica corta.
- `../openclaw-main/docs/gateway/protocol.md`: handshake, roles, scopes y framing.
- `../openclaw-main/src/gateway/boot.ts`: filosofia de boot y primer uso.
- `../openclaw-main/src/gateway/protocol/schema.ts`: version y contrato del protocolo.
- `../openclaw-main/src/gateway/server/ws-connection.ts`: ciclo de vida de sockets y handshake.
- `../openclaw-main/src/gateway/server/ws-connection/message-handler.ts`: validacion de `connect`, pairing y admision real.
- `../openclaw-main/src/gateway/server/ws-connection/auth-context.ts`: resolucion de auth de sesion.
- `../openclaw-main/src/gateway/server/ws-connection/connect-policy.ts`: reglas finas de pairing y superficies.
- `../openclaw-main/src/gateway/server-methods.ts`: mapa de metodos del gateway.
- `../openclaw-main/src/gateway/server-methods-list.ts`: inventario y forma de los metodos/eventos.
- `../openclaw-main/src/gateway/server-http.ts`: superficie HTTP del gateway.
- `../openclaw-main/src/gateway/server-broadcast.ts`: fanout de eventos con `seq` y `stateVersion`.
- `../openclaw-main/src/gateway/server-chat.ts`: traduccion entre runtime del agente y eventos de chat/UI.
- `../openclaw-main/src/gateway/node-registry.ts`: runtime RPC de nodos.
- `../openclaw-main/src/gateway/exec-approval-manager.ts`: aprobaciones en memoria y `allow-once`.
- `../openclaw-main/src/gateway/node-invoke-system-run-approval.ts`: aprobaciones fuertes de `system.run`.
- `../openclaw-main/src/gateway/control-ui.ts`: servido de la Control UI con politica propia.
- `../openclaw-main/src/gateway/security-path.ts`: canonicalizacion defensiva de rutas.

## Runtime del agente

- `../openclaw-main/docs/concepts/agent.md`: contrato del workspace y sesiones.
- `../openclaw-main/docs/concepts/model-failover.md`: rotacion de auth y fallback de modelos.
- `../openclaw-main/src/agents/pi-embedded-runner/run.ts`: orchestrator principal del agente.
- `../openclaw-main/src/agents/pi-embedded-runner/run/setup.ts`: ensamblaje de sesion, tools, auth y contexto.
- `../openclaw-main/src/agents/pi-embedded-runner/compact.ts`: compaction, hooks y session maintenance.
- `../openclaw-main/src/agents/pi-embedded-runner/run/attempt.ts`: intento concreto de ejecucion.
- `../openclaw-main/src/agents/pi-embedded-runner/system-prompt.ts`: construccion del system prompt real.
- `../openclaw-main/src/agents/pi-embedded-runner/tool-result-truncation.ts`: proteccion del contexto.
- `../openclaw-main/src/agents/pi-embedded-runner/lanes.ts`: control de concurrencia.
- `../openclaw-main/src/context-engine/index.ts`: capa de contexto selectivo.
- `../openclaw-main/src/context-engine/registry.ts`: registro de estrategias de contexto.
- `../openclaw-main/src/agents/bash-tools.exec.ts`: ejecucion local con policy, host selection y approvals.

## Routing y pairing

- `../openclaw-main/docs/channels/channel-routing.md`: reglas de routing.
- `../openclaw-main/docs/channels/pairing.md`: pairing de DMs y nodos.
- `../openclaw-main/src/routing/resolve-route.ts`: seleccion del agente correcto.
- `../openclaw-main/src/routing/session-key.ts`: forma de las session keys.
- `../openclaw-main/src/pairing/pairing-store.ts`: store con lock, TTL y cap.
- `../openclaw-main/src/pairing/setup-code.ts`: bootstrap para nodos.
- `../openclaw-main/src/auto-reply/reply/inbound-dedupe.ts`: evita correr dos veces el mismo inbound.
- `../openclaw-main/src/auto-reply/reply/get-reply.ts`: pipeline de respuesta antes del runner.
- `../openclaw-main/src/auto-reply/reply/agent-runner.ts`: turn execution, queue y followups.
- `../openclaw-main/src/auto-reply/reply/reply-delivery.ts`: entrega final y block streaming.

## Plugins y extensiones

- `../openclaw-main/docs/tools/plugin.md`: vista de usuario del sistema de plugins.
- `../openclaw-main/docs/plugins/architecture.md`: arquitectura profunda del plugin system.
- `../openclaw-main/src/plugins/discovery.ts`: roots, ownership y discovery seguro.
- `../openclaw-main/src/plugins/loader.ts`: discovery, cache y carga runtime.
- `../openclaw-main/src/plugins/registry.ts`: registry central.
- `../openclaw-main/src/plugins/runtime.ts`: runtime snapshot y facade de capacidades cargadas.
- `../openclaw-main/src/plugins/contracts/registry.ts`: contrato esperado del registry.
- `../openclaw-main/src/plugin-sdk/plugin-entry.ts`: entrypoint del SDK de plugins.
- `../openclaw-main/src/plugin-sdk/api-baseline.ts`: baseline del API publico del SDK.
- `../openclaw-main/extensions/openai/openclaw.plugin.json`: ejemplo de manifest de provider.
- `../openclaw-main/extensions/openai/index.ts`: ejemplo de plugin multi-capability.
- `../openclaw-main/extensions/telegram/openclaw.plugin.json`: ejemplo de manifest de canal.
- `../openclaw-main/extensions/telegram/index.ts`: ejemplo de channel plugin entry.
- `../openclaw-main/extensions/telegram/src/channel.ts`: complejidad real de un canal maduro.

## Setup y experiencia de operador

- `../openclaw-main/docs/start/wizard.md`: onboarding CLI.
- `../openclaw-main/docs/start/wizard-cli-reference.md`: detalles finos del wizard.
- `../openclaw-main/src/wizard/setup.ts`: flujo principal del setup.
- `../openclaw-main/src/wizard/setup.finalize.ts`: cierre del wizard y health guidance.
- `../openclaw-main/src/commands/onboard-helpers.ts`: utilidades del flujo.
- `../openclaw-main/src/commands/onboard-non-interactive/local.ts`: setup local automatizable.
- `../openclaw-main/src/commands/onboard-non-interactive/local/daemon-install.ts`: instalacion de servicio con prechecks.
- `../openclaw-main/src/commands/doctor/repair-sequencing.ts`: secuencia de autoreparacion de config.
- `../openclaw-main/src/commands/doctor/shared/stale-plugin-config.ts`: limpieza de referencias stale a plugins.

## ACP y control plane externo

- `../openclaw-main/src/acp/server.ts`: bridge ACP montado sobre el Gateway real.
- `../openclaw-main/src/acp/translator.ts`: traduccion entre eventos/metodos ACP y Gateway.
- `../openclaw-main/src/acp/policy.ts`: policy de habilitacion y allowlist de agentes.
- `../openclaw-main/src/acp/control-plane/manager.core.ts`: session manager ACP.
- `../openclaw-main/src/acp/control-plane/manager.runtime-controls.ts`: aplicacion de controles segun capacidades.
- `../openclaw-main/src/acp/control-plane/runtime-cache.ts`: cache de runtimes ACP por actor.
- `../openclaw-main/src/acp/runtime/registry.ts`: registro de backends ACP disponibles.
- `../openclaw-main/src/acp/persistent-bindings.lifecycle.ts`: bindings persistentes entre conversaciones y sesiones ACP.

## Ejecucion, sandbox y nodos

- `../openclaw-main/docs/nodes/index.md`: mapa conceptual del plano de nodos.
- `../openclaw-main/src/node-host/runner.ts`: nodo local conectado al Gateway con caps/comandos reales.
- `../openclaw-main/src/node-host/invoke.ts`: dispatch local de `node.invoke.request`.
- `../openclaw-main/src/node-host/invoke-system-run.ts`: revalidacion local de `system.run`.
- `../openclaw-main/src/node-host/invoke-system-run-plan.ts`: plan canonico y endurecimiento de paths/operandos.
- `../openclaw-main/src/node-host/exec-policy.ts`: decision local de allowlist/ask.
- `../openclaw-main/src/agents/sandbox/config.ts`: seleccion/configuracion del backend de sandbox.
- `../openclaw-main/src/agents/sandbox/backend.ts`: contrato de backend pluggable.
- `../openclaw-main/src/agents/sandbox/registry.ts`: registro de runtimes sandbox.
- `../openclaw-main/src/agents/sandbox/tool-policy.ts`: policy de tools dentro del sandbox.
- `../openclaw-main/src/agents/sandbox/validate-sandbox-security.ts`: hardening de binds/red/profiles.
- `../openclaw-main/src/agents/sandbox/fs-bridge.ts`: operaciones de FS ancladas y seguras.
- `../openclaw-main/src/process/exec.ts`: capa base de ejecucion multiplataforma.
- `../openclaw-main/src/process/command-queue.ts`: lanes y serializacion de comandos.
- `../openclaw-main/src/process/supervisor/supervisor.ts`: supervisor de procesos `child`/`pty`.
- `../openclaw-main/src/canvas-host/server.ts`: canvas host local.
- `../openclaw-main/src/canvas-host/a2ui.ts`: bridge de acciones y servido de A2UI.
- `../openclaw-main/src/canvas-host/file-resolver.ts`: resolucion segura de archivos del canvas.

## UI y apps

- `../openclaw-main/ui/src/ui/app.ts`: punto de entrada de la Control UI.
- `../openclaw-main/ui/src/ui/gateway.ts`: cliente gateway de la UI.
- `../openclaw-main/ui/src/ui/controllers/chat.ts`: controlador de chat.
- `../openclaw-main/apps/shared/OpenClawKit/Package.swift`: libreria Swift compartida.
- `../openclaw-main/apps/shared/OpenClawKit/Sources/OpenClawKit/GatewayNodeSession.swift`: modelo de sesion de nodo.
- `../openclaw-main/apps/macos/Sources/OpenClaw/GatewayConnection.swift`: conexion del cliente macOS.
- `../openclaw-main/apps/macos/Sources/OpenClaw/OnboardingView+Wizard.swift`: onboarding macOS.
- `../openclaw-main/apps/ios/Sources/Gateway/GatewayConnectionController.swift`: conexion iOS.
- `../openclaw-main/apps/ios/Sources/Capabilities/NodeCapabilityRouter.swift`: dispatch de capacidades del nodo.

## Calidad, seguridad y operaciones

- `../openclaw-main/docs/help/testing.md`: mapa de pruebas.
- `../openclaw-main/docs/gateway/security/index.md`: modelo de seguridad.
- `../openclaw-main/docs/security/formal-verification.md`: modelos formales.
- `../openclaw-main/src/config/io.ts`: auditoria y health de config en disco.
- `../openclaw-main/src/config/redact-snapshot.ts`: redaccion de snapshots de config.
- `../openclaw-main/src/config/doc-baseline.ts`: baseline de documentacion/config schema.
- `../openclaw-main/.github/workflows/ci.yml`: pipeline de CI.
- `../openclaw-main/scripts/check-architecture-smells.mjs`: guardrail de arquitectura.
- `../openclaw-main/Dockerfile`: empaquetado serio.
- `../openclaw-main/docker-compose.yml`: despliegue local/servido.
- `../openclaw-main/render.yaml`: ejemplo de despliegue remoto.

## Automatizacion y scheduler

- `../openclaw-main/src/flows/channel-setup.ts`: onboarding de canales via plugins y adapters.
- `../openclaw-main/src/flows/provider-flow.ts`: descubrimiento de providers para setup/model picker.
- `../openclaw-main/src/cron/service.ts`: fachada del scheduler.
- `../openclaw-main/src/cron/service/jobs.ts`: validacion, normalizacion y calculo de proximas ejecuciones.
- `../openclaw-main/src/cron/service/store.ts`: persistencia del cron store.
- `../openclaw-main/src/cron/isolated-agent/run.ts`: ejecucion de jobs en sesiones/agents aislados.

## Durabilidad de sesiones

- `../openclaw-main/src/config/sessions/paths.ts`: layout por agente, validacion y containment de rutas.
- `../openclaw-main/src/config/sessions/store.ts`: store principal con locks, caches y mantenimiento.
- `../openclaw-main/src/config/sessions/store-read.ts`: lectura readonly segura del store.
- `../openclaw-main/src/config/sessions/store-maintenance.ts`: pruning, caps y presupuesto.
- `../openclaw-main/src/config/sessions/disk-budget.ts`: sweep de disco y high-water logic.
- `../openclaw-main/src/config/sessions/artifacts.ts`: convenciones de archivos archivados.
- `../openclaw-main/src/config/sessions/transcript.ts`: persistencia del transcript y mirroring de mensajes.
- `../openclaw-main/src/config/sessions/targets.ts`: descubrimiento de stores y targets multi-agent.
- `../openclaw-main/src/sessions/transcript-events.ts`: eventos de actualizacion del transcript.
- `../openclaw-main/src/sessions/session-lifecycle-events.ts`: eventos de ciclo de vida de sesiones.
- `../openclaw-main/src/sessions/input-provenance.ts`: provenance inter-sesion y continuidad de entrada.

## Lectura final

Si alguien entiende bien los archivos anteriores, ya entiende casi todo lo que explica por que OpenClaw:

- es usable
- no depende de un solo proveedor
- no depende de un solo cliente
- no depende de un solo canal
- y se ve mantenible a futuro
