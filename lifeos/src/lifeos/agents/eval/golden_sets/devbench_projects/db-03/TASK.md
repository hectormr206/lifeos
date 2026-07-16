# Tarea: soportar fecha opcional en los gastos

Hoy cada línea de gasto es `MONTO CATEGORIA [NOTA...]`. Queremos aceptar
también un prefijo de fecha ISO opcional: `2026-07-01 150 comida tacos`.

## Contrato exacto

En `expense_parser.py`:

- Si el PRIMER token de la línea tiene forma `AAAA-MM-DD`, es la fecha del
  gasto y el resto de la línea se interpreta como hasta ahora.
- Todo registro devuelto lleva la clave `date`: el string de la fecha cuando
  la línea la trae, o `None` cuando no.

En `report.py`:

- Las líneas CON fecha se imprimen `FECHA  MONTO  CATEGORIA` (dos espacios
  entre columnas, monto con dos decimales, como ahora).
- Las líneas SIN fecha y la línea `TOTAL` conservan EXACTAMENTE el formato
  actual — hay tests de regresión que hoy pasan y deben seguir pasando.

## Reglas

- Toca solo `expense_parser.py` y `report.py`; los `test_*.py` son de solo
  lectura.
- Usa `run_tests` para verificar: la tarea termina cuando toda la suite pasa.
