# MCP Server — Security Model

LifeOS exposes a set of `lifeos_*` tools to MCP clients (Claude Desktop, VS Code Copilot, in-process Axi router, Dashboard chat). This document captures which tools are gated, why, and how to opt in.

## Threat model

Vectors that can reach the MCP dispatcher:

- **SimpleX inbound** — a contact crafts a message that nudges the LLM into calling a sensitive tool.
- **Dashboard chat** — same surface, browser-side.
- **Compromised MCP client** — a third-party MCP client (extension supply chain) sends raw tool calls.

Tools that read or modify state outside the daemon's own data must therefore default OFF and require an explicit operator opt-in. Defaults are conservative, gates are documented in error messages, and every gated invocation logs at `warn!` level.

## Gates

| Tool(s) | Env var (set to `1`/`true`/`yes`/`on`) | Why it's gated |
|---|---|---|
| `lifeos_shell` | `LIFEOS_MCP_SHELL_ENABLE` | Pipes a string from the MCP caller into `sh -c`. A blocklist cannot make this safe; opting in accepts the risk. |
| `lifeos_clipboard_get`, `lifeos_clipboard_set` | `LIFEOS_MCP_CLIPBOARD_ENABLE` | Clipboard frequently holds passwords, 2FA codes, session tokens. Writing it lets a caller plant commands the user later pastes into a terminal. |
| `lifeos_a11y_tree`, `lifeos_a11y_find`, `lifeos_a11y_activate`, `lifeos_a11y_get_text`, `lifeos_a11y_set_text` | `LIFEOS_MCP_A11Y_ENABLE` | AT-SPI exposes the live text and actionable controls of every accessible app on the desktop — browser, email, password manager, terminal. Reading is exfiltration; activating/setting can submit forms with attacker text. |

`lifeos_a11y_apps` (listing applications) is intentionally **not** gated — it returns a list comparable to `ps`, which is already broadly visible.

## Validation

- `lifeos_apps_launch` requires the `app` argument to match `[A-Za-z0-9._-]{1,64}`. Path separators, shell metacharacters, whitespace, embedded newlines, and non-ASCII are rejected. `tokio::Command::new` uses `execvp`, so the only way to constrain *which* binary the caller can launch is to constrain the shape of the name.
- `lifeos_workspaces_*` and `lifeos_display_resolution` keep their existing per-arg metacharacter checks — they invoke `swaymsg`/`cosmic-randr` via `execvp` (no shell), but the upstream tools have their own command grammar that we don't want callers smuggling into.

## Output caps

`lifeos_browser_extract_text` and `lifeos_a11y_get_text` truncate their `text` field at **64 KiB** on a UTF-8 boundary. Truncation is signalled by `"truncated": true`; the original `length` is reported in bytes. This is a defence against accidental memory bombs (a 100 MB page) and against using these tools to relay full-document exfiltration in a single response.

## What changed (vs. previous behaviour)

- Previously: `lifeos_clipboard_*` and all five `lifeos_a11y_*` tools (except `apps`) were callable without gating.
- Previously: `lifeos_apps_launch` only blocked `;`, `&`, `|`, and `/` — leaving `$()`, backticks, newlines, IFS tricks, and Unicode lookalikes wide open.
- Previously: `lifeos_apps_list_installed` and `lifeos_brightness_*` paths shelled out via `sh -c` with static command strings (safe today, but a footgun for any future refactor that splices user input). `lifeos_apps_list_installed` now walks the XDG dirs in pure Rust.
- Previously: `lifeos_browser_extract_text` returned the full extracted text with no length cap.

## Opting in

To enable a gated tool for the running daemon, set the env var in the systemd drop-in for the user-session unit and reload:

```
mkdir -p ~/.config/systemd/user/lifeosd.service.d
printf '[Service]\nEnvironment=LIFEOS_MCP_CLIPBOARD_ENABLE=1\n' \
  > ~/.config/systemd/user/lifeosd.service.d/50-mcp-gates.conf
systemctl --user daemon-reload
systemctl --user restart lifeosd
```

Each enabled gate appears in `journalctl --user -u lifeosd` on every invocation as `[mcp_server] <tool> EXEC (opt-in)`. If you no longer want a tool exposed, remove the line and restart.
