"""Build eval corpus from real Axi data in memory.db.

The produced files are PERSONAL data and are gitignored. The repo instead ships a
committed SYNTHETIC (fictional) sample corpus — eval_docs.sample.jsonl /
eval_corpus.sample.jsonl — which eval_embedders.py falls back to automatically
when these real files are absent (e.g. a fresh public clone). Run this script
locally to regenerate the real corpus from your own memory.db.

Produces:
  eval_corpus.jsonl  — (query_id, query, relevant_id) pairs
  eval_docs.jsonl    — (id, text, source) documents

Auto-annotation strategies:
  A — keyword/paraphrase: derive a short query from the first sentence/key terms
  B — conversational follow-up: msg[i+1] as query → msg[i] as relevant
  C — Q&A: if msg contains "?", use the question as query → its Axi response as relevant
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

import sqlcipher3

STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "axi"
DB_PATH = STATE_DIR / "memory.db"
EVAL_DIR = Path(__file__).parent

# ── helpers ──────────────────────────────────────────────────────────────────

def open_db() -> sqlcipher3.Connection:
    key = (STATE_DIR / "memory.key").read_text().strip()
    c = sqlcipher3.connect(str(DB_PATH), check_same_thread=False, isolation_level=None)
    c.execute(f"PRAGMA key = \"x'{key}'\"")
    c.row_factory = sqlcipher3.Row
    return c


def first_sentence(text: str) -> str:
    """Extract first sentence or first 120 chars."""
    text = text.strip()
    for sep in (".", "!", "?", "\n"):
        idx = text.find(sep)
        if idx > 20:
            return text[: idx + 1].strip()
    return text[:120].strip()


def extract_question(text: str) -> str | None:
    """Return the first sentence ending in '?' if found."""
    sentences = re.split(r"(?<=[.!?])\s+", text)
    for s in sentences:
        if "?" in s and len(s) > 10:
            return s.strip()
    return None


def keyword_query(text: str, n: int = 8) -> str:
    """Build a short keyword query from the most content-rich words."""
    words = re.findall(r"[a-záéíóúüñA-ZÁÉÍÓÚÜÑ]{4,}", text)
    # Deduplicate preserving order
    seen: set[str] = set()
    result = []
    for w in words:
        wl = w.lower()
        if wl not in seen:
            seen.add(wl)
            result.append(w)
    return " ".join(result[:n])


# ── load data ─────────────────────────────────────────────────────────────────

def load_data(c: sqlcipher3.Connection):
    convs = c.execute(
        "SELECT id, user_text, axi_text, session_id FROM conversations ORDER BY ts ASC"
    ).fetchall()

    segs = c.execute(
        "SELECT id, text, meeting_id FROM meeting_segments "
        "WHERE text IS NOT NULL AND LENGTH(TRIM(text)) > 30 ORDER BY id ASC"
    ).fetchall()

    return convs, segs


# ── strategy A: keyword paraphrase ────────────────────────────────────────────

def strategy_a_conversations(convs, docs: list[dict], pairs: list[dict], prefix="ca") -> None:
    """For each user_text doc, derive a keyword query → that doc is relevant."""
    for row in convs:
        uid = str(row["id"])
        user_text = (row["user_text"] or "").strip()
        if len(user_text) < 30:
            continue
        doc_id = f"conv_{uid}"
        query = keyword_query(user_text)
        if len(query.split()) < 3:
            continue
        pairs.append({
            "query_id": f"{prefix}{uid}",
            "query": query,
            "relevant_id": doc_id,
            "strategy": "A-conv-keyword",
        })


def strategy_a_segments(segs, docs: list[dict], pairs: list[dict], prefix="sa") -> None:
    """For each segment, use first sentence as keyword query → segment is relevant."""
    for row in segs:
        sid = str(row["id"])
        text = (row["text"] or "").strip()
        if len(text) < 40:
            continue
        doc_id = f"seg_{sid}"
        fst = first_sentence(text)
        query = keyword_query(fst)
        if len(query.split()) < 3:
            continue
        pairs.append({
            "query_id": f"{prefix}{sid}",
            "query": query,
            "relevant_id": doc_id,
            "strategy": "A-seg-keyword",
        })


# ── strategy B: conversational follow-up ────────────────────────────────────

def strategy_b(convs, pairs: list[dict], prefix="b") -> None:
    """msg[i+1] as query → msg[i] (user_text of i) as relevant."""
    rows = list(convs)
    for i in range(len(rows) - 1):
        curr = rows[i]
        nxt = rows[i + 1]
        # Only within the same session if session_id is set
        if curr["session_id"] and nxt["session_id"] and curr["session_id"] != nxt["session_id"]:
            continue
        query = (nxt["user_text"] or "").strip()
        if len(query) < 20 or len(query) > 300:
            continue
        # The query should not be another long statement; short follow-ups are best
        relevant = (curr["axi_text"] or "").strip()
        if len(relevant) < 30:
            continue
        pairs.append({
            "query_id": f"{prefix}{curr['id']}_{nxt['id']}",
            "query": query,
            "relevant_id": f"conv_axi_{curr['id']}",
            "strategy": "B-followup",
        })


# ── strategy C: Q&A ───────────────────────────────────────────────────────────

def strategy_c(convs, pairs: list[dict], prefix="c") -> None:
    """If user_text contains '?', use the question as query → axi_text as relevant doc."""
    for row in convs:
        user_text = (row["user_text"] or "").strip()
        question = extract_question(user_text)
        if not question or len(question) < 15:
            continue
        axi_text = (row["axi_text"] or "").strip()
        if len(axi_text) < 30:
            continue
        pairs.append({
            "query_id": f"{prefix}{row['id']}",
            "query": question,
            "relevant_id": f"conv_axi_{row['id']}",
            "strategy": "C-qa",
        })


# ── build doc pool ────────────────────────────────────────────────────────────

def build_docs(convs, segs) -> list[dict]:
    docs = []
    for row in convs:
        uid = str(row["id"])
        user_text = (row["user_text"] or "").strip()
        axi_text = (row["axi_text"] or "").strip()
        if user_text:
            docs.append({"id": f"conv_{uid}", "text": user_text, "source": "conversations"})
        if axi_text:
            docs.append({"id": f"conv_axi_{uid}", "text": axi_text, "source": "conversations"})
    for row in segs:
        sid = str(row["id"])
        text = (row["text"] or "").strip()
        if text:
            docs.append({"id": f"seg_{sid}", "text": text, "source": "meeting_segments"})
    return docs


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    print("Opening memory.db …")
    c = open_db()
    convs, segs = load_data(c)
    print(f"  conversations: {len(convs)}")
    print(f"  meeting_segments (with text): {len(segs)}")

    docs = build_docs(convs, segs)
    doc_ids = {d["id"] for d in docs}

    pairs: list[dict] = []

    # Strategy A: keyword from user_text → user_text doc
    strategy_a_conversations(convs, docs, pairs)
    # Strategy A: keyword from meeting segment → segment doc
    strategy_a_segments(segs, docs, pairs)
    # Strategy B: follow-up
    strategy_b(convs, pairs)
    # Strategy C: Q&A
    strategy_c(convs, pairs)

    # Filter to pairs where relevant_id exists in doc pool
    pairs = [p for p in pairs if p["relevant_id"] in doc_ids]

    # Deduplicate by query_id
    seen_qids: set[str] = set()
    unique_pairs: list[dict] = []
    for p in pairs:
        if p["query_id"] not in seen_qids:
            seen_qids.add(p["query_id"])
            unique_pairs.append(p)

    # Balance: limit A-conv to 30, B to 20, C to 20, A-seg to at least 15
    def pick_n(strategy_prefix: str, n: int) -> list[dict]:
        return [p for p in unique_pairs if p["strategy"].startswith(strategy_prefix)][:n]

    a_conv = pick_n("A-conv", 20)
    a_seg  = pick_n("A-seg", 20)
    b_pairs = pick_n("B-", 15)
    c_pairs = pick_n("C-", 15)

    selected = a_conv + a_seg + b_pairs + c_pairs
    # Deduplicate again after selection (in case of overlap)
    seen: set[str] = set()
    final_pairs: list[dict] = []
    for p in selected:
        if p["query_id"] not in seen:
            seen.add(p["query_id"])
            final_pairs.append(p)

    print(f"\nTotal pairs selected: {len(final_pairs)}")
    from collections import Counter
    strat_counts = Counter(p["strategy"] for p in final_pairs)
    for s, n in strat_counts.items():
        print(f"  {s}: {n}")

    # Compute which docs are referenced
    referenced_ids = {p["relevant_id"] for p in final_pairs}

    # Write eval_corpus.jsonl (strip strategy field for cleanliness)
    corpus_path = EVAL_DIR / "eval_corpus.jsonl"
    with open(corpus_path, "w", encoding="utf-8") as f:
        for i, p in enumerate(final_pairs, 1):
            out = {
                "query_id": f"q{i:03d}",
                "query": p["query"],
                "relevant_id": p["relevant_id"],
                "strategy": p["strategy"],
            }
            f.write(json.dumps(out, ensure_ascii=False) + "\n")
    print(f"\nWrote {corpus_path} ({len(final_pairs)} pairs)")

    # Write eval_docs.jsonl — include ALL docs (not just referenced ones,
    # for realistic retrieval challenge)
    docs_path = EVAL_DIR / "eval_docs.jsonl"
    with open(docs_path, "w", encoding="utf-8") as f:
        for d in docs:
            f.write(json.dumps(d, ensure_ascii=False) + "\n")
    print(f"Wrote {docs_path} ({len(docs)} docs)")

    # Print 10 example pairs
    doc_map = {d["id"]: d for d in docs}
    print("\n── 10 Example pairs ──────────────────────────────────────────────")
    for p in final_pairs[:10]:
        print(f"\nStrategy: {p['strategy']}")
        print(f"  query_id : {p['query_id']}")
        print(f"  query    : {p['query'][:120]}")
        rel = doc_map.get(p["relevant_id"], {})
        print(f"  relevant : [{p['relevant_id']}] {(rel.get('text') or '')[:100]} …")


if __name__ == "__main__":
    main()
