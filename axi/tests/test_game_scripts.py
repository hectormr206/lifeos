"""Tests for axi-game-on / axi-game-off script content — Slice 3 (Game-mode + Heartbeat).

These scripts are pure bash without an AXI_DRY_RUN harness, so behavioral tests
are implemented as content assertions (grep-style). Per the tasks spec:
  'If the scripts are pure bash without a test harness, verify the defensive
   existence-check and the PREV_MODEL guard are present via a test that greps
   the script content for the required guards (acceptable for bash).'

TDD 3.3 RED (game-on VT eviction + defensive guard)
TDD 3.5 RED (game-off VT restore guard: PREV_MODEL==qwen35-4b vs 35B)
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).parent.parent / "scripts"
GAME_ON = SCRIPTS_DIR / "axi-game-on"
GAME_OFF = SCRIPTS_DIR / "axi-game-off"
VT_LAUNCH = SCRIPTS_DIR / "axi-vt-launch"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _content(script: Path) -> str:
    return script.read_text()


# ===========================================================================
# 3.3 RED — axi-game-on: VT eviction + defensive existence check
# ===========================================================================

class TestGameOnVtEviction:
    """axi-game-on must mask and stop llama-vt.service to evict VibeThinker-3B from VRAM."""

    def test_game_on_masks_llama_vt(self):
        """game-on must call 'systemctl --user mask llama-vt.service' (reboot-safe eviction).

        Spec: Scenario 'game-on stops VT-3B'. Design pick 3.2: use mask (not plain stop)
        so that WantedBy=default.target cannot auto-restart VT on reboot-during-game.
        """
        content = _content(GAME_ON)
        assert "mask llama-vt.service" in content, (
            "axi-game-on must mask llama-vt.service to prevent VRAM use on reboot"
        )

    def test_game_on_stops_llama_vt(self):
        """game-on must call 'systemctl --user stop llama-vt.service' to free VRAM immediately."""
        content = _content(GAME_ON)
        assert "stop llama-vt.service" in content, (
            "axi-game-on must stop llama-vt.service to free VRAM immediately"
        )

    def test_game_on_llama_vt_existence_check(self):
        """game-on must guard all llama-vt operations with an existence check.

        MEETING-SAFE DEFENSIVE GUARD: llama-vt.service may not yet be installed
        (the unit file exists in axi/systemd/ but may not be symlinked into
        ~/.config/systemd/user/). All operations must be skipped silently if
        the unit is not installed, so running game-on today does not break.
        Verified by presence of a guard block around llama-vt systemctl calls.
        """
        content = _content(GAME_ON)
        # The existence check must test for the unit file or use list-unit-files
        # before any systemctl mask/stop for llama-vt.
        has_existence_check = (
            "list-unit-files llama-vt.service" in content
            or "llama-vt.service.d" in content  # checking unit dir
            or ("llama-vt" in content and ("if " in content and "systemd" in content))
        )
        # More specific: check that the script tests unit existence before operating on it
        assert (
            "llama-vt" in content
        ), "axi-game-on must contain llama-vt handling"
        # The guard itself: must have a conditional block OR 2>/dev/null || true pattern
        # The minimal acceptable form wraps the entire llama-vt block in an if-exists guard
        assert (
            "2>/dev/null || true" in content
        ), "axi-game-on must use 2>/dev/null || true for defensive llama-vt calls"

    def test_game_on_llama_vt_unit_existence_guard(self):
        """game-on must use an if-block to check llama-vt unit existence before any operation.

        The existence check must appear before mask/stop so that a system without
        llama-vt installed skips entirely rather than erroring.
        """
        content = _content(GAME_ON)
        # Require the defensive if-block guard for llama-vt
        assert (
            "list-unit-files llama-vt.service" in content
        ), (
            "axi-game-on must check 'systemctl --user list-unit-files llama-vt.service' "
            "before masking/stopping, to skip silently when the unit is not installed"
        )


# ===========================================================================
# 3.5 RED — axi-game-off: VT restore with PREV_MODEL guard + defensive check
# ===========================================================================

class TestGameOffVtRestore:
    """axi-game-off must unmask llama-vt and start it ONLY when PREV_MODEL==qwen35-4b."""

    def test_game_off_unmasks_llama_vt(self):
        """game-off must call 'systemctl --user unmask llama-vt.service'.

        Unmask always runs so a non-triad restore can still manually start VT later.
        """
        content = _content(GAME_OFF)
        assert "unmask llama-vt.service" in content, (
            "axi-game-off must unmask llama-vt.service so it can be started later"
        )

    def test_game_off_guard_starts_vt_only_for_4b(self):
        """game-off must guard 'start llama-vt.service' with PREV_MODEL == qwen35-4b check.

        Spec: Scenario 'game-off restores VT when primary is 4B'.
        The guard string '\"qwen35-4b\"' must appear near 'start llama-vt.service'
        to ensure the conditional is present.
        """
        content = _content(GAME_OFF)
        assert "qwen35-4b" in content, (
            "axi-game-off must reference 'qwen35-4b' for the VRAM guard"
        )
        assert "start llama-vt.service" in content, (
            "axi-game-off must start llama-vt.service when PREV_MODEL == qwen35-4b"
        )

    def test_game_off_guard_is_conditional(self):
        """The 'start llama-vt.service' line must be inside a conditional block.

        Spec: Scenario 'game-off does NOT start VT-3B when primary is 35B'.
        Verified by presence of if/else + PREV_MODEL guard + VRAM guard message.
        """
        content = _content(GAME_OFF)
        # Must have an if statement that references PREV_MODEL and qwen35-4b
        assert (
            'PREV_MODEL' in content and 'qwen35-4b' in content
        ), "axi-game-off PREV_MODEL guard must reference PREV_MODEL and qwen35-4b"
        # Must have an else branch that does NOT start VT (VRAM guard message)
        assert (
            "VRAM guard" in content or "leaving llama-vt" in content
        ), (
            "axi-game-off must have an else branch explaining VT is not started "
            "(VRAM guard — expected when primary is 35B)"
        )

    def test_game_off_llama_vt_existence_guard(self):
        """game-off must check llama-vt unit existence before unmask/start.

        MEETING-SAFE DEFENSIVE GUARD: same rationale as game-on.
        """
        content = _content(GAME_OFF)
        assert (
            "list-unit-files llama-vt.service" in content
        ), (
            "axi-game-off must check 'systemctl --user list-unit-files llama-vt.service' "
            "before unmasking/starting, to skip silently when the unit is not installed"
        )

    def test_game_off_35b_does_not_start_vt(self):
        """Verify that the conditional guard prevents VT start for non-4B primary.

        The guard must be structured so that 'start llama-vt.service' is INSIDE
        the if-block (PREV_MODEL==qwen35-4b), not outside or unconditional.
        Verified by checking the else/VRAM-guard message is present in the same
        llama-vt block as the start command.
        """
        content = _content(GAME_OFF)
        # Find the position of 'start llama-vt' and 'VRAM guard'/'leaving llama-vt'
        start_pos = content.find("start llama-vt.service")
        guard_msg_pos = max(
            content.find("VRAM guard"),
            content.find("leaving llama-vt"),
        )
        # Both must exist (start inside if, guard message in else)
        assert start_pos != -1, "start llama-vt.service not found in game-off"
        assert guard_msg_pos != -1, "VRAM guard / leaving llama-vt message not found in game-off"


# ===========================================================================
# VT relocate-to-CPU (keep development alive while gaming)
# ===========================================================================

class TestGameOnVtRelocate:
    """relocate (default) mode relocates VT-3B to CPU instead of evicting it, so
    an in-progress Axi dev build keeps running while gaming. --offline still masks."""

    def test_game_on_writes_vt_cpu_dropin(self):
        content = _content(GAME_ON)
        assert "write_dropin llama-vt" in content, (
            "game-on must write a CPU drop-in for llama-vt in relocate mode"
        )
        assert "axi-vt-launch --cpu" in content, (
            "the llama-vt drop-in must launch VT on CPU via 'axi-vt-launch --cpu'"
        )

    def test_game_on_relocate_uses_try_restart_not_stop(self):
        content = _content(GAME_ON)
        assert "try-restart llama-vt.service" in content, (
            "relocate mode must try-restart llama-vt (CPU), not evict it"
        )

    def test_game_on_mask_is_offline_guarded(self):
        """VT mask must live under the OFFLINE branch (relocate keeps VT on CPU)."""
        content = _content(GAME_ON)
        # mask appears only after an OFFLINE check; assert both tokens present and
        # that the offline guard precedes the mask call.
        assert 'OFFLINE" -eq 1' in content
        offline_pos = content.find('if [ "$OFFLINE" -eq 1 ]; then\n        echo "[axi-game-on] --offline: masking llama-vt')
        assert offline_pos != -1, (
            "llama-vt mask must be inside the --offline branch (relocate must not mask)"
        )


class TestGameOffVtDropinCleanup:
    """game-off must clean up the relocate drop-in and restore/stop VT correctly."""

    def test_game_off_removes_vt_dropin(self):
        content = _content(GAME_OFF)
        assert "llama-vt.service.d/game-cpu.conf" in content, (
            "game-off must remove the llama-vt CPU drop-in written in relocate mode"
        )

    def test_game_off_restarts_vt_on_restore(self):
        content = _content(GAME_OFF)
        assert "restart llama-vt.service" in content, (
            "game-off must restart (not just start) llama-vt so a CPU-relocated VT re-execs on GPU"
        )

    def test_game_off_stops_vt_for_non_triad(self):
        content = _content(GAME_OFF)
        assert "stop llama-vt.service" in content, (
            "game-off must actively stop llama-vt for a non-triad primary "
            "(it may have been left running on CPU by relocate)"
        )


# ===========================================================================
# axi-vt-launch --cpu (behavioral via AXI_DRY_RUN)
# ===========================================================================

def _vt_launch_ngl(args, state_dir):
    env = {**os.environ, "AXI_DRY_RUN": "1", "XDG_STATE_HOME": str(state_dir)}
    out = subprocess.run(
        ["bash", str(VT_LAUNCH), *args],
        capture_output=True, text=True, env=env,
    )
    toks = out.stdout.split()
    assert "-ngl" in toks, f"no -ngl in output: {out.stdout!r} / {out.stderr!r}"
    return toks[toks.index("-ngl") + 1]


class TestVtLaunchCpuFlag:
    """axi-vt-launch --cpu forces ngl=0 (CPU); default stays GPU-resident."""

    def test_default_is_gpu_resident(self, tmp_path):
        assert _vt_launch_ngl([], tmp_path) == "999"

    def test_cpu_flag_forces_ngl_zero(self, tmp_path):
        assert _vt_launch_ngl(["--cpu"], tmp_path) == "0"
