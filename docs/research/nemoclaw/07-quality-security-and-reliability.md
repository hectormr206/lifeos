# 07 - Quality, Security And Reliability

## Resultado del baseline de seguridad

Mi lectura general es `caution`, no `stop`.

No vi señales claras de repo comprometido ni codigo escondido raro en las superficies principales.
Si vi varias zonas que merecen respeto operativo:

- uso intensivo de `bash -c`
- bootstrap remoto por `curl`
- manejo de credenciales por env vars
- bridges auxiliares que construyen comandos shell

Eso no huele a compromiso. Huele a un repo temprano que intenta ser util rapido pero sin ignorar del todo la seguridad.

## Medidas positivas que si estan presentes

### 1. Tests de seguridad dedicados

La carpeta `test/` no solo prueba happy paths.
Tambien hay tests como:

- `credential-exposure.test.js`
- `security-binaries-restriction.test.js`
- `security-c2-dockerfile-injection.test.js`
- `security-c4-manifest-traversal.test.js`
- `service-env.test.js`
- `validate-blueprint.test.ts`

Eso es buena señal: el equipo ya esta pensando en clases de fallo especificas.

### 2. SSRF guard

`ssrf.ts` bloquea endpoints privados e internos antes de aceptar overrides.
Eso es especialmente importante para providers custom y rutas compatibles OpenAI/Anthropic.

### 3. Secret hygiene razonable

Se ve intencion de no filtrar secretos:

- redaccion en `debug.sh`
- persistencia sin credenciales en `plan.json`
- tests para que `NVIDIA_API_KEY` no se cuele al sandbox por error
- `registry.json` y `credentials.json` del lado host

### 4. Policy enforcement real

La policy no es cosmetica.
Restringe:

- filesystem
- process user
- network egress
- binarios autorizados por endpoint

Eso es una capa real de contencion.

### 5. CI relativamente seria

El repo trae:

- PR lint + tests + coverage ratchet
- build de imagenes sandbox
- docs preview con separacion segura para PRs
- checks de pin de Docker base image
- e2e nocturno
- e2e remoto con Brev

No es una CI minima.

## Riesgos residuales

### 1. Mucho shell orchestration

Gran parte del repo sigue dependiendo de:

- `spawnSync("bash", ["-c", ...])`
- wrappers shell en scripts
- interpolacion cuidadosa con `shellQuote`

Eso puede ser suficientemente seguro si se mantiene bien, pero concentra bastante riesgo en los wrappers.

### 2. Bridges auxiliares mas sensibles

El bridge de Telegram exporta la clave de inferencia y lanza comandos remotos dentro del sandbox.
Esta quoteado y el nombre de sandbox se valida, pero sigue siendo una de las superficies mas delicadas del repo.

### 3. Installer remoto

El flujo recomendado usa:

- `curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash`

Eso es normal en tooling de developer experience, pero siempre es una superficie de supply chain a vigilar.

## Lo que me da confianza

Lo que mas confianza da no es que el repo sea perfecto.
Es que ya trae varias pruebas y documentos justamente donde cabria esperar fallos:

- install
- port conflicts
- gateway recovery
- sandbox isolation
- credential sanitization
- name validation
- policy merge

## Conclusion

NemoClaw esta en alpha, y se nota.
Pero tambien se nota que NVIDIA intento meter desde temprano:

- policy como sistema
- tests de seguridad concretos
- recovery post-fallo
- CI para las rutas principales

Eso lo pone por encima de muchos proyectos "AI wrapper" que solo funcionan en el happy path.
