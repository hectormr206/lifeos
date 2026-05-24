# Axi — Instalación local

## 1. Verificar la cadena (ya hecho durante el bootstrap)

```fish
cd ~/LifeOS/lifeos/axi
.venv/bin/python -m axi._probe_capture 5
```

Hablá durante los 5 segundos. Debería imprimir la transcripción.

## 2. Probar el daemon a mano

En una terminal:

```fish
~/LifeOS/lifeos/axi/.venv/bin/python -m axi.daemon
```

En otra terminal:

```fish
~/LifeOS/lifeos/axi/scripts/axi-toggle   # arranca grabación
# hablá unos segundos…
~/LifeOS/lifeos/axi/scripts/axi-toggle   # detiene → transcribe → clipboard + notif
```

## 3. Auto-arranque al login (user systemd)

```fish
mkdir -p ~/.config/systemd/user
ln -sf ~/LifeOS/lifeos/axi/systemd/axi-voice.service ~/.config/systemd/user/axi-voice.service
systemctl --user daemon-reload
systemctl --user enable --now axi-voice.service
systemctl --user status axi-voice.service
```

Logs en vivo:

```fish
journalctl --user -u axi-voice -f
```

## 4. Atajo global Super+Space en KDE Plasma

Manual, una sola vez (30 segundos):

1. **System Settings → Shortcuts → Custom Shortcuts**
2. **Edit → New → Global Shortcut → Command/URL**
3. Trigger tab: presionar `Meta+Space` (Super+Space)
4. Action tab: `~/LifeOS/lifeos/axi/scripts/axi-toggle`
5. **Apply**

Probar: tap Super+Space → notificación "🎤 Escuchando". Hablar. Tap otra vez → transcripción al portapapeles.

## 5. Apagar / reiniciar / desinstalar

```fish
systemctl --user stop axi-voice.service
systemctl --user disable axi-voice.service
```
