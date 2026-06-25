#!/usr/bin/env python3
"""Wake-word live-test analyzer — the ONE post-session command.

Fire-and-forget harness for the LifeOS/Axi hands-free wake-word feature.
Héctor plays a game, invokes the wake-word, then runs this ONCE afterward to
get a decision table + verdict. No terminal babysitting during play.

Data sources (all read after the fact, no live services required to *parse*):
  - journald logs of the axi-voice unit (the wake path emits machine-parseable
    `wakeword-metric:` lines plus existing human log lines).
  - the `brain_metrics` table in the encrypted store (brain latency per ask).
  - optionally, a CPU/RAM CSV produced by scripts/wakeword_cpu_sample.sh.

The log PARSER (`parse_log_lines`) is a PURE function over an iterable of log
lines so it is unit-testable without journalctl or live services.

stdlib only, plus `from axi import store` for brain_metrics access.
"""

from __future__ import annotations

import argparse
import re
import statistics
import subprocess
import sys
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Verdict thresholds (architect-provided). Edit here to retune.
# All time thresholds are in SECONDS unless noted.
# ---------------------------------------------------------------------------
ROUND_TRIP_GREEN_S = 15.0          # p95 round-trip at/under this is green
ROUND_TRIP_SMALL_BRAIN_S = 15.0   # p95 over this -> recommend smaller game-brain
FALSE_TRIGGER_GREEN_MAX = 0       # spurious wakes at/under this is green
MISS_RATE_GREEN_MAX = 0.10        # fraction (no-wake / total transcripts) green at/under
CPU_IDLE_GREEN_MAX = 15.0         # idle CPU% at/under this is green
CPU_PEAK_GREEN_MAX = 120.0        # peak CPU% at/under this is green (one core ~100%)

# Log line markers ----------------------------------------------------------
_RE_WAKE_DETECTED = re.compile(r"wakeword-metric: wake_detected t=([0-9.]+) command=(.*)$")
_RE_ASK_START = re.compile(r"wakeword-metric: ask_start t=([0-9.]+)")
_RE_TTS_START = re.compile(r"wakeword-metric: tts_start t=([0-9.]+)")
_RE_TTS_DONE = re.compile(r"wakeword-metric: tts_done t=([0-9.]+)")
_RE_TRANSCRIPT = re.compile(r"wakeword: transcript=(.*)$")
_RE_NO_WAKE = re.compile(r"wakeword: no wake match for transcript (.*)$")
_RE_ANSWER = re.compile(r"wakeword answer: (.*)$")


@dataclass
class Invocation:
    """One wake event and the metrics correlated to it (next-event by ts)."""

    wake_detected: float
    command: str
    ask_start: float | None = None
    tts_start: float | None = None
    tts_done: float | None = None
    answer_seen: bool = False
    brain_latency_ms: int | None = None  # filled by correlate step

    @property
    def round_trip_s(self) -> float | None:
        """Full hands-free round-trip: tts_done - wake_detected."""
        if self.tts_done is None:
            return None
        return self.tts_done - self.wake_detected

    @property
    def tts_duration_s(self) -> float | None:
        if self.tts_start is None or self.tts_done is None:
            return None
        return self.tts_done - self.tts_start


@dataclass
class ParseResult:
    invocations: list[Invocation] = field(default_factory=list)
    transcript_count: int = 0
    no_wake_count: int = 0       # near-misses / false negatives at match step
    answer_count: int = 0


def parse_log_lines(lines) -> ParseResult:
    """Pure function: parse an iterable of log lines into a ParseResult.

    Lines may be raw journald `-o cat` output (just the message) or include a
    leading timestamp prefix — we only match on the message substrings, so both
    work. The `wakeword-metric:` lines carry their own epoch `t=`, so we never
    depend on journald's clock formatting.

    Correlation strategy: events are assigned to the most recent preceding
    wake_detected. This mirrors the real sequential flow
    (wake -> ask_start -> answer -> tts_start -> tts_done) per invocation.
    """
    result = ParseResult()
    current: Invocation | None = None

    for raw in lines:
        line = raw.rstrip("\n")

        m = _RE_WAKE_DETECTED.search(line)
        if m:
            current = Invocation(
                wake_detected=float(m.group(1)),
                command=m.group(2).strip(),
            )
            result.invocations.append(current)
            continue

        m = _RE_ASK_START.search(line)
        if m:
            if current is not None and current.ask_start is None:
                current.ask_start = float(m.group(1))
            continue

        m = _RE_TTS_START.search(line)
        if m:
            if current is not None and current.tts_start is None:
                current.tts_start = float(m.group(1))
            continue

        m = _RE_TTS_DONE.search(line)
        if m:
            if current is not None and current.tts_done is None:
                current.tts_done = float(m.group(1))
            continue

        m = _RE_ANSWER.search(line)
        if m:
            result.answer_count += 1
            if current is not None:
                current.answer_seen = True
            continue

        m = _RE_NO_WAKE.search(line)
        if m:
            result.no_wake_count += 1
            continue

        # transcript= must be checked AFTER no_wake (no_wake also references a
        # transcript but with different surrounding text).
        m = _RE_TRANSCRIPT.search(line)
        if m:
            result.transcript_count += 1
            continue

    return result


