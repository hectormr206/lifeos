# Troubleshooting — Guia de Solucion de Problemas

## Axi no responde en Telegram

**Diagnostico:**
```bash
life doctor                      # Diagnostico rapido de salud
systemctl --user status lifeosd   # El daemon principal corre como user service
sudo systemctl status llama-server  # Runtime canonico del modelo local
curl http://127.0.0.1:8081/api/v1/health  # Estado agregado de salud
journalctl --user -u lifeosd --since "10 min ago"  # Logs recientes del daemon
```

**Solucion comun:**
- Si lifeosd no esta corriendo: `systemctl --user restart lifeosd`
- Si llama-server no esta corriendo: `sudo systemctl restart llama-server`
- Si `llama-server` no existe como system service en ese host: probar `systemctl --user restart llama-server` solo como fallback puntual
- Si el modelo local fallo: verificar `/var/lib/lifeos/models/` tiene el archivo .gguf

## Modelo local muy lento

**Diagnostico:**
```bash
life doctor                      # Verifica provider local, disco y DBs
life ai status                    # Ver velocidad del modelo
nvidia-smi                        # GPU esta disponible?
grep '^LIFEOS_AI_GPU_LAYERS=' /etc/lifeos/llama-server.env
```

**Solucion:**
- Si `LIFEOS_AI_GPU_LAYERS=0`: editar `/etc/lifeos/llama-server.env` y reiniciar `llama-server`
- Si no hay GPU: el modelo corre en CPU (8-30 tok/s es normal)

## Actualizacion de LifeOS fallo

**Diagnostico:**
```bash
sudo bootc status                 # Ver estado actual
sudo bootc rollback               # Volver a la version anterior
```

## Axi entro en modo seguro

Esto pasa cuando el daemon crasheo 3+ veces seguidas. Axi deja de hacer cambios autonomos por seguridad.

**Para salir:**
- Escribe "exit safe mode" en Telegram
- O: `life safe-mode status`
- O: `curl -X POST http://127.0.0.1:8081/api/v1/safe-mode/exit`

## El dashboard no abre

```bash
life doctor
curl http://127.0.0.1:8081/api/v1/health  # La API responde?
```

Si no responde, reinicia el daemon: `systemctl --user restart lifeosd`

## La API de health reporta base de datos corrupta

Si `curl http://127.0.0.1:8081/api/v1/health` o los logs reportan un error de integridad en alguna base de datos:

```bash
life doctor
# Hacer backup del archivo corrupto
cp /var/lib/lifeos/<nombre>.db /var/lib/lifeos/<nombre>.db.corrupt

# Eliminar para que el daemon la recree
rm /var/lib/lifeos/<nombre>.db

# Reiniciar el daemon
systemctl --user restart lifeosd
```

## Espacio en disco bajo

Si `curl http://127.0.0.1:8081/api/v1/health` o los logs reportan espacio bajo:

```bash
life doctor
# Ver uso de disco
df -h /var

# Limpiar modelos viejos (mantener solo el activo)
ls -lh /var/lib/lifeos/models/
# Eliminar modelos que ya no uses

# Limpiar journals viejos
sudo journalctl --vacuum-size=100M
```
