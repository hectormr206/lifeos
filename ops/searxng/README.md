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
