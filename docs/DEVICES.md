# Dispositivos de prueba y cómo llegar a ellos

Escrito porque se perdió una tarde entera con la conclusión equivocada: `adb
devices` sale vacío en el VPS, y de ahí deduje —dos veces, y se lo dije al
usuario— que no había forma de llegar al teléfono. Sí la hay.

## Pixel de pruebas (Pixel 7 Pro)

| | |
|---|---|
| Serial adb | `29291FDH300LVM` |
| Conectado a | la ASUS con Proxmox, por USB |
| Host | `asus` → `10.66.66.4` por la VPN WireGuard (hostname real: `pve`) |
| adb vive en | el contenedor LXC **212**, `android-lab` — **no** en el host |

```bash
# ¿Está enchufado y con depuración?  (desde el VPS)
ssh asus "lsusb | grep -i google"
#   18d1:4ee7 Google Inc. Nexus/Pixel Device (charging + debug)

# Listar dispositivos
ssh asus "pct exec 212 -- adb devices -l"

# Cualquier comando
ssh asus "pct exec 212 -- adb -s 29291FDH300LVM shell <cmd>"

# Versión instalada de LifeOS
ssh asus "pct exec 212 -- adb -s 29291FDH300LVM shell dumpsys package com.lifeos.lifeos | grep versionCode"
```

**`adb devices` en el VPS SIEMPRE está vacío.** Eso no es evidencia de que el
dispositivo no esté disponible: solo de que no es local. Antes de decir "no
tengo acceso", probar la ruta de arriba.

## Otros hosts en la VPN

| Host | IP | Qué es |
|---|---|---|
| `laptop` | 10.66.66.2 | la CachyOS del usuario |
| `pixel` | 10.66.66.3 | su Pixel personal |
| `asus` | 10.66.66.4 | Proxmox (`pve`), donde cuelga el Pixel de pruebas |
| `moto` | 10.66.66.5 | |
| `devbox` | 10.66.66.6 | contenedor 210 en la ASUS; el que se usa para medir **desde fuera** del VPS |
| `huawei` | 10.66.66.7 | |

En la ASUS también corren los contenedores `200 docker`, `210 devbox`,
`211 ci-runner` y `212 android-lab`, y las VMs `201 win11` y
`202 macos-lab-sequoia15` (paradas).

## Por qué importa medir desde `devbox` y no desde el VPS

Un `curl` a un servicio del propio VPS sale por loopback y **no atraviesa el
cortafuegos ni el proxy**, así que da verde aunque desde internet esté cerrado.
Cualquier comprobación de que algo "está vivo" se hace desde `devbox`, nunca
desde el VPS contra sí mismo.
