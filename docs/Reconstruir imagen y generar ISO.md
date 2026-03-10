# Reconstruir imagen y generar artefactos de LifeOS

> Nota (Fase 3): la imagen base incluye dependencias de desarrollo para compilar `life` y `lifeosd --all-features` directamente en LifeOS (sin instalar `-devel` manualmente en host), y stack de virtualizacion local (`qemu-kvm`, `libvirt`, drivers `qemu/network`, `virsh`, `virt-install`, `virt-manager` RPM).

## Opcion rapida (pipeline completo)

Comando por defecto (genera ISO):

```bash
sudo bash scripts/build-iso.sh
```

ISO sin modelo prebundled (recomendado para iteracion rapida):

```bash
sudo bash scripts/build-iso-without-model.sh
```

ISO con modelo prebundled (imagen mas pesada):

```bash
sudo bash scripts/build-iso-with-model.sh
```

Comando para `raw` (tu caso de prueba):

```bash
sudo bash scripts/build-iso.sh --type raw --image localhost/lifeos:latest
```

Esto ejecuta automaticamente los pasos 0-3:

1. Limpia imagen anterior
2. Reconstruye imagen con `--no-cache`
3. Verifica imagen (os-release, llama-server, CLI, compat docker/podman-compose; modelo si esta pre-cargado)
4. Genera artefacto con `bootc-image-builder` (`iso`, `raw`, `qcow2` o `vmdk`)

Log completo del build:

- `output/build-iso.log` (siempre se actualiza como ultimo build)
- `output/build-<type>.log` (log por tipo ejecutado)
- `output/build-raw.log` (tipo `raw`)
- `output/build-qcow2.log` (tipo `qcow2`)
- `output/build-vmdk.log` (tipo `vmdk`)

Al finalizar cada build del pipeline completo (`build-iso*.sh`), comparte esto para revision rapida:

```bash
tail -n 250 output/build-iso.log
```

Filtro rapido de errores/warnings:

```bash
rg -n "ERROR|\\[ERROR\\]|\\[!\\]|failed|FATAL" output/build-*.log
```

Con esos dos comandos podemos validar si quedo correcto o donde ajustar.

## Iteracion realmente rapida (sin reconstruir toda la imagen)

Si no cambiaste `image/Containerfile` ni paquetes base, usa la imagen ya construida y solo genera el artefacto:

```bash
sudo bash scripts/generate-iso-simple.sh --type iso --image localhost/lifeos:latest
```

Regla practica:

- Cambios en sistema base (Containerfile, paquetes, servicios base): usa `build-iso*.sh` (pipeline completo).
- Cambios de empaquetado/artefacto o solo necesitas nueva ISO del mismo `localhost/lifeos:latest`: usa `generate-iso-simple.sh`.

Importante para logs en iteracion rapida:

- `generate-iso-simple.sh` no escribe `output/build-iso.log` por si solo.
- Para no confundirte con logs viejos, ejecutalo con `tee`:

```bash
sudo bash scripts/generate-iso-simple.sh --type iso --image localhost/lifeos:latest 2>&1 | tee output/generate-iso.log
```

- Revision rapida despues de iteracion rapida:

```bash
tail -n 250 output/generate-iso.log
rg -n "ERROR|\\[ERROR\\]|\\[!\\]|failed|FATAL" output/generate-iso.log
```

Nota importante (seguridad de disco en ISO):

- Modo default: `LIFEOS_INSTALL_MODE=interactive`
  Anaconda pide seleccionar disco destino manualmente.
- Modo CI/lab: `LIFEOS_INSTALL_MODE=unattended`
  Puede particionar automaticamente y sobrescribir disco.

Nota importante (tamano de imagen/modelo):

- Default: `LIFEOS_PRELOAD_MODEL=false` (build mas ligero)
- Con modelo: `LIFEOS_PRELOAD_MODEL=true` (descarga varios GB adicionales)

## Pasos manuales (si se necesita correr por separado)

```bash
# 0. Limpiar
sudo podman rmi -f localhost/lifeos:latest

# 1A. Reconstruir la imagen desde cero (sin modelo, recomendado)
sudo podman build --no-cache --build-arg LIFEOS_PRELOAD_MODEL=false -t localhost/lifeos:latest -f image/Containerfile .

# 1B. Reconstruir la imagen desde cero (con modelo prebundled)
sudo podman build --no-cache --build-arg LIFEOS_PRELOAD_MODEL=true -t localhost/lifeos:with-model -f image/Containerfile .

# 2. Verificar que tiene ID=fedora
podman run --rm localhost/lifeos:latest cat /usr/lib/os-release | grep ^ID=

# 3. Generar artefacto
chmod +x scripts/generate-iso-simple.sh
sudo bash scripts/generate-iso-simple.sh --type raw --image localhost/lifeos:latest

# Para ISO:
sudo bash scripts/generate-iso-simple.sh --type iso --image localhost/lifeos:latest
```

