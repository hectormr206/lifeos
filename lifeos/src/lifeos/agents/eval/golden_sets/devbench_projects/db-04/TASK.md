# Tarea: refactorizar `summary.py` bajo contrato

`orders_grand_total` es un copy-paste degradado de `order_total`: al duplicar
el código se perdió el descuento por volumen (líneas con `qty >= 10` llevan
10% de descuento en esa línea) y además llama al servicio de precios UNA VEZ
POR LÍNEA, cuando `pricing.fetch_price` es una operación cara.

## Contrato (codificado en `test_summary.py`)

1. Comportamiento: el gran total debe aplicar el mismo descuento por volumen
   que `order_total` (el gran total = suma de los totales por orden).
2. Costo: al calcular el gran total, `pricing.fetch_price` debe ejecutarse a
   lo más UNA VEZ POR PRODUCTO DISTINTO — y al menos una vez (no vale
   reimplementar la búsqueda de precios por fuera de `pricing.fetch_price`).

La solución esperada elimina la duplicación (una sola ruta de cálculo) y
consulta cada precio distinto una sola vez (por ejemplo, con un mapa
producto→precio construido al inicio).

## Reglas

- Modifica solo `summary.py`. No toques `pricing.py` ni los `test_*.py`.
- Sigue usando `pricing.fetch_price` como acceso a precios (vía el módulo).
- Usa `run_tests` para verificar: la tarea termina cuando toda la suite pasa.
