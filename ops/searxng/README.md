# SearXNG para LifeOS — buscador propio, cerrado a todo lo demás

## Por qué existe

Axi busca en internet a través de DuckDuckGo Lite. Medido el 2026-08-19 desde
el VPS:

```
$ curl -A "Mozilla/5.0" "https://lite.duckduckgo.com/lite/?q=presion+arterial+normal"
202
"Unfortunately, bots use DuckDuckGo too. Please complete the following
 challenge... Select all squares containing a duck"
```

Un CAPTCHA. No es un fallo de LifeOS: DuckDuckGo bloquea a quien consulta
desde una IP de centro de datos, y con el tiempo también a quien lo hace muy
seguido desde una casa. Depender de eso significa que la búsqueda de Axi
funciona hasta el día que deja de funcionar, sin aviso y sin que podamos
arreglarlo.

Un SearXNG propio quita esa dependencia: consulta a varios buscadores, agrega
los resultados y responde en JSON. Es el mismo trato que ya tienen las
actualizaciones y la sincronización — el VPS presta el servicio, y los datos
del usuario no se quedan ahí.

## El guardarraíl: sólo LifeOS entra

Una instancia de SearXNG abierta en internet se convierte en el buscador
gratuito de cualquiera que encuentre la URL, y son nuestros recursos y nuestra
IP los que se queman. Así que:

1. **SearXNG NO se publica.** No lleva etiquetas de Traefik y no tiene ruta
   propia: sólo existe dentro de la red `coolify`.
2. **Delante va una puerta nginx** que exige la cabecera
   `X-LifeOS-Search-Key`. Sin ella, 403 antes de tocar el buscador.
3. **Rate limit en Traefik**, igual que el OTA, para que una clave filtrada no
   se traduzca en carga ilimitada.
4. **Sólo `/search` con `format=json`.** Ni la interfaz web, ni las
   preferencias, ni las estadísticas: nada que invite a usarlo como buscador
   general desde un navegador.

La clave vive donde ya viven las otras: en `mobile/tools/ota-publish.env`
(ignorado por git) y en la configuración de la app, nunca en este repositorio.

## Cómo se despliega

La fuente de verdad es la base de datos de Coolify, igual que el OTA (ver
`ops/ota/docker-compose.yml`). Este directorio es la copia revisada, para que
un cambio tenga historia y se pueda leer sin entrar al VPS.

1. En Coolify: nuevo servicio → Docker Compose → pegar `docker-compose.yml`.
2. Subir `searxng-settings.yml` y `search-gate.conf` al directorio del
   servicio, y ajustar las dos rutas del compose con el UUID que Coolify
   asigne.
3. Generar la clave y el secreto:
   ```
   openssl rand -hex 32   # X-LifeOS-Search-Key
   openssl rand -hex 32   # SEARXNG_SECRET
   ```
4. Comprobar desde FUERA del VPS (nunca por loopback, que no atraviesa el
   proxy):
   ```
   ssh devbox "curl -s -o /dev/null -w '%{http_code}\n' \
     https://search.lifeos.hectormr.com/search?q=hola&format=json"
   # 403  <- sin clave, correcto

   ssh devbox "curl -s -H 'X-LifeOS-Search-Key: <clave>' \
     'https://search.lifeos.hectormr.com/search?q=hola&format=json' | head -c 200"
   # {"query":"hola","results":[...
   ```
5. En la app: Ajustes → Búsqueda web → SearXNG, y pegar la URL base.

## Lo que NO hace

No guarda consultas. SearXNG no lleva registro por defecto y aquí se deja así:
lo que alguien busca es tan suyo como lo que le cuenta a Axi, y este servidor
no se entera de ninguna de las dos cosas.

## Cómo quedó desplegado de verdad (2026-08-20)

El VPS **ya tenía** un SearXNG corriendo desde hacía tres semanas, en el
proyecto `personal` de Coolify, sin etiquetas de Traefik — es decir, ya cumplía
la parte importante del guardarraíl: no existía ruta hacia él desde internet.
Levantar un segundo habría duplicado 512 MB de RAM para nada, así que se
reutilizó ese y sólo se añadió lo que faltaba:

1. **JSON habilitado.** SearXNG lo trae apagado de fábrica: `format=json`
   respondía `403 Forbidden`, y sin eso la búsqueda de Axi simplemente no
   existe. Se añadió `search.formats: [html, json]` a su `settings.yml`
   (respaldo en `settings.yml.bak-20260820`) y se reinició.

2. **La puerta, como servicio nuevo de Coolify** (`lifeos-search-gate`, en el
   proyecto LifeOS): un nginx que exige `X-LifeOS-Search-Key`, sólo deja pasar
   `/search` con `format=json`, y está unido a la vez a la red `coolify` (para
   Traefik) y a la red privada del SearXNG. La configuración va inline en el
   compose (`configs:`), así que no hay ningún archivo suelto en el host.

3. **DNS y TLS:** `search.lifeos.hectormr.com` → 74.208.78.93, sin proxy de
   Cloudflare, igual que el OTA, con el certificado que emite Traefik.

Comprobado desde fuera del VPS, no desde dentro:

```
sin llave              → 403
con llave              → 200 y resultados reales
/  /preferences /stats → 404
/search sin format=json→ 403
/health                → 200 (a propósito: saber que está en pie sin abrir nada)
```

La respuesta trae `unresponsive_engines: [duckduckgo: CAPTCHA, startpage:
CAPTCHA]` y aun así devuelve resultados: eso es exactamente para lo que sirve
un metabuscador, y es la razón de todo esto.

## La llave

Vive en `~/.config/lifeos/search-key.txt` (0600) y en `tools/ota-publish.env`,
que no se versiona. Va compilada en la app con
`--dart-define=LIFEOS_SEARCH_KEY`, nunca en las preferencias: así no hay
ninguna pantalla desde la que pueda salir, y viaja como cabecera, no en la URL
—donde acabaría en el registro del servidor y en cualquier historial.

Para rotarla: cambiar el archivo, redesplegar `lifeos-search-gate` y publicar.
