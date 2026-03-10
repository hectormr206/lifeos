# Phase 2.5 KPI Results

**Phase:** 2.5  
**Date:** 2026-03-09  
**Owner:** @hectormr206  
**Status:** PARTIAL (single-user dogfooding; gate still pending)

---

## 1) KPI Targets (from spec)

- KPI-1: SUS >= 80 (new Linux users)
- KPI-2: p95 overlay/panel open time has no regression vs Phase 2 baseline
- KPI-3: >= 85% users report visual comfort in sessions >= 3h

---

## 2) Data Sources

- SUS survey form: pending (not run yet)
- Performance logs source: manual CLI sampling (`life overlay show/hide`, 30 samples)
- Session telemetry source: user session + screenshots + local shell output
- Sample size:
  - Users: 1 (internal founder dogfooding)
  - Overlay latency samples: 30

---

## 3) Results

### KPI-1: SUS

- Sample size: 0 (no SUS survey yet)
- Mean SUS: N/A
- Median SUS: N/A
- Target met: pending

### KPI-2: p95 overlay/panel latency

- Baseline p95 (Phase 2): pending reference not yet frozen
- Current p95 (Phase 2.5): **83 ms**
- Delta: pending (baseline missing)
- Target met: partial evidence (measurement collected; gate decision pending baseline + multiuser pass)

Raw output provided by tester:

```text
samples=30 p95_ms=83
```

### KPI-3: Visual comfort >=3h

- Total eligible participants: 1
- Positive comfort responses: pending formal survey
- Percentage: pending formal survey
- Target met: pending

---

## 4) Evidence Attachments

- [ ] Raw survey export attached
- [x] Raw latency logs attached (single-user run)
- [x] Aggregation method documented
- [ ] Outliers documented

Links:
- Artifact 1: `/var/home/lifeos/Documents/overlay-latency-ms-*.txt` (single-user run from 2026-03-09 session)
- Artifact 2: RE2 + NVIDIA runtime screenshots collected in this session (Phase 2 hardware evidence)

Aggregation method:

```bash
OUT="/var/home/lifeos/Documents/overlay-latency-ms-$(date +%F-%H%M).txt"
for i in $(seq 1 30); do
  t0=$(date +%s%3N); life overlay show >/dev/null 2>&1; t1=$(date +%s%3N)
  life overlay hide >/dev/null 2>&1
  echo $((t1-t0))
  sleep 0.3
done | tee "$OUT"
sort -n "$OUT" | awk 'BEGIN{c=0}{a[++c]=$1}END{i=int((0.95*c)+0.999); if(i<1)i=1; if(i>c)i=c; print "samples="c,"p95_ms="a[i]}'
```

---

## 5) Decision

- Phase 2.5 KPI gate: **PENDING**
- Required follow-up actions:
  - Run SUS with new Linux users and compute KPI-1.
  - Freeze Phase 2 p95 baseline to evaluate regression/no-regression formally.
  - Run visual comfort survey for sessions >=3h with enough participants to validate KPI-3.
