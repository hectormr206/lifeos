# Funcionalidades de Axi en Telegram

> Documentacion de todas las funciones de interaccion de Axi via Telegram.
> Actualizado: 2026-04-01

## Reportes proactivos del sistema

Axi monitorea el sistema y envia reportes automaticos cuando detecta problemas.

### Umbrales de alertas

| Alerta | Umbral Warning | Umbral Critico | Fuente |
|---|---|---|---|
| CPU Temperatura | **90°C** | 95°C | /sys/class/thermal/ |
| GPU Temperatura | 85°C | 95°C | nvidia-smi |
| Disco /var | 85% | 95% | df (solo /var, NO /) |
| RAM | 90% uso | — | free -m |
| Firewall | nftables sin reglas | — | nft list ruleset |
| Sesion larga | 6+ horas **activas** | — | loginctl + idle detection |

**Nota sobre composefs**: El disco `/` (composefs) siempre muestra 100% en sistemas bootc inmutables.
Esto es normal por diseno. Solo se monitorea `/var`.

**Nota sobre temperatura**: Muchas laptops operan normalmente a 80-85°C bajo carga.
El umbral de warning se establece en 90°C para evitar alertas innecesarias.

### Deteccion de sesion activa

La alerta de "Llevas X horas activo" solo se envia si:
1. El usuario esta **realmente presente** (idle < 15 minutos)
2. La sesion de login lleva 6+ horas

Metodos de deteccion de actividad:
- **Primario**: D-Bus IdleMonitor (GNOME/COSMIC, compatible con Wayland)
- **Fallback**: xprintidle (X11)
- Si no puede detectar idle, asume que el usuario esta activo

Si la laptop esta encendida pero el usuario no esta (idle > 15 min),
**no se envia la alerta**.

## Contexto de respuestas (Reply)

Cuando el usuario usa la funcion "Responder" de Telegram para responder a un
mensaje especifico de Axi, el sistema extrae el texto del mensaje original
y lo incluye como contexto:

```
[Respondiendo a tu mensaje: "CPU a 82°C y Firewall inactivo..."]

En qué grados debe estar?
```

Esto permite que Axi entienda a que se refiere el usuario sin tener que
repetir todo el contexto.

## Reacciones con emojis

Cuando el usuario reacciona a un mensaje de Axi con un emoji, Axi responde
de forma contextual y aprende de la retroalimentacion:

### Reacciones positivas (guardan feedback en memoria)

| Emoji | Respuesta | Accion |
|---|---|---|
| ❤️ 😍 🥰 💘 | "Aww, gracias! Me alegra que te haya servido..." | — |
| 👍 👌 💯 🏆 | "Perfecto, anotado! Seguire por esa linea." | Guarda feedback positivo en MemoryPlane |
| 🎉 🤩 🔥 ⚡ | "Eso! A seguir con todo!" | — |

### Reacciones de confusion (ofrecen ayuda)

| Emoji | Respuesta |
|---|---|
| 🤔 🤨 😐 | "Veo que no quedo claro. Quieres que te lo explique de otra forma?" |

### Reacciones negativas (guardan feedback en memoria)

| Emoji | Respuesta | Accion |
|---|---|---|
| 👎 😢 💔 | "Entendido, no fue lo que esperabas. Dime como mejorar." | Guarda feedback negativo en MemoryPlane |

### Otras reacciones

| Emoji | Respuesta |
|---|---|
| 😁 🤣 | "Jaja me da gusto que te haya sacado una sonrisa!" |
| 🙏 🤗 🫡 | "Para eso estoy! Siempre listo para ayudarte." |
| 🤯 😱 😨 | "Impresionante verdad? Si tienes preguntas, dime!" |
| 😴 🥱 | "Te noto cansado. Tal vez es buen momento para un descanso?" |

### Aprendizaje via reacciones

Las reacciones 👍/👌/💯 y 👎/😢/💔 se almacenan en la MemoryPlane como
entradas de feedback con tags `reaction` + `positive`/`negative`.
Esto permite que Axi ajuste su comportamiento con el tiempo basandose
en que tipo de respuestas le gustan al usuario.

## Mensajes de voz

El sistema procesa mensajes de voz automaticamente:
1. Descarga el audio OGG de Telegram
2. Convierte a WAV via ffmpeg (16kHz, mono)
3. Transcribe con whisper-cli (modelo base, idioma español)
4. Procesa la transcripcion como texto normal en el agentic loop
5. Responde con texto + mensaje de voz (Piper TTS)

### Voz unificada

La voz de Axi es la misma en Telegram y en el sistema local:
- **Motor**: Piper TTS (resolucion dinamica de modelo y binario)
- **Modelo**: es_MX-claude-high.onnx (espanol mexicano, calidad alta)
- **Fallback**: espeak-ng con voz española
- **Rutas de busqueda**: /var/lib/lifeos/models/piper/, /usr/share/lifeos/models/piper/
- **Variable de entorno**: LIFEOS_TTS_MODEL para override

## Gestion de servicios (Tool #79)

Axi puede administrar servicios del sistema cuando el usuario lo solicita:

```
"Activa el firewall" → service_manage {service: "nftables", action: "start"}
```

Servicios permitidos: nftables, firewalld, llama-server, whisper-stt
Acciones: start, stop, restart, enable, disable, status

Requiere permisos sudo configurados en /etc/sudoers.d/lifeos-axi.

## Screenshots

Las capturas de pantalla se envian como **documentos** (no como fotos)
para preservar la resolucion original sin compresion de Telegram.

## Total de herramientas Telegram: 83

Ver telegram_tools.rs para la lista completa de tools #1-83.
