# Mejoras al Sistema de Memoria — Prevenir Basura a Largo Plazo

> No es una fase nueva — son mejoras incrementales al memory_plane existente.

**Problema:** Despues de meses/anos de uso, la memoria de Axi se llena de entradas irrelevantes que degradan la calidad de busqueda. El espacio (~50 MB/ano) no es problema — la señal-vs-ruido si.

**Lo que ya funciona:** importance scoring, access tracking, consolidacion 6h, knowledge graph decay, vision cleanup, storage housekeeping.

---

## Prioridad 1 — Alto impacto, bajo esfuerzo

- [ ] **Filtro de basura en ingesta** — skip entradas <10 chars o que matcheen filler: `^(ok|hola|gracias|si|no|listo|vale|bien|ya|mmm|aja)$`
- [ ] **Decay exponencial** — reemplazar `-5` lineal con `importance * 0.85^(days/30)` para entradas con access_count < 2
- [ ] **Memorias permanentes** — columna `permanent INTEGER DEFAULT 0`. Skip decay/delete. Para: nombre del usuario, familia, preferencias explicitas ("recuerda que...")
- [ ] **Dedup semantica** — en consolidacion, encontrar pares con cosine similarity >0.90, merge en la de mayor importancia

## Prioridad 2 — Impacto medio

- [ ] **Resumen de clusters viejos** — agrupar memorias >30 dias por tags, si un cluster tiene 10+ entradas, LLM resume en 1 entrada con importancia max. Archivar originales
- [ ] **Bonus por conexiones** — memorias con muchas relaciones en knowledge graph resisten decay: `bonus = min(links * 2, 20)`
- [ ] **Tagging emocional** — detectar frustracion/logro en mensajes, boost +15 importancia
- [ ] **Piso de relevancia para entidades importantes** — entidades con 3+ relaciones nunca bajan de 0.3

## Prioridad 3 — Polish

- [ ] **Storage por tiers** — entradas >6 meses con importancia <30 van a `memory_archive` (tabla separada, excluida de busqueda por defecto)
- [ ] **Dashboard de salud de memoria** — `/api/v1/memory/health`: total entradas, por tier, importancia promedio, dedup count
- [ ] **Comandos de usuario** — `/memory cleanup` (ver stats + aprobar purge), `/memory protect <tema>` (marcar como permanente)

---

## Inspiracion biologica

| Cerebro humano | Equivalente en Axi |
|----------------|-------------------|
| Curva de Ebbinghaus (olvido exponencial) | Decay exponencial en vez de lineal |
| Consolidacion durante el sueno | Ciclo de consolidacion cada 6h (ya existe) |
| Emociones fortalecen memorias | Tagging emocional → boost importancia |
| Memorias conectadas persisten | Graph-degree bonus en consolidacion |
| Resumen de experiencias en narrativas | LLM summarization de clusters viejos |
| Memoria a largo plazo vs corto plazo | Tier hot (reciente) vs archive (viejo) |
