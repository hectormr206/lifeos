# 06 - Onboarding And Operator Experience

## Tesis

Una gran parte del exito practico de OpenClaw viene de algo que muchos repos subestiman:

- instalarlo
- configurarlo
- dejarlo andando
- entender que hacer despues

OpenClaw trata esa parte como un feature central del producto.

## Onboarding como producto, no como script secundario

La doc `docs/start/wizard.md` y el codigo `src/wizard/setup.ts` dejan esto clarisimo.

El onboarding:

- no solo pide una API key
- no solo crea un archivo config
- no solo imprime "good luck"

Hace un flujo guiado completo.

## Lo que configura

Segun la documentacion, el onboarding local cubre:

1. modelo y auth
2. workspace
3. gateway
4. canales
5. daemon
6. health check
7. skills

Eso ya explica por que el producto se siente "listo para usar" y no "armalo tu".

## `src/wizard/setup.ts`

Este archivo enseguida muestra varias decisiones maduras:

- obliga a aceptar el riesgo antes de continuar
- detecta config invalida y manda a `openclaw doctor`
- detecta notices de compatibilidad de plugins
- separa `quickstart` y `advanced`
- maneja reset de config, creds, sessions y workspace
- resuelve preferencias de auth provider
- escribe metadata de wizard

No es un wizard cosmetico. Es una capa operacional.

## QuickStart y defaults inteligentes

Los defaults del producto ya estan pensados para reducir errores:

- gateway local por loopback
- puerto `18789`
- auth token incluso en loopback
- `tools.profile: "coding"` para setups locales nuevos
- `session.dmScope: "per-channel-peer"`
- Tailscale apagado por default

Eso es importante porque convierte el mejor camino en el camino mas facil.

## Riesgo explicado desde el inicio

Me parece una de las mejores senales del repo:

- el wizard no vende seguridad magica
- dice explicitamente que OpenClaw es personal-by-default
- explica que multiusuario y herramientas amplias requieren hardening extra
- recomienda `openclaw security audit`

Eso reduce la probabilidad de que el usuario termine con una instalacion insegura por optimismo del producto.

## Local vs remote

OpenClaw tambien separa dos escenarios reales:

- gateway local
- gateway remoto

Y deja claro que el modo remoto:

- configura el cliente local
- no reescribe cosas en el host remoto

Eso suena obvio, pero evita mucha confusion operativa.

## Daemonizacion

El onboarding no se queda en "corre este comando cada vez".
Tambien cubre:

- LaunchAgent en macOS
- systemd user unit en Linux/WSL2

Eso es exactamente lo que hace que el asistente se comporte como servicio siempre vivo.

## Channels y skills durante setup

El wizard puede:

- configurar canales
- configurar web search
- instalar skills recomendadas

Con esto el usuario termina no solo con un modelo autenticado, sino con un asistente util.

## Resultado de UX

En la practica, OpenClaw hizo algo muy valioso:

- llevo decisiones complejas de arquitectura y seguridad hacia un flow guiado
- sin esconder del todo las consecuencias

Es decir:

- reduce friccion
- pero no reduce honestidad

## Por que esto ayuda a que "muchas personas lo usen"

Porque entre una plataforma poderosa y una plataforma adoptada hay un puente:

- setup
- defaults
- health checks
- autostart
- docs
- recovery paths

OpenClaw si construyo ese puente.

## Conclusion

El onboarding es una de las razones principales por las que OpenClaw ya funciona como producto:

- convierte una arquitectura compleja en un flujo util
- pone defaults razonables
- te deja servicio corriendo
- y reduce muchisimo el costo mental de empezar
