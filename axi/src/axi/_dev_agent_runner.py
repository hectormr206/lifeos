"""
Axi dev-agent subprocess runner.

This script is invoked INSIDE a bubblewrap sandbox by dev_agent.py.
It reads task parameters from an input JSON file, calls the Claude Agent SDK
query() in asyncio, applies the PreToolUse safety hook, and writes results to
an output JSON file.

It must be self-contained enough to run inside the bwrap jail, where:
- The axi source tree (src/) is bind-mounted read-only.
- The venv is bind-mounted read-only.
- The worktree is writable.
- /home is NOT available.
- The only env var set is ANTHROPIC_API_KEY (and PATH/HOME/PYTHONPATH).

Usage:
    python _dev_agent_runner.py <input_json_path> <output_json_path>

Input JSON schema:
    {
        "task": str,
        "worktree_path": str,
        "max_budget_usd": float,
        "max_turns": int,
        "model": str | null,
        "anthropic_api_key": str
    }

Output JSON schema:
    {
        "summary": str,
        "cost_usd": float,
        "num_turns": int,
        "is_error": bool,
        "errors": list[str],
        "tool_calls": list[{"tool": str, "input_summary": str}],
        "blocked_tool_attempts": list[str]
    }

Exit codes:
    0 — completed successfully (SDK ran; is_error may still be true inside)
    1 — runner-level failure (SDK import error, JSON I/O error, uncaught exception)
"""
from __future__ import annotations

import asyncio
import json
import re
import sys

# Safety constants — duplicated here so this file works standalone inside bwrap
# without needing to import from dev_agent (though the axi package IS available).
_BLOCKLIST_RE = re.compile(
    r"git\s+(push|reset\s+--hard|clean\s+-f)|\brm\s+|\bgit\s+commit\b|\bcurl\b|\bwget\b|\.(env|credentials|secrets)\b",
    re.IGNORECASE,
)
_BLOCKED_TOOLS = {"WebSearch", "WebFetch"}


def _is_dangerous(tool_name: str, tool_input: dict) -> bool:
    """Return True if this tool call should be blocked by the safety gate."""
    if tool_name in _BLOCKED_TOOLS:
        return True
    if tool_name == "Bash":
        command = ""
        if isinstance(tool_input, dict):
            command = tool_input.get("command", "") or tool_input.get("cmd", "")
        if _BLOCKLIST_RE.search(str(command)):
            return True
    return False


def _make_pre_tool_use_hook(blocked_tool_attempts: list[str]):
    """
    Return a PreToolUse hook function that uses the correct hookSpecificOutput
    shape required by the Claude Agent SDK (C5 fix).

    The hook denies dangerous tool calls and records them in blocked_tool_attempts.
    Safe calls return an allow decision.
    """

    async def _hook(hook_input, session_id, ctx):
        if isinstance(hook_input, dict):
            tool_name = hook_input.get("tool_name", "")
            tool_inp = hook_input.get("tool_input", {})
        else:
            tool_name = getattr(hook_input, "tool_name", "")
            tool_inp = getattr(hook_input, "tool_input", {})

        if _is_dangerous(tool_name, tool_inp):
            reason = f"blocked by dev_agent safety gate: {tool_name}"
            blocked_tool_attempts.append(reason)
            return {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        return {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
            }
        }

    return _hook


async def _run_agent(inp: dict) -> dict:
    """Run the Claude Agent SDK query with the given input parameters."""
    import claude_agent_sdk as sdk  # noqa: PLC0415

    task = inp["task"]
    worktree_path = inp["worktree_path"]
    max_budget_usd = inp.get("max_budget_usd", 0.50)
    max_turns = inp.get("max_turns", 8)
    model = inp.get("model") or None
    anthropic_api_key = inp.get("anthropic_api_key", "")

    blocked_tool_attempts: list[str] = []
    pre_tool_use_hook = _make_pre_tool_use_hook(blocked_tool_attempts)

    options = sdk.ClaudeAgentOptions(
        cwd=worktree_path,
        allowed_tools=["Read", "Edit", "Write", "Bash"],
        disallowed_tools=["WebSearch", "WebFetch"],
        permission_mode="dontAsk",
        max_turns=max_turns,
        max_budget_usd=max_budget_usd,
        model=model,
        env={"ANTHROPIC_API_KEY": anthropic_api_key},
        setting_sources=[],
        hooks={
            "PreToolUse": [
                sdk.HookMatcher(
                    matcher=None,
                    hooks=[pre_tool_use_hook],
                    timeout=None,
                )
            ]
        },
    )

    tool_calls: list[dict] = []
    summary = ""
    cost_usd = 0.0
    num_turns = 0
    is_error = False
    errors: list[str] = []

    async for message in sdk.query(prompt=task, options=options):
        if isinstance(message, sdk.AssistantMessage):
            for block in message.content:
                if isinstance(block, sdk.ToolUseBlock):
                    tool_calls.append(
                        {
                            "tool": block.name,
                            "input_summary": str(block.input)[:200],
                        }
                    )
        elif isinstance(message, sdk.ResultMessage):
            summary = message.result or ""
            cost_usd = message.total_cost_usd or 0.0
            num_turns = message.num_turns
            is_error = message.is_error
            if message.errors:
                errors.extend(message.errors)

    return {
        "summary": summary,
        "cost_usd": cost_usd,
        "num_turns": num_turns,
        "is_error": is_error,
        "errors": errors,
        "tool_calls": tool_calls,
        "blocked_tool_attempts": blocked_tool_attempts,
    }


def main() -> int:
    if len(sys.argv) != 3:
        print(
            f"Usage: {sys.argv[0]} <input_json_path> <output_json_path>",
            file=sys.stderr,
        )
        return 1

    input_path = sys.argv[1]
    output_path = sys.argv[2]

    try:
        with open(input_path) as f:
            inp = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"Failed to read input JSON: {e}", file=sys.stderr)
        return 1

    try:
        result = asyncio.run(_run_agent(inp))
    except ImportError as e:
        print(f"SDK import error: {e}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"Agent runner error: {e}", file=sys.stderr)
        return 1

    try:
        with open(output_path, "w") as f:
            json.dump(result, f)
    except OSError as e:
        print(f"Failed to write output JSON: {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
