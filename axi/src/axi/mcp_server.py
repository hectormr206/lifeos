"""MCP server exposing LifeOS capabilities to local agents (T2).

Runs over stdio — the standard transport for local agents such as Claude Code
— so there is no network surface: an agent launches this process and talks to
it on stdin/stdout. Tools operate on the encrypted local stores via the pure
functions in ``axi.mcp_tools``.

Run:  python -m axi.mcp_server

Wire into Claude Code (~/.claude.json or project .mcp.json):
  {
    "mcpServers": {
      "lifeos": {
        "command": "/home/<you>/LifeOS/lifeos/axi/.venv/bin/python",
        "args": ["-m", "axi.mcp_server"]
      }
    }
  }
"""
from __future__ import annotations

from mcp.server.fastmcp import FastMCP

from axi import mcp_tools

mcp = FastMCP("lifeos")

# v1 surface: reads + additive writes. No destructive tools are registered.
_TOOLS = [
    mcp_tools.memory_search,
    mcp_tools.recent_conversations,
    mcp_tools.add_fact,
    mcp_tools.list_reminders,
    mcp_tools.create_reminder,
    mcp_tools.finance_summary,
    mcp_tools.log_finance_entry,
    mcp_tools.health_recent,
    mcp_tools.log_health_entry,
]

for _fn in _TOOLS:
    mcp.tool()(_fn)


def tool_names() -> list[str]:
    """Names of all registered MCP tools (used by tests and introspection)."""
    return [fn.__name__ for fn in _TOOLS]


def main() -> None:
    mcp.run()  # stdio transport by default


if __name__ == "__main__":
    main()
