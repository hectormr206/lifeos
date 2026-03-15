# LifeOS Project State (Source Of Truth)

Last updated: 2026-03-15

## Scope and Ownership

This file is the operational status source for execution.
Normative architecture and contracts remain in:

- `docs/lifeos-ai-distribution.md`

Historical snapshots (deprecated) are kept for traceability only:

- `ROADMAP.md`
- `PROJECT_STATUS.md`
- `FINAL_STATUS.md`

## LifeOS 1.0 Wedge

LifeOS 1.0 is focused on a single wedge:

- AI local-first workstation for founders and developers.

Out of wedge for 1.0 hardening:

- New ecosystem surfaces that do not improve daily-driver reliability.
- B2B experimental swarm/RFC work.

## Current Phase: Phase 4 and 4.5 Closed (Field Validated) / Phase 5 Pending

Phase 4 focused on making LifeOS feel alive through real sensory interaction:
voice (bidirectional), vision (screen awareness), camera (presence detection),
and GPU-accelerated inference with automatic NVIDIA offload.

Key deliverables:
- STT always-on + TTS local (Piper) → full voice conversation loop
- Screen awareness with vision models (Qwen3.5 mmproj) on GPU
- Camera presence detection (not face-ID) with ergonomic alerts
- Axi animated states in overlay (8 states: idle, listening, thinking, speaking, watching, error, offline, night)
- Automatic NVIDIA GPU offload for LLM and vision models
- Graceful degradation when hardware/consent is missing

Phase 4.5 completed the model-lifecycle corrective layer before Phase 5 scale work:
heavy models now run under explicit user lifecycle control with signed catalog,
default-model coherence, companion mmproj mapping, and update-safe persistence
so OS upgrades do not override model decisions already made by the user.

## Execution Status

- Phase 0: closed at baseline.
- Phase 1: closed at baseline + ISO validation.
- Phase 2: closed at baseline (multimodal + memory + runtime controls).
- Phase 2.5: closed at baseline (visual identity + UX foundations).
- Phase 3: closed (hardening + dogfooding + closeout). Evidence: `evidence/phase-3/phase-3-closeout.md`.
- Phase 4: **CLOSED IN REPO + FIELD VALIDATED** — verified on image `edge-20260314-db06313` with full GPU offload and sensory bench in target hardware.
- Phase 4.5: **CLOSED IN REPO + FIELD VALIDATED** — selector/API lifecycle, fit and cleanup guardrails validated on target hardware with `Qwen3.5-0.8B-Q4_K_M`.
- Phase 5: pending (ecosystem, sync, scale).

## Phase 4 Closed Blocks

| Block | Priority | Focus |
|-------|----------|-------|
| Voice bidirectional | Closed | STT always-on + TTS + voice loop pipeline |
| GPU offload NVIDIA | Closed | Auto-detect + offload LLM/vision to GPU |
| Vision contextual | Closed | Screen awareness + OCR + vision queries |
| Sensory orchestration | Closed | Unified pipeline + model coordination |
| Presence & camera | Closed | Presence detect + fatigue/posture alerts |
| Axi alive in desktop | Closed | Animated states + proactive notifications |

## Phase 4.5 Closed Blocks

| Block | Priority | Focus |
|-------|----------|-------|
| Selector visual + catalogo firmado | Closed | Roster inicial, firma de catalogo y metadata de fit/costo |
| Coherencia runtime por defecto | Closed | `MODEL`/`MMPROJ` sincronizados desde una sola fuente |
| Persistencia y tombstones | Closed | `installed/selected/pinned/removed_by_user` resiliente a updates |
| Awareness por hardware | Closed | `GPU_LAYERS` dinamico por RAM/VRAM/presion termica |
| Guardrails de disco y cleanup | Closed | Pre-chequeo de espacio, cleanup seguro y dry-run |
| Portabilidad de inventario | Closed | Export/import por dispositivo con pinning controlado |

## Reference Links

- Normative spec: `docs/lifeos-ai-distribution.md` (Phase 4 section)
- Phase 3 evidence: `evidence/phase-3/phase-3-closeout.md`
- Phase 4 evidence: `evidence/phase-4/phase-4-closeout.md`
- Phase 4 ISO/VM validation: `evidence/phase-4/iso-vm-regression-validation.md`
- Phase 4.5 evidence: `evidence/phase-4.5/phase-4.5-closeout.md`
- Recovery operations: `docs/incident-response-playbook.md`
- Build and ISO workflow: `docs/Reconstruir imagen y generar ISO.md`
- Update channels: `docs/update-channels.md`
