# 02 - Host CLI And Onboarding

## Donde vive la logica host-side

La pieza central es `../NemoClaw-main/bin/nemoclaw.js`.

Ese archivo no es un launcher trivial.
Hace varias cosas importantes:

- resuelve `openshell`
- decide que comandos son globales
- reconcilia gateway y sandbox tras reinicios o drift
- invoca `openshell` con wrappers propios
- valida nombres de sandbox
- centraliza `connect`, `status`, `logs`, `destroy`, `policy-*`, `start`, `stop`, `setup-spark` y `onboard`

## Lo que realmente productiza NemoClaw

La capa mas valiosa del repo esta en `bin/lib/onboard.js`.

Ese wizard convierte un stack potencialmente confuso en un flujo guiado:

- detectar runtime de contenedores por plataforma
- elegir proveedor de inferencia
- validar endpoint y modelo antes de crear el sandbox
- pedir o reutilizar credenciales
- correr preflight checks
- crear gateway, provider, policy y sandbox
- persistir estado suficiente para reanudar o reparar

## Onboarding como motor del producto

La arquitectura de producto real esta en la experiencia de onboard:

1. elegir provider y modelo
2. validar que la conectividad y runtime sirven
3. decidir nombre del sandbox
4. configurar policy presets
5. crear o reconciliar gateway y sandbox
6. dejar comandos claros de `connect`, `status` y `logs`

Eso baja mucho la friccion comparado con pedir al usuario que aprenda OpenShell primero.

## Que soporta hoy

Del lado no experimental, el wizard contempla:

- NVIDIA Endpoints
- OpenAI
- Anthropic
- Gemini
- endpoints OpenAI-compatible
- endpoints Anthropic-compatible
- Ollama local en el flujo estandar

Y deja `vLLM` y algunas rutas locales como caminos mas experimentales.

## Preflight y validacion

Antes de tocar el sandbox, NemoClaw hace cheques concretos:

- puerto del gateway con `lsof` y probe TCP
- runtime soportado por plataforma
- problemas de cgroup v2 en Spark/Ubuntu 24.04/WSL2
- restricciones de nombres RFC 1123
- reuso o limpieza de gateways/sandboxes previos

Esto importa porque el proyecto no asume "maquina limpia"; asume maquinas que fallan, reinician y ya tienen residuos.

## Lo mas inteligente del CLI

Lo mejor de `bin/nemoclaw.js` no es el parseo de comandos.
Es la capa de reconciliacion:

- detecta si el gateway `nemoclaw` existe pero esta caido
- intenta reseleccionarlo o reiniciarlo
- distingue sandbox faltante de gateway roto
- devuelve hints concretos en vez de errores opacos

Eso convierte fallos de infraestructura en pasos de recovery entendibles.

## Conclusion de esta capa

NemoClaw se vuelve producto por esta razon:

> la complejidad operacional no se deja al usuario; se absorbe en el CLI y en el wizard de onboard.
