# 04 - Inference Routing And Policy

## La tesis del producto

NemoClaw no vende solo "corremos OpenClaw".
Vende esta idea:

> el agente no llama proveedores ni internet libremente; todo pasa por rutas y politicas declaradas.

Eso se ve en dos lugares:

- `nemoclaw-blueprint/blueprint.yaml`
- `nemoclaw-blueprint/policies/openclaw-sandbox.yaml`

## Profiles de inferencia

El blueprint trae perfiles concretos:

- `default`
- `ncp`
- `nim-local`
- `vllm`

Cada uno define:

- tipo de provider
- nombre de provider
- endpoint
- modelo
- variable de credencial

El runner traduce eso a comandos `openshell provider create` e `openshell inference set`.

## Punto importante de seguridad

En `runner.ts`, cuando crea el provider, pasa a OpenShell el **nombre** de la variable de credencial y scopea el valor al subprocess.
Ademas, al persistir `plan.json`, omite `credential_env` y `credential_default`.

Eso no elimina todo riesgo, pero si muestra intencion clara de no dejar secretos tirados en estado local.

## Guard contra SSRF

`nemoclaw/src/blueprint/ssrf.ts` valida endpoints antes de aceptarlos.

Bloquea:

- `127.0.0.0/8`
- `10.0.0.0/8`
- `172.16.0.0/12`
- `192.168.0.0/16`
- `169.254.0.0/16`
- `::1`
- `fd00::/8`

Y solo permite `http://` y `https://`.

Eso importa mucho para endpoints compatibles custom:

- evita apuntar "sin querer" a cosas internas del host
- fuerza a que el override de endpoint pase por una validacion real

## Policy baseline

El archivo `openclaw-sandbox.yaml` es de los mas reveladores del repo.

La filosofia es:

- deny by default
- filesystem muy acotado
- binaries permitidos por endpoint
- reglas HTTP por host cuando importa

## Filesystem policy

La separacion mas importante es esta:

- `/.openclaw` como config inmutable
- `/.openclaw-data` como estado escribible

Eso evita que el propio agente manipule libremente su config de gateway/auth mientras sigue teniendo espacio escribible para trabajo normal.

## Network policy

El baseline preautoriza un set minimo:

- NVIDIA inference
- GitHub
- `openclaw.ai`
- `clawhub.com`
- docs de OpenClaw
- npm
- algunos bridges de mensajeria como Telegram o Discord

Pero no los deja a todos libres para cualquier binario.
El policy amarra hosts a binarios concretos como:

- `openclaw`
- `gh`
- `git`
- `node`
- `claude`

Ese detalle vale mucho porque baja exfiltration accidental via `curl`, `python` o binarios arbitrarios.

## Presets

`bin/lib/policies.js` maneja presets como:

- `npm`
- `pypi`
- `telegram`
- `slack`
- `discord`
- `jira`
- `outlook`

Y los mergea sobre la policy viva del sandbox o sobre el baseline.

## Lo que demuestra esta capa

NemoClaw esta pensado para que policy e inference no sean un paso posterior.
Son parte del primer setup.

Eso es exactamente lo contrario a muchos wrappers de agente donde primero "haces que funcione" y despues "ya veremos seguridad".
