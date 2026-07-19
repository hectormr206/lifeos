# Tarea: unifica el parseo de dinero y arregla la causa raíz

El reporte de gastos truena cuando un monto trae separador de miles. En
producción, `report.total_for` revienta así con datos reales del CSV:

```
Traceback (most recent call last):
  File "app.py", line 8, in <module>
    report.total_for(transacciones, "comida")
  File "report.py", line 14, in total_for
    total += float(raw)
ValueError: could not convert string to float: '1,250.50'
```

Hay DOS problemas y están relacionados:

1. `money.parse_amount` es la única fuente de verdad para convertir un string
   de dinero (`"$1,250.50"`) a `float`, pero nunca quita la coma de los miles,
   así que también falla.
2. `report.total_for` NO usa `money.parse_amount`: tiene una copia del parseo
   pegada en línea (drift), por eso arrastra el mismo bug.

Corrige la CAUSA RAÍZ una sola vez en `money.parse_amount` (que maneje el
separador de miles) y haz que `report.total_for` DELEGUE en ese helper
compartido en lugar de re-parsear a mano. Una prueba verifica, con
`monkeypatch`, que `total_for` efectivamente llama a `parse_amount`.

## Reglas

- Los archivos `test_*.py` son de solo lectura; la suite codifica el
  comportamiento correcto.
- No agregues conversiones dispersas: repara el origen (`parse_amount`) y
  reutilízalo.
- Usa `run_tests` para verificar: la tarea termina cuando toda la suite pasa.
