"""Tests for the wake-word live-test analyzer (scripts/wakeword_report.py).

The analyzer's parser is a PURE function over an iterable of log lines, so these
tests need no journald, no live services, and no real DB — they feed synthetic
`wakeword-metric:` lines and a synthetic brain_metrics fixture and assert the
computed metrics, percentiles, false-trigger count, and verdict at boundaries.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

_MODULE_PATH = Path(__file__).parent.parent / "scripts" / "wakeword_report.py"


def _load_module():
    import sys

    spec = importlib.util.spec_from_file_location("wakeword_report", _MODULE_PATH)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    # Register before exec so @dataclass can resolve cls.__module__ in __dict__.
    sys.modules["wakeword_report"] = mod
    spec.loader.exec_module(mod)
    return mod


wr = _load_module()


# --- synthetic log builder -------------------------------------------------

def _invocation_lines(*, wake_t, command, ask_t=None, tts_start_t=None, tts_done_t=None,
                      transcript="hola axi", answer="respuesta"):
    """Emit the journal lines for one full wake invocation, in order."""
    lines = [f"wakeword: transcript={transcript!r}"]
    lines.append(f"wakeword: WAKE DETECTED — command={command!r}")
    lines.append(f"wakeword-metric: wake_detected t={wake_t:.3f} command={command!r}")
    if ask_t is not None:
        lines.append(f"wakeword-metric: ask_start t={ask_t:.3f}")
    if answer is not None:
        lines.append(f"wakeword answer: {answer}")
    if tts_start_t is not None:
        lines.append(f"wakeword-metric: tts_start t={tts_start_t:.3f}")
    if tts_done_t is not None:
        lines.append(f"wakeword-metric: tts_done t={tts_done_t:.3f}")
    return lines


# ===========================================================================
# Parser
# ===========================================================================

class TestParser:
    def test_single_invocation_round_trip(self):
        lines = _invocation_lines(
            wake_t=1000.0, command="que hago aca",
            ask_t=1000.5, tts_start_t=1003.0, tts_done_t=1005.0,
        )
        r = wr.parse_log_lines(lines)
        assert len(r.invocations) == 1
        inv = r.invocations[0]
        assert inv.command == "'que hago aca'"
        assert inv.round_trip_s == pytest.approx(5.0)
        assert inv.tts_duration_s == pytest.approx(2.0)
        assert r.answer_count == 1

    def test_multiple_invocations_isolated(self):
        lines = []
        lines += _invocation_lines(wake_t=10, command="a", ask_t=10.2,
                                   tts_start_t=12, tts_done_t=14)
        lines += _invocation_lines(wake_t=100, command="b", ask_t=100.5,
                                   tts_start_t=103, tts_done_t=110)
        r = wr.parse_log_lines(lines)
        assert len(r.invocations) == 2
        assert r.invocations[0].round_trip_s == pytest.approx(4.0)
        assert r.invocations[1].round_trip_s == pytest.approx(10.0)

    def test_no_wake_and_transcript_counts(self):
        lines = [
            "wakeword: transcript='hola'",
            "wakeword: no wake match for transcript 'hola'",
            "wakeword: transcript='axi ayudame'",
            "wakeword: WAKE DETECTED — command='ayudame'",
            "wakeword-metric: wake_detected t=5.000 command='ayudame'",
        ]
        r = wr.parse_log_lines(lines)
        assert r.no_wake_count == 1
        # both transcript= lines counted
        assert r.transcript_count == 2
        assert len(r.invocations) == 1

    def test_incomplete_invocation_round_trip_none(self):
        # wake but TTS never completed (e.g. crash) -> round_trip None
        lines = _invocation_lines(wake_t=1.0, command="x", ask_t=1.1,
                                  tts_start_t=None, tts_done_t=None)
        r = wr.parse_log_lines(lines)
        assert r.invocations[0].round_trip_s is None

    def test_journald_prefix_tolerated(self):
        # lines with a leading timestamp prefix must still match on substrings
        lines = [
            "Jun 22 10:00:00 host axi[1]: wakeword: WAKE DETECTED — command='hi'",
            "Jun 22 10:00:00 host axi[1]: wakeword-metric: wake_detected t=1.000 command='hi'",
            "Jun 22 10:00:05 host axi[1]: wakeword-metric: tts_done t=6.000",
        ]
        r = wr.parse_log_lines(lines)
        assert len(r.invocations) == 1
        assert r.invocations[0].round_trip_s == pytest.approx(5.0)


# ===========================================================================
# Percentiles / stats
# ===========================================================================

class TestPercentiles:
    def test_percentile_single_value(self):
        assert wr._percentile([42.0], 50) == 42.0
        assert wr._percentile([42.0], 95) == 42.0

    def test_percentile_empty_none(self):
        assert wr._percentile([], 50) is None

    def test_p50_p95(self):
        vals = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
        p50, p95 = wr._p50_p95(vals)
        # nearest-rank: idx round(0.50*9)=4 -> 5.0 ; idx round(0.95*9)=9 -> 10.0
        assert p50 == pytest.approx(5.0)
        assert p95 == pytest.approx(10.0)


# ===========================================================================
# Brain latency correlation
# ===========================================================================

class TestCorrelate:
    def test_nearest_following_brain_row(self):
        invs = wr.parse_log_lines(
            _invocation_lines(wake_t=1000, command="a", ask_t=1000.5,
                              tts_start_t=1003, tts_done_t=1005)
            + _invocation_lines(wake_t=2000, command="b", ask_t=2000.5,
                                tts_start_t=2003, tts_done_t=2005)
        ).invocations
        # brain rows: one in window of inv0, one in window of inv1
        rows = [
            (1001.0, 480, "qwen", 1),
            (2001.0, 920, "qwen", 1),
        ]
        wr.correlate_brain_latency(invs, rows)
        assert invs[0].brain_latency_ms == 480
        assert invs[1].brain_latency_ms == 920

    def test_failed_brain_row_skipped(self):
        invs = wr.parse_log_lines(
            _invocation_lines(wake_t=1000, command="a", ask_t=1000.5,
                              tts_done_t=1005)
        ).invocations
        rows = [(1001.0, 9999, "qwen", 0)]  # ok=0 -> skip
        wr.correlate_brain_latency(invs, rows)
        assert invs[0].brain_latency_ms is None


# ===========================================================================
# Verdict thresholds (boundary values)
# ===========================================================================

class TestVerdict:
    def test_all_green(self):
        overall, recs = wr.compute_verdict(
            round_trip_p95=10.0, false_trigger_count=0,
            miss_rate=0.05, cpu_idle=10.0, cpu_peak=90.0,
        )
        assert overall == "GREEN"
        assert any("slice-2" in r for r in recs)

    def test_false_trigger_boundary_green(self):
        # exactly at the max is still green
        overall, _ = wr.compute_verdict(
            round_trip_p95=5.0, false_trigger_count=wr.FALSE_TRIGGER_GREEN_MAX,
            miss_rate=0.0, cpu_idle=5.0, cpu_peak=50.0,
        )
        assert overall == "GREEN"

    def test_false_trigger_over_recommends_openwakeword(self):
        overall, recs = wr.compute_verdict(
            round_trip_p95=5.0, false_trigger_count=wr.FALSE_TRIGGER_GREEN_MAX + 1,
            miss_rate=0.0, cpu_idle=5.0, cpu_peak=50.0,
        )
        assert overall == "ACTION-NEEDED"
        assert any("openWakeWord" in r for r in recs)

    def test_slow_round_trip_recommends_small_brain(self):
        overall, recs = wr.compute_verdict(
            round_trip_p95=wr.ROUND_TRIP_SMALL_BRAIN_S + 0.1, false_trigger_count=0,
            miss_rate=0.0, cpu_idle=5.0, cpu_peak=50.0,
        )
        assert overall == "ACTION-NEEDED"
        assert any("game-brain" in r for r in recs)

    def test_high_miss_rate_recommends_openwakeword(self):
        overall, recs = wr.compute_verdict(
            round_trip_p95=5.0, false_trigger_count=0,
            miss_rate=wr.MISS_RATE_GREEN_MAX + 0.01, cpu_idle=5.0, cpu_peak=50.0,
        )
        assert overall == "ACTION-NEEDED"
        assert any("openWakeWord" in r for r in recs)

    def test_high_cpu_flagged(self):
        overall, recs = wr.compute_verdict(
            round_trip_p95=5.0, false_trigger_count=0,
            miss_rate=0.0, cpu_idle=wr.CPU_IDLE_GREEN_MAX + 1, cpu_peak=999.0,
        )
        assert overall == "ACTION-NEEDED"
        assert any("CPU" in r or "cpu" in r for r in recs)


# ===========================================================================
# CPU CSV summary
# ===========================================================================

class TestCpuCsv:
    def test_summarize(self, tmp_path):
        csv = tmp_path / "cpu.csv"
        csv.write_text(
            "epoch,cpu_pct,rss_mb\n"
            "1000,5.0,400\n"
            "1002,50.0,420\n"
            "1004,12.0,410\n"
        )
        s = wr.summarize_cpu_csv(str(csv))
        assert s["samples"] == 3
        assert s["cpu_idle"] == 5.0
        assert s["cpu_peak"] == 50.0
        assert s["rss_peak_mb"] == 420.0

    def test_missing_file_returns_none(self, tmp_path):
        assert wr.summarize_cpu_csv(str(tmp_path / "nope.csv")) is None


# ===========================================================================
# Report rendering (smoke / empty handling)
# ===========================================================================

class TestReport:
    def test_empty_window_message(self):
        r = wr.parse_log_lines([])
        out = wr.build_report(r, None)
        assert "no wake events in window" in out

    def test_report_lists_each_wake_for_false_trigger_confirmation(self):
        lines = (
            _invocation_lines(wake_t=10, command="a", ask_t=10.2, tts_done_t=14)
            + _invocation_lines(wake_t=20, command="b", ask_t=20.2, tts_done_t=25)
        )
        r = wr.parse_log_lines(lines)
        out = wr.build_report(r, None)
        assert "TOTAL WAKES (max possible false triggers) : 2" in out
        assert "[1]" in out and "[2]" in out
        assert "VERDICT" in out
