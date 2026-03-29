# Troubleshooting — Guia de Solucion de Problemas

## Axi no responde en Telegram

**Diagnostico:**
```bash
systemctl status lifeosd          # El daemon esta corriendo?
systemctl status llama-server     # El modelo local esta corriendo?
life doctor                       # Diagnostico completo
journalctl -u lifeosd --since "10 min ago"  # Logs recientes
```

**Solucion comun:**
- Si lifeosd no esta corriendo: `sudo systemctl restart lifeosd`
- Si llama-server no esta corriendo: `sudo systemctl restart llama-server`
- Si el modelo local fallo: verificar `/var/lib/lifeos/models/` tiene el archivo .gguf

## Modelo local muy lento

**Diagnostico:**
```bash
life ai status                    # Ver velocidad del modelo
nvidia-smi                        # GPU esta disponible?
cat /etc/lifeos/llama-server.env  # GPU_LAYERS=99?
```

**Solucion:**
- Si GPU_LAYERS=0: `sudo sed -i 's/GPU_LAYERS=0/GPU_LAYERS=99/' /etc/lifeos/llama-server.env && sudo systemctl restart llama-server`
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
- O: `life safe-mode exit`

## El dashboard no abre

```bash
curl http://127.0.0.1:8081/api/v1/health  # La API responde?
```

Si no responde, reinicia el daemon: `sudo systemctl restart lifeosd`

## Doctor reporta base de datos corrupta

Si `life doctor` reporta un error de integridad en alguna base de datos:

```bash
# Hacer backup del archivo corrupto
cp /var/lib/lifeos/<nombre>.db /var/lib/lifeos/<nombre>.db.corrupt

# Eliminar para que el daemon la recree
rm /var/lib/lifeos/<nombre>.db

# Reiniciar el daemon
sudo systemctl restart lifeosd
```

## Espacio en disco bajo

Si `life doctor` reporta espacio bajo:

```bash
# Ver uso de disco
df -h /var

# Limpiar modelos viejos (mantener solo el activo)
ls -lh /var/lib/lifeos/models/
# Eliminar modelos que ya no uses

# Limpiar journals viejos
sudo journalctl --vacuum-size=100M
```
