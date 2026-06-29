"""Conversational memory backed by the SQLite knowledge store.

Same public API as the JSONL V0 (`add`, `messages`, `clear`, `turn_count`)
but every turn is now (a) a row in the `conversations` table and (b) a
node of kind `conversation` in the graph. The graph node is what we later
hang facts off of — when Axi extracts "Héctor mentioned wanting a Mazda"
from a turn, that fact-node gets an edge `mentioned_in` to the conversation
node, preserving the source.

The sliding window of last N turns is now a SELECT … LIMIT, so the
in-memory deque is gone — everything is queryable from disk.

Every fact surfaced to the LLM carries its timestamp in the user's
timezone so the model can reason about supersession ("usé HyperX el
12 de mayo, pero el 14 dijiste Huawei → Huawei es lo actual"). The
original timezone is annotated ONLY when it differs from the current
one, so users who never travel never see clutter.
"""
from __future__ import annotations

import logging
from datetime import datetime
from zoneinfo import ZoneInfo

from axi import config, store
from axi.output import notify
from axi.store import RecoveryError

log = logging.getLogger("axi.memory")

MAX_CONTEXT_TURNS = 20  # how many recent turns feed the LLM each ask

_CORRUPTION_INDICATORS = (
    "disk image is malformed",
    "disk i/o error",
    "hmac check failed",
)


def _is_corruption_error(exc: BaseException) -> bool:
    """Return True when *exc* looks like a SQLCipher page-level corruption."""
    msg = str(exc).lower()
    return any(indicator in msg for indicator in _CORRUPTION_INDICATORS)


def _format_ts(unix_ts: float, created_tz: str | None = None) -> str:
    """Render a Unix timestamp in the user's *current* TZ. Append
    '(originalmente en <tz>)' only when the creation TZ differs."""
    current_tz = config.get("timezone", "America/Mexico_City")
    try:
        d = datetime.fromtimestamp(unix_ts, tz=ZoneInfo(current_tz))
    except Exception:  # noqa: BLE001
        d = datetime.fromtimestamp(unix_ts, tz=ZoneInfo("America/Mexico_City"))
        current_tz = "America/Mexico_City"
    base = d.strftime("%Y-%m-%d %H:%M")
    if created_tz and created_tz != current_tz:
        return f"{base} (originalmente en {created_tz})"
    return base