def correlate_brain_latency(invocations: list[Invocation], brain_rows) -> None:
    """Attach the nearest following brain_metrics row to each invocation.

    `brain_rows` is an iterable of (ts, latency_ms, model, ok) tuples, ASC by ts.
    For each wake, pick the first brain row whose ts >= the wake's ask_start
    (or wake_detected if ask_start missing) and before the next wake's anchor.
    """
    rows = sorted(brain_rows, key=lambda r: r[0])
    for i, inv in enumerate(invocations):
        anchor = inv.ask_start if inv.ask_start is not None else inv.wake_detected
        # upper bound: next invocation's anchor (exclusive)
        if i + 1 < len(invocations):
            nxt = invocations[i + 1]
            upper = nxt.ask_start if nxt.ask_start is not None else nxt.wake_detected
        else:
            upper = float("inf")
        for ts, latency_ms, _model, ok in rows:
            if ts >= anchor and ts < upper and ok:
                inv.brain_latency_ms = int(latency_ms)
                break


# --- stats helpers ---------------------------------------------------------

def _percentile(values: list[float], pct: float) -> float | None:
    """Nearest-rank percentile (pct in 0..100). None if no values."""
    if not values:
        return None
    s = sorted(values)
    if len(s) == 1:
        return s[0]
    # nearest-rank
    k = max(0, min(len(s) - 1, int(round((pct / 100.0) * (len(s) - 1)))))
    return s[k]


def _p50_p95(values: list[float]) -> tuple[float | None, float | None]:
    return _percentile(values, 50), _percentile(values, 95)


# --- CPU CSV ---------------------------------------------------------------

def summarize_cpu_csv(path: str) -> dict | None:
    """Read epoch,cpu_pct,rss_mb CSV. Return idle/peak summary or None."""
    cpus: list[float] = []
    rss: list[float] = []
    try:
        with open(path, encoding="utf-8") as fh:
            for ln in fh:
                ln = ln.strip()
                if not ln or ln.lower().startswith("epoch"):
                    continue
                parts = ln.split(",")
                if len(parts) < 3:
                    continue
                try:
                    cpus.append(float(parts[1]))
                    rss.append(float(parts[2]))
                except ValueError:
                    continue
    except OSError as e:
        print(f"  (could not read CPU CSV {path}: {e})", file=sys.stderr)
        return None
    if not cpus:
        return None
    return {
        "samples": len(cpus),
        "cpu_idle": min(cpus),        # idle proxy = lowest observed
        "cpu_peak": max(cpus),
        "cpu_p50": _percentile(cpus, 50),
        "rss_p50_mb": _percentile(rss, 50),
        "rss_peak_mb": max(rss),
    }


# --- verdict ---------------------------------------------------------------

