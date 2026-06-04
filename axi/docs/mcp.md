# LifeOS MCP server

`axi.mcp_server` exposes LifeOS capabilities to local AI agents (Claude Code,
and any other [Model Context Protocol](https://modelcontextprotocol.io) client)
over **stdio**. The agent launches the server as a subprocess and talks to it on
stdin/stdout — there is no network listener and no new attack surface. Tools read
and write the encrypted local stores directly through the existing domain APIs.

## Run

```bash
~/LifeOS/lifeos/axi/.venv/bin/python -m axi.mcp_server
```

You normally don't run it by hand — the MCP client spawns it (see below).

## Wire into Claude Code

Add to `~/.claude.json` (global) or a project `.mcp.json`:

```json
{
  "mcpServers": {
    "lifeos": {
      "command": "/home/<you>/LifeOS/lifeos/axi/.venv/bin/python",
      "args": ["-m", "axi.mcp_server"]
    }
  }
}
```

Then in Claude Code the tools appear as `mcp__lifeos__*`.

## Tools (v1)

Reads:

| Tool | Purpose |
|------|---------|
| `memory_search(query, limit=10)` | Full-text search the knowledge graph |
| `recent_conversations(limit=20)` | Recent chat turns, oldest first |
| `list_reminders(status="pending")` | Pending (or recent) reminders |
| `finance_summary(days=30)` | Finance totals by kind |
| `health_recent(days=30, limit=50)` | Recent health entries |

Writes (additive only — no delete/clear/config):

| Tool | Purpose |
|------|---------|
| `add_fact(label, data=None, domain=None)` | Store a fact in long-term memory |
| `create_reminder(message, when_iso=None)` | Create a reminder (ISO time; now if omitted) |
| `log_finance_entry(kind, title, amount, when_iso=None, currency="MXN")` | Record a finance entry |
| `log_health_entry(kind, title, when_iso=None, body=None)` | Record a health entry |

`kind` for finance is one of `expense, income, savings, debt_payment,
big_purchase, note`; for health, `symptom, medication, vital, condition, note`.

## Security model

- **stdio only** — no socket, no port, no remote access.
- **Additive writes only** — a buggy or adversarial agent cannot delete or
  overwrite your data through this surface in v1.
- Same trust boundary as the user: the tools can do what the user's own agent can
  do, against the user's own encrypted stores. See [threat-model.md](threat-model.md).

## Roadmap (v1.1+)

- Read tools for cross-domain `insights`/correlations and the `daily_digest`.
- Relationships, exercise, learning, and meeting-search tools.
- Optional per-tool consent prompts for writes.
