# Tarea: depurar un crash a partir del traceback

En producción, el gate de notificaciones truena así:

```
Traceback (most recent call last):
  File "app.py", line 12, in <module>
    if should_notify({"max_daily_alerts": "3"}, 15, 1):
  File "notifier.py", line 9, in should_notify
    return alert_budget(raw_config, sent_today) > 0
  File "alerts.py", line 9, in alert_budget
    return settings["max_daily_alerts"] - sent_today
TypeError: unsupported operand type(s) for -: 'str' and 'int'
```

El síntoma aparece en `notifier.py`/`alerts.py`, pero piensa en DÓNDE nace el
dato malo: la configuración viene de un archivo INI, así que sus valores
llegan como strings. Corrige la CAUSA RAÍZ (una sola corrección en el lugar
correcto arregla también las horas de silencio con strings), no cada síntoma
por separado.

## Reglas

- Los archivos `test_*.py` son de solo lectura; la suite codifica el
  comportamiento correcto.
- No agregues conversiones dispersas en cada función que consume la
  configuración: repara el origen.
- Usa `run_tests` para verificar: la tarea termina cuando toda la suite pasa.