def compute_verdict(
    *,
    round_trip_p95: float | None,
    false_trigger_count: int,
    miss_rate: float | None,
    cpu_idle: float | None,
    cpu_peak: float | None,
) -> tuple[str, list[str]]:
    """Return (overall, recommendations[]). overall is GREEN or ACTION-NEEDED."""
    recs: list[str] = []

    if false_trigger_count > FALSE_TRIGGER_GREEN_MAX:
        recs.append(
            f"False triggers={false_trigger_count} (>{FALSE_TRIGGER_GREEN_MAX}): "
            "escalate to openWakeWord (trained wake model, far fewer spurious wakes)."
        )

    if miss_rate is not None and miss_rate > MISS_RATE_GREEN_MAX:
        recs.append(
            f"Miss rate={miss_rate:.0%} (>{MISS_RATE_GREEN_MAX:.0%}): "
            "escalate to openWakeWord (improves wake recall)."
        )

    if round_trip_p95 is not None and round_trip_p95 > ROUND_TRIP_SMALL_BRAIN_S:
        recs.append(
            f"Round-trip p95={round_trip_p95:.1f}s (>{ROUND_TRIP_SMALL_BRAIN_S:.0f}s): "
            "use a smaller game-brain (e.g. gemma-e2b) for the wake co-pilot."
        )

    if cpu_idle is not None and cpu_idle > CPU_IDLE_GREEN_MAX:
        recs.append(
            f"Idle CPU={cpu_idle:.0f}% (>{CPU_IDLE_GREEN_MAX:.0f}%): "
            "wake listener is heavy at rest — profile before slice-2."
        )
    if cpu_peak is not None and cpu_peak > CPU_PEAK_GREEN_MAX:
        recs.append(
            f"Peak CPU={cpu_peak:.0f}% (>{CPU_PEAK_GREEN_MAX:.0f}%): "
            "investigate CPU spikes during wake processing."
        )

    if not recs:
        return "GREEN", [
            "All thresholds green — proceed to slice-2 (web-search wake co-pilot)."
        ]
    return "ACTION-NEEDED", recs


# --- journald -------------------------------------------------------------

def read_journal(since: str | None, minutes: int | None) -> list[str]:
    """Fetch axi-voice journal lines. -o cat gives bare messages."""
    cmd = ["journalctl", "--user", "-u", "axi-voice", "-o", "cat", "--no-pager"]
    if minutes is not None:
        cmd += ["--since", f"-{minutes}min"]
    elif since:
        cmd += ["--since", since]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=False)
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"journalctl failed: {e}", file=sys.stderr)
        return []
    return out.stdout.splitlines()


def read_brain_metrics(since_epoch: float | None):
    """Read brain_metrics rows since an epoch. Returns list of (ts,latency,model,ok)."""
    try:
        from axi import store  # local import: avoids hard dep for pure-parser tests
    except Exception as e:  # noqa: BLE001
        print(f"  (store unavailable, skipping brain latency: {e})", file=sys.stderr)
        return []
    lower = since_epoch if since_epoch is not None else 0.0
    try:
        conn = store._connect()  # noqa: SLF001 (intentional: read-only analyzer)
        cur = conn.execute(
            "SELECT ts, latency_ms, model, ok FROM brain_metrics WHERE ts >= ? ORDER BY ts",
            (lower,),
        )
        return [(float(r[0]), int(r[1]), r[2], int(r[3])) for r in cur.fetchall()]
    except Exception as e:  # noqa: BLE001
        print(f"  (brain_metrics query failed: {e})", file=sys.stderr)
        return []


# --- report ----------------------------------------------------------------

def _fmt(v, unit="s", nd=1):
    if v is None:
        return "n/a"
    return f"{v:.{nd}f}{unit}"