## Actualizar LifeOS instalado (robusto + logs)

Para equipos ya instalados (no para construir ISO), usar el flujo robusto:

```bash
# Canal stable + apply update
sudo ./scripts/update-lifeos.sh --channel stable --apply --yes
```

Con log personalizado para soporte:

```bash
sudo ./scripts/update-lifeos.sh --channel stable --apply --log-file /var/tmp/lifeos-update.log
```

## Probar en maquina virtual (recomendado en Linux)

### Flujo recomendado (script unico, sin duplicar ISO)

Usa el helper oficial para crear/recrear una VM de pruebas leyendo la ISO directo desde `output/`:

```bash
cd /var/home/lifeos/personalProjects/gama/lifeos
scripts/vm-test-reset.sh run
```

Comportamiento por defecto:

- Conexion: `qemu:///session` (evita problemas de permisos sobre `/var/home/lifeos`).
- Disco VM: `20G`.
- ISO: `output/lifeos-latest.iso` mapeada automaticamente a `~/.local/share/libvirt/boot/` via hardlink o reflink (sin duplicar datos cuando el FS lo permite).
- Si ya existe la VM con el mismo nombre, la destruye y recrea para no acumular espacio.

Opciones utiles:

```bash
# Ver estado
scripts/vm-test-reset.sh status

# Menor RAM/disco para pruebas rapidas
scripts/vm-test-reset.sh run --memory 6144 --disk-size 18

# Limpiar VM y disco
scripts/vm-test-reset.sh clean
```

### Opcion 1 (recomendada): virt-manager + KVM/QEMU

- Verificar backend (ya viene en imagen LifeOS reciente):

```bash
command -v virt-manager
command -v virsh
sudo systemctl enable --now libvirtd || sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket
```

- Crear VM (UEFI, 4 vCPU, 8 GB RAM, 40 GB disco)
- Montar `output/lifeos-latest.iso` como CD/DVD
- Tipo de OS: Fedora Linux
- Arrancar, instalar en disco virtual y reiniciar
- Usuario default de pruebas: `lifeos` / `lifeos`

### Opcion 2: GNOME Boxes (flujo rapido)

- Instalar:

```bash
sudo dnf install -y gnome-boxes
```

- Abrir Boxes -> New -> seleccionar `output/lifeos-latest.iso`
- Asignar recursos (>= 4 vCPU, >= 8 GB RAM, >= 40 GB disco)
- Instalar LifeOS y validar comandos post-instalacion

### Opcion 3: VirtualBox (si ya lo usas)

- Crear VM: Fedora 64-bit, 4 GB RAM, 40 GB disco, EFI habilitado
- Montar ISO como unidad optica
- Arrancar y en Anaconda seleccionar disco destino
- Usuario: `lifeos` / Password: `lifeos`

### Copiar/pegar dentro de la VM

En VMs con SPICE (virt-manager/virt-viewer), el portapapeles bidireccional requiere:

1. Canal SPICE en la VM (el script `scripts/vm-test-reset.sh` ya lo agrega).
2. `spice-vdagent` dentro del guest (incluido en la imagen LifeOS nueva).

Validacion dentro de la VM:

```bash
rpm -q spice-vdagent
systemctl status spice-vdagentd --no-pager
```

Si no esta activo:

```bash
sudo systemctl enable --now spice-vdagentd
```

## Verificacion post-instalacion

```bash
sudo life check
```

Por defecto, `life check` trata validaciones de contenedores como advertencias en una ISO limpia.
Si quieres modo estricto para contenedores (fallar el check):

```bash
LIFEOS_CHECK_STRICT_CONTAINERS=1 sudo life check
```

Tambien se puede correr directamente:

```bash
sudo lifeos-check
```

## Validacion en ISO instalada (sin repo local)

En una instalacion limpia de ISO no existe automaticamente `/var/home/lifeos/personalProjects/gama/lifeos`.
Para validar la imagen sin repo, usa solo comandos del sistema:

```bash
life check
life status
life update --dry
life recover
life lab status --json
```

Si quieres correr hardening completo de desarrollo (`scripts/check-daemon-prereqs.sh` y `scripts/phase3-hardening-checks.sh`), primero clona el repo dentro de la VM o monta una carpeta compartida con el arbol de `lifeos`.
