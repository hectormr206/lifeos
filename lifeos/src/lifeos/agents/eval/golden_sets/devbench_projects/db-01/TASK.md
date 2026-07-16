# Tarea: implementar `moving_average`

En `stats.py` falta implementar la función `moving_average(values, window)`.

## Contrato exacto

- Devuelve la lista de promedios de cada ventana de `window` valores
  consecutivos: para `[1, 2, 3, 4, 5]` con `window=3` el resultado es
  `[2.0, 3.0, 4.0]`.
- Cada promedio debe ser `float`.
- `window == 1` devuelve los mismos valores (como floats).
- `window == len(values)` devuelve una lista con un solo promedio.
- Si `window < 1` o `window > len(values)`, lanza `ValueError`.

## Reglas

- Modifica SOLO `stats.py` (los archivos `test_*.py` son de solo lectura).
- No cambies `mean` ni `median`.
- Usa `run_tests` para verificar: la tarea termina cuando toda la suite pasa.