def build_report(parsed: ParseResult, cpu_summary: dict | None) -> str:
    invs = parsed.invocations
    lines: list[str] = []
    lines.append("=" * 70)
    lines.append("AXI WAKE-WORD LIVE-TEST REPORT")
    lines.append("=" * 70)

    if not invs:
        lines.append("")
        lines.append("no wake events in window.")
        lines.append("")
        lines.append(f"transcripts seen : {parsed.transcript_count}")
        lines.append(f"no-wake (misses) : {parsed.no_wake_count}")
        return "\n".join(lines)

    round_trips = [i.round_trip_s for i in invs if i.round_trip_s is not None]
    tts_durs = [i.tts_duration_s for i in invs if i.tts_duration_s is not None]
    brain_lat = [i.brain_latency_ms for i in invs if i.brain_latency_ms is not None]

    rt_p50, rt_p95 = _p50_p95(round_trips)
    tts_p50, tts_p95 = _p50_p95(tts_durs)
    bl_p50, bl_p95 = _p50_p95([float(x) for x in brain_lat])

    # miss rate = no-wake / total transcripts (best-effort recall proxy)
    total_transcripts = parsed.transcript_count + parsed.no_wake_count
    miss_rate = (parsed.no_wake_count / total_transcripts) if total_transcripts else None

    lines.append("")
    lines.append("--- COUNTS ---")
    lines.append(f"wake invocations    : {len(invs)}")
    lines.append(f"transcripts (total) : {parsed.transcript_count}")
    lines.append(f"no-wake / near-miss : {parsed.no_wake_count}")
    lines.append(f"answers produced    : {parsed.answer_count}")
    lines.append(f"miss rate           : {('%.0f%%' % (miss_rate*100)) if miss_rate is not None else 'n/a'}")

    lines.append("")
    lines.append("--- LATENCY (what each measures) ---")
    lines.append("round-trip = tts_done - wake_detected (full hands-free turn).")
    lines.append("  NOTE: there is no 'speech started' anchor, so wake-detect")
    lines.append("  latency itself cannot be measured precisely. Round-trip is")
    lines.append("  the honest end-to-end number the user actually feels.")
    lines.append(f"round-trip   p50/p95 : {_fmt(rt_p50)} / {_fmt(rt_p95)}")
    lines.append(f"brain latency p50/p95: {_fmt(bl_p50, 'ms', 0)} / {_fmt(bl_p95, 'ms', 0)}")
    lines.append(f"tts duration  p50/p95: {_fmt(tts_p50)} / {_fmt(tts_p95)}")

    lines.append("")
    lines.append("--- WAKE EVENTS (confirm false triggers) ---")
    lines.append("Mark any of these you did NOT intend as a false trigger.")
    lines.append("(In a SILENT run, EVERY wake below is a false positive.)")
    for i, inv in enumerate(invs, 1):
        rt = _fmt(inv.round_trip_s)
        lines.append(f"  [{i}] t={inv.wake_detected:.3f} round-trip={rt} command={inv.command}")
    lines.append(f"TOTAL WAKES (max possible false triggers) : {len(invs)}")

    # For verdict we assume false_trigger_count == total wakes only in a silent
    # run; in a real run Héctor subtracts intended ones. We compute the verdict
    # against the TOTAL as a conservative default and say so.
    cpu_idle = cpu_summary["cpu_idle"] if cpu_summary else None
    cpu_peak = cpu_summary["cpu_peak"] if cpu_summary else None

    if cpu_summary:
        lines.append("")
        lines.append("--- CPU / RAM ---")
        lines.append(f"samples       : {cpu_summary['samples']}")
        lines.append(f"CPU idle/peak : {cpu_idle:.0f}% / {cpu_peak:.0f}%")
        lines.append(f"CPU p50       : {cpu_summary['cpu_p50']:.0f}%")
        lines.append(f"RSS p50/peak  : {cpu_summary['rss_p50_mb']:.0f}MB / {cpu_summary['rss_peak_mb']:.0f}MB")

    overall, recs = compute_verdict(
        round_trip_p95=rt_p95,
        false_trigger_count=len(invs),  # conservative: treat all as needing confirmation
        miss_rate=miss_rate,
        cpu_idle=cpu_idle,
        cpu_peak=cpu_peak,
    )
    lines.append("")
    lines.append("--- VERDICT ---")
    lines.append("(false-trigger verdict assumes ALL wakes are spurious; subtract")
    lines.append(" your intended invocations and re-read the false-trigger line.)")
    lines.append(f"OVERALL: {overall}")
    for r in recs:
        lines.append(f"  - {r}")
    lines.append("=" * 70)
    return "\n".join(lines)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Axi wake-word live-test analyzer")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--since", help="journalctl --since value, e.g. '1 hour ago'")
    g.add_argument("--minutes", type=int, help="look back this many minutes")
    p.add_argument("--cpu-csv", help="path to CSV from wakeword_cpu_sample.sh")
    p.add_argument("--log-file", help="parse this file instead of journalctl (testing)")
    args = p.parse_args(argv)

    if args.log_file:
        with open(args.log_file, encoding="utf-8") as fh:
            log_lines = fh.read().splitlines()
    else:
        log_lines = read_journal(args.since, args.minutes)

    parsed = parse_log_lines(log_lines)

    # brain latency correlation: window lower bound = earliest wake (minus slack)
    if parsed.invocations:
        since_epoch = min(i.wake_detected for i in parsed.invocations) - 5.0
        brain_rows = read_brain_metrics(since_epoch)
        correlate_brain_latency(parsed.invocations, brain_rows)

    cpu_summary = summarize_cpu_csv(args.cpu_csv) if args.cpu_csv else None

    print(build_report(parsed, cpu_summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
