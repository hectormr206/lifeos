# LifeOS Public Docs

Public-facing documents that summarize LifeOS in a way that is easier to understand for users, sponsors, press, and early adopters.

These files are not a replacement for the technical strategy docs. They are a curated layer built on top of them.

Public messaging should keep the project's Mexican origin visible without presenting LifeOS as region-exclusive or as folkloric branding.

## Public maturity taxonomy

Public-facing copy should classify claims with this taxonomy whenever a feature's maturity matters:

- **validated on host** - integrated and recently observed working on real hardware
- **integrated in repo** - wired in code/runtime, but not recently re-validated on a real host
- **experimental** - promising or partially wired, but not yet a stable end-to-end product path
- **shipped disabled / feature-gated** - present in repo, but not enabled in the default image/runtime path

Rule of thumb: do not let `repo capability`, `default shipped behavior`, and `host validation` collapse into the same sentence.

## Files

- [roadmap.md](roadmap.md) - Public roadmap in English
- [roadmap.es-mx.md](roadmap.es-mx.md) - Hoja de ruta publica en espanol mexicano

## Source of truth

The canonical technical source of truth still lives in:

- [../strategy/unified-strategy.md](../strategy/unified-strategy.md)
- [../strategy/auditoria-estados-reales.md](../strategy/auditoria-estados-reales.md)

If there is ever a mismatch, the technical strategy docs win and the public docs should be updated.
