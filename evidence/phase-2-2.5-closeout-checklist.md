# Phase 2 + 2.5 Closeout Checklist

Use this checklist to close pending items in `docs/lifeos-ai-distribution.md` with evidence links.

---

## 1) Phase 2 Pending Items

Source items:
- GPU hybrid support
- Steam/Proton + high-refresh/adaptive-sync
- ISO test on physical hardware

Evidence files:
- `evidence/phase-2/hardware-validation.md`
- `evidence/phase-2/iso-physical-test.md`

Checklist:
- [x] Fill `hardware-validation.md` completely and mark PASS/FAIL per item.
- [x] Fill `iso-physical-test.md` with installation + boot evidence.
- [x] Add links from spec item comments to these evidence files.
- [x] Mark corresponding Phase 2 checkboxes `[x]` only if evidence is PASS. _(GPU hybrid + Steam/Proton/display + ISO fisica actualizados en spec.)_

---

## 2) Phase 2.5 Pending Items (field validation)

Source items:
- legibility 4h+
- micro-interactions polish
- visual regression suite
- beta with new Linux users
- friction-driven adjustments
- KPI gates (SUS, p95 overlay, visual comfort)

Evidence files:
- `evidence/phase-2.5/ux-beta-report.md`
- `evidence/phase-2.5/kpi-results.md`

Checklist:
- [ ] Run UX beta and record findings in `ux-beta-report.md`.
- [ ] Record KPI numbers and gate status in `kpi-results.md`.
- [ ] Attach or link raw artifacts (survey export, logs, screenshots).
- [ ] Mark Phase 2.5 deferred checkboxes `[x]` only if metrics pass.

---

## 3) Hygiene Before Marking Complete

- [ ] Remove or reconcile duplicate bullet points in Phase 2 section to avoid ambiguous status.
- [ ] Ensure each `[x]` item has a traceable evidence link.
- [ ] Keep dates and image digests explicit in evidence docs.

---

## 4) Suggested PR Scope for Closure

- `docs/lifeos-ai-distribution.md`: update pending checkboxes + add evidence links.
- `evidence/phase-2/*.md`: finalized test evidence.
- `evidence/phase-2.5/*.md`: finalized UX and KPI evidence.

Recommended PR title:
- `docs(phase2): close hardware+ux evidence gates for phase 2 and 2.5`
