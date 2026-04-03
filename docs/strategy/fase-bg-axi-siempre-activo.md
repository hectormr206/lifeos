# Fase BG — Axi Siempre Activo (sin login requerido)

> Que Axi responda por Telegram incluso si la laptop esta encendida
> pero el usuario no ha iniciado sesion.

## Problema actual

`lifeosd` es un servicio de usuario (`systemctl --user`). Solo corre cuando
hay una sesion activa (login en escritorio). Si la laptop se reinicia y
nadie inicia sesion, Axi no responde en Telegram.

## Solucion propuesta

Mover lifeosd (o una version reducida) a un servicio de sistema que corra
sin sesion grafica.

### Opcion A: Servicio de sistema con User=lifeos

```ini
[Service]
User=lifeos
Type=simple
ExecStart=/usr/bin/lifeosd --headless
```

**Ventaja:** Arranca sin login, responde Telegram, cron, reportes.
**Limitacion:** Sin acceso a PipeWire, D-Bus de sesion, Wayland.
No puede: voz, screenshots, control de ventanas, overlay, wake word.

### Opcion B: Modo dual (headless + full)

1. Servicio de sistema: `lifeosd --headless` (Telegram, cron, memoria, calendario)
2. Servicio de usuario: `lifeosd --desktop` (voz, vision, overlay, control escritorio)
3. Cuando el usuario inicia sesion, el modo desktop se conecta al headless
4. Si el usuario cierra sesion, headless sigue corriendo

**Ventaja:** Lo mejor de ambos mundos.
**Complejidad:** Alta — requiere separar el daemon en dos modos.

### Opcion C: Autologin + bloqueo de pantalla

1. Configurar autologin del usuario en GDM/COSMIC greeter
2. La sesion inicia automaticamente al encender
3. La pantalla se bloquea inmediatamente (seguro)
4. lifeosd corre porque hay sesion activa

**Ventaja:** Simple, sin cambios en el daemon.
**Limitacion:** Menos seguro si alguien tiene acceso fisico.

### Opcion D: lingering (systemd)

```bash
loginctl enable-linger lifeos
```

Esto permite que los servicios de usuario corran sin sesion activa.
lifeosd arrancaria al boot como servicio de usuario persistente.

**Ventaja:** Minimo cambio — un solo comando.
**Limitacion:** Algunos servicios de sesion (PipeWire, D-Bus) pueden no
estar disponibles. Necesita validacion.

## Recomendacion

**Opcion D (lingering)** es la mas simple y la que tiene mayor probabilidad
de funcionar sin cambios en el daemon. Si PipeWire no esta disponible,
los sentidos que dependen de audio fallaran silenciosamente pero Telegram,
cron, calendario, memoria y reportes seguirian funcionando.

Validar con:
```bash
loginctl enable-linger lifeos
sudo reboot
# NO iniciar sesion
# Verificar desde otro dispositivo si Axi responde en Telegram
```

## Tareas

- [ ] BG.1 — Investigar si `loginctl enable-linger` permite lifeosd sin sesion
- [ ] BG.2 — Validar que funciones dependen de sesion grafica
- [ ] BG.3 — Modo headless: flag `--headless` que deshabilita sentidos graficos
- [ ] BG.4 — Documentar que funciona y que no sin sesion
- [ ] BG.5 — Si linger funciona, habilitarlo por defecto en first-boot
