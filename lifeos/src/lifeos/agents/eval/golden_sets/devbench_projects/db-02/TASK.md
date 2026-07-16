# Tarea: corregir la búsqueda de horarios libres

El módulo de citas devuelve horarios incorrectos. Los usuarios reportan dos
síntomas:

1. Se "pierde" el último horario del día: con horario de 9:00 a 10:00 y citas
   de 30 minutos solo se ofrece las 9:00, cuando las 9:30 también cabe (una
   cita puede terminar EXACTAMENTE a la hora de cierre).
2. Una cita que termina a las 9:00 bloquea indebidamente el horario que
   empieza a las 9:00 (los intervalos que solo se tocan NO se traslapan).

La suite de tests (`test_booking.py`) codifica el comportamiento correcto y es
la fuente de la verdad.

## Reglas

- El defecto está repartido entre `slots.py` y `booking.py`; corrige solo lo
  necesario en esos dos archivos.
- Los archivos `test_*.py` son de solo lectura.
- Usa `run_tests` para verificar: la tarea termina cuando toda la suite pasa.