class ConversationMemory:
    """Thin facade — the real state lives in SQLite.

    All public methods are wrapped with graceful degradation: a corrupt or
    unavailable database never propagates an exception out of this class.
    When degraded, messages() returns [], add() is a no-op, turn_count()
    returns 0. The ``degraded`` flag is set when init_db() fails.
    """

    def __init__(self, max_context_turns: int = MAX_CONTEXT_TURNS) -> None:
        self.max_context_turns = max_context_turns
        self.degraded = False
        # Guards against infinite recovery loops: at most one self-heal attempt
        # per ConversationMemory instance lifetime.
        self._self_healed: bool = False
        try:
            store.init_db()
            log.info("memory backend: %s (%d turns)", store.DB_PATH, store.conversation_count())
        except RecoveryError as exc:
            log.critical(
                "RECOVERY REQUIRED — recoverable data exists but restore failed; "
                "refusing to run with empty memory. Manual recovery needed. "
                "Files: ~/.local/state/axi/memory.db, "
                ".corrupt-*.bak backups in that directory, ~/lifeos-backups. "
                "Error: %s",
                exc,
            )
            try:
                notify(
                    "Axi — Recovery Required",
                    "Recoverable data exists but restore failed. "
                    "Check ~/.local/state/axi/ and ~/lifeos-backups. Manual recovery needed.",
                    icon="dialog-error",
                )
            except Exception:  # noqa: BLE001
                pass
            raise
        except Exception as exc:  # noqa: BLE001
            if _is_corruption_error(exc) and not self._self_healed:
                self._self_healed = True
                log.warning("memory: corruption on init — attempting self-heal: %s", exc)
                try:
                    if store.attempt_self_heal():
                        store.init_db()
                        log.warning("memory: self-heal succeeded — DB reinited")
                        return
                except Exception as reinit_exc:  # noqa: BLE001
                    log.warning("memory: self-heal retry failed: %s", reinit_exc)
            self.degraded = True
            log.warning("memory degraded: %s — running with empty history", exc)

    def _notify_recovery(self) -> None:
        """Best-effort desktop notification that manual recovery may be needed."""
        try:
            notify(
                "Axi — Recovery Required",
                "Store error: recoverable data at risk. Check ~/.local/state/axi/.",
                icon="dialog-error",
            )
        except Exception:  # noqa: BLE001
            pass

    def _with_recovery(self, op_name, fn, default):
        """Run *fn*; on a SQLCipher corruption/latch error, recover and RETRY so
        the operation actually completes instead of being silently dropped.

        Two rungs, cheapest first:

        1. ``store.reset_connection()`` — the common case. The on-disk file is
           healthy but the live connection latched into a "deferred error
           condition" (a transient decrypt/hmac race between the dashboard,
           daemon and heartbeat). A fresh connection clears it; we re-run *fn*
           so e.g. an INSERT lands. Cheap and repeatable.
        2. ``store.attempt_self_heal()`` — the heavy recovery ladder for genuine
           file corruption, gated once per instance to avoid loops.

        Only when both rungs fail to make *fn* succeed do we mark the memory
        degraded and return *default*.
        """
        try:
            return fn()
        except RecoveryError as exc:
            log.critical(
                "RECOVERY REQUIRED in %s — store raised RecoveryError; "
                "operation not completed. Manual recovery needed. Error: %s",
                op_name, exc,
            )
            self._notify_recovery()
            return default
        except Exception as exc:  # noqa: BLE001
            if not _is_corruption_error(exc):
                log.warning("memory degraded in %s: %s", op_name, exc)
                return default
            # Rung 1 — cheap connection reset + retry (healthy file, latched conn).
            log.warning("memory: corruption in %s (%s) — resetting connection", op_name, exc)
            try:
                did_reset = store.reset_connection()
            except Exception:  # noqa: BLE001
                did_reset = False
            if did_reset:
                try:
                    return fn()
                except Exception as e2:  # noqa: BLE001
                    log.warning("memory: %s retry after reset failed: %s", op_name, e2)
            # Rung 2 — heavy recovery ladder, once per instance.
            if not getattr(self, "_self_healed", False):
                self._self_healed = True
                try:
                    if store.attempt_self_heal():
                        try:
                            return fn()
                        except Exception as e3:  # noqa: BLE001
                            log.warning("memory: %s retry after self-heal failed: %s", op_name, e3)
                except Exception as heal_exc:  # noqa: BLE001
                    log.warning("memory: self-heal raised in %s: %s", op_name, heal_exc)
            self.degraded = True
            log.warning("memory degraded in %s: %s — operation did not complete", op_name, exc)
            return default

    def _add_once(self, user, axi, has_screenshot, session_id, source="chat"):
        """The raw insert (+ optional graph bridge). Wrapped by _with_recovery."""
        conv_id = store.add_conversation(
            user, axi, has_screenshot=has_screenshot, session_id=session_id, source=source
        )
        node_id = None
        if config.get("graph_bridge_conversations", False):
            node_id = store.add_node(
                kind="conversation",
                label=user[:80],
                data={"user": user, "axi": axi},
            )
            # Bridge: link the conversation row to its graph node for future
            # fact-extraction passes.
            with store._tx() as c:  # noqa: SLF001 — internal helper, intentional
                c.execute("UPDATE conversations SET node_id = ? WHERE id = ?", (node_id, conv_id))
        return conv_id, node_id

    def add(self, user: str, axi: str, has_screenshot: bool = False,
            session_id: str | None = None, source: str = "chat") -> tuple[int, int]:
        """Record a turn. Returns (conversation row id, conversation node id).

        `session_id` scopes the turn to a domain chat (e.g. "health" for the
        Salud chat) so each specialized chat can show only its own history.

        A latched connection no longer silently drops the turn: on a corruption
        error the connection is reset and the insert is retried, so the turn
        persists. Returns (0, 0) only when recovery fails entirely.
        """
        return self._with_recovery(
            "add", lambda: self._add_once(user, axi, has_screenshot, session_id, source), (0, 0)
        )

    def _messages_once(self) -> list[dict]:
        """The raw history read. Wrapped by _with_recovery."""
        rows = store.recent_conversations(self.max_context_turns)
        out: list[dict] = []
        for r in rows:
            out.append({"role": "user", "content": r["user_text"]})
            out.append({"role": "assistant", "content": r["axi_text"]})
        return out

    def messages(self) -> list[dict]:
        """OpenAI chat-completion format, oldest first.

        Returns [] without raising when the store is corrupt or unavailable.
        """
        return self._with_recovery("messages", self._messages_once, [])

    def clear(self) -> int:
        n = store.clear_conversations()
        log.info("cleared %d conversation rows (graph nodes preserved)", n)
        return n

    def turn_count(self) -> int:
        """Return the number of stored conversation turns.

        Returns 0 without raising when the store is unavailable.
        """
        return self._with_recovery("turn_count", store.conversation_count, 0)

    def relevant_facts(self, query: str, limit: int = 5) -> list[str]:
        """FTS search over fact nodes. Returns lines pre-formatted with the
        creation timestamp in the user's TZ, so the LLM can prefer newer
        facts when there is conflict (e.g. HyperX → Huawei superseding)."""
        if not query.strip():
            return []
        sanitized = " ".join(w for w in query.replace("¿", "").replace("?", "").split() if len(w) > 2)
        if not sanitized:
            return []
        try:
            rows = store.search_nodes_fts(sanitized, limit=limit * 4)
        except Exception:  # noqa: BLE001 — FTS can choke on weird tokens
            return []
        facts = [r for r in rows if r["kind"] == "fact"]
        facts.sort(key=lambda r: r["created_at"], reverse=True)
        out: list[str] = []
        for r in facts[:limit]:
            created_tz = r["created_tz"] if "created_tz" in r.keys() else None
            ts = _format_ts(r["created_at"], created_tz)
            tag = f"[{r['domain']}] " if r["domain"] else ""
            out.append(f"[{ts}] {tag}{r['label']}")
        return out
