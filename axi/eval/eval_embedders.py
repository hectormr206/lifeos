"""Eval script for Spanish embedding models.

Models evaluated:
  - Qwen3-Embedding-4B (GGUF Q4_K_M) via llama-server on port 8099
  - BGE-M3 (GGUF Q4_K_M) via llama-server on port 8099
  - Harrier-OSS-0.6B: SKIPPED — repo not found on HuggingFace

Metrics computed per model:
  MRR@5   — mean reciprocal rank at cutoff 5
  NDCG@10 — normalized discounted cumulative gain at cutoff 10 (binary relevance)

Results saved to eval_results.json.
"""
from __future__ import annotations

import json
import math
import os
import signal
import subprocess
import time
from pathlib import Path
from typing import Any

import requests

EVAL_DIR = Path(__file__).parent
CORPUS_PATH = EVAL_DIR / "eval_corpus.jsonl"
DOCS_PATH = EVAL_DIR / "eval_docs.jsonl"
RESULTS_PATH = EVAL_DIR / "eval_results.json"

EMBED_PORT = 8099
EMBED_HOST = "127.0.0.1"
EMBED_BASE_URL = f"http://{EMBED_HOST}:{EMBED_PORT}"

MODELS = [
    {
        "id": "qwen3-embedding-4b",
        "gguf_path": os.path.expanduser("~/LifeOS/models/qwen3-embedding-4b/Qwen3-Embedding-4B-Q4_K_M.gguf"),
        "backend": "llama.cpp_gguf",
        "pooling": "last",
        # Qwen3 instruction format for queries; no prefix for docs
        "query_prefix": "Instruct: Given a Spanish text, retrieve the most relevant passage\nQuery: ",
        "doc_prefix": "",
        "embedding_dim": 4096,  # full dim; we'll detect actual from response
    },
    {
        "id": "bge-m3",
        "gguf_path": os.path.expanduser("~/LifeOS/models/bge-m3/bge-m3-Q4_K_M.gguf"),
        "backend": "llama.cpp_gguf",
        "pooling": "cls",
        # BGE-M3 is multilingual; no instruction prefix needed
        "query_prefix": "",
        "doc_prefix": "",
        "embedding_dim": 1024,
    },
]


# ── data loading ──────────────────────────────────────────────────────────────

def load_corpus() -> list[dict]:
    with open(CORPUS_PATH, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def load_docs() -> list[dict]:
    with open(DOCS_PATH, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


# ── llama-server management ───────────────────────────────────────────────────

def kill_embed_server() -> None:
    """Kill any process listening on EMBED_PORT or named llama-server.*8099."""
    try:
        subprocess.run(
            ["pkill", "-f", f"llama-server.*{EMBED_PORT}"],
            timeout=10,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    # Also kill by port in case process name differs
    try:
        result = subprocess.run(
            ["fuser", f"{EMBED_PORT}/tcp"],
            capture_output=True, text=True, timeout=5,
        )
        if result.stdout.strip():
            pids = result.stdout.strip().split()
            for pid in pids:
                try:
                    os.kill(int(pid), signal.SIGTERM)
                except (ProcessLookupError, ValueError):
                    pass
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    time.sleep(2)


def wait_for_server(timeout: int = 120) -> bool:
    """Poll /health until status == 'ok' or timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = requests.get(f"{EMBED_BASE_URL}/health", timeout=3)
            data = r.json()
            if data.get("status") == "ok":
                return True
        except Exception:
            pass
        time.sleep(2)
    return False


def start_embed_server(model_cfg: dict) -> subprocess.Popen | None:
    """Start llama-server for embedding in background. Returns Popen or None on failure."""
    kill_embed_server()

    gguf = model_cfg["gguf_path"]
    pooling = model_cfg.get("pooling", "last")

    cmd = [
        "/usr/bin/llama-server",
        "-m", gguf,
        "--embedding",
        "--pooling", pooling,
        "-ngl", "0",
        "--device", "none",   # force CPU-only — no CUDA allocations
        "--host", EMBED_HOST,
        "--port", str(EMBED_PORT),
        "-c", "2048",
        "--batch-size", "512",
    ]

    print(f"  Starting llama-server: {' '.join(cmd)}")
    log_path = EVAL_DIR / f"server_{model_cfg['id']}.log"
    with open(log_path, "w") as log_f:
        proc = subprocess.Popen(
            cmd,
            stdout=log_f,
            stderr=log_f,
        )

    print(f"  Waiting for server health (up to 120s) …", flush=True)
    if not wait_for_server(120):
        print(f"  ERROR: server did not become healthy. Check {log_path}")
        proc.terminate()
        return None

    print(f"  Server ready.")
    return proc


# ── embedding via llama-server ────────────────────────────────────────────────

def embed_batch(texts: list[str], batch_size: int = 32) -> list[list[float]]:
    """Embed a list of texts in batches, return list of float vectors."""
    all_vecs: list[list[float]] = []
    for i in range(0, len(texts), batch_size):
        batch = texts[i : i + batch_size]
        payload = {"input": batch, "encoding_format": "float"}
        try:
            r = requests.post(
                f"{EMBED_BASE_URL}/v1/embeddings",
                json=payload,
                timeout=120,
            )
            r.raise_for_status()
            data = r.json()
            # Sort by index to preserve order
            items = sorted(data["data"], key=lambda x: x["index"])
            for item in items:
                all_vecs.append(item["embedding"])
        except Exception as exc:
            print(f"  embed_batch error on batch {i}: {exc}")
            # Pad with zeros to keep alignment
            for _ in batch:
                all_vecs.append([])
        if (i // batch_size) % 5 == 0:
            print(f"  embedded {min(i + batch_size, len(texts))}/{len(texts)}", flush=True)
    return all_vecs


# ── math utils ───────────────────────────────────────────────────────────────

def l2_normalize(vec: list[float]) -> list[float]:
    norm = math.sqrt(sum(x * x for x in vec))
    if norm == 0:
        return vec
    return [x / norm for x in vec]


def dot(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b))


def rank_docs(query_vec: list[float], doc_vecs: list[list[float]]) -> list[int]:
    """Return doc indices sorted by cosine similarity (desc)."""
    scores = [(dot(query_vec, dv), i) for i, dv in enumerate(doc_vecs) if dv]
    scores.sort(key=lambda x: x[0], reverse=True)
    return [i for _, i in scores]


# ── metrics ───────────────────────────────────────────────────────────────────

def mrr_at_k(ranked_ids: list[str], relevant_id: str, k: int = 5) -> float:
    for rank, doc_id in enumerate(ranked_ids[:k], 1):
        if doc_id == relevant_id:
            return 1.0 / rank
    return 0.0


def ndcg_at_k(ranked_ids: list[str], relevant_id: str, k: int = 10) -> float:
    dcg = 0.0
    for rank, doc_id in enumerate(ranked_ids[:k], 1):
        if doc_id == relevant_id:
            dcg = 1.0 / math.log2(rank + 1)
            break
    # Ideal DCG (1 relevant doc at rank 1)
    idcg = 1.0 / math.log2(2)  # log2(1+1)
    return dcg / idcg if idcg > 0 else 0.0


# ── evaluation loop ───────────────────────────────────────────────────────────

def evaluate_model(model_cfg: dict, corpus: list[dict], docs: list[dict]) -> dict[str, Any]:
    model_id = model_cfg["id"]
    query_prefix = model_cfg["query_prefix"]
    doc_prefix = model_cfg["doc_prefix"]
    doc_ids = [d["id"] for d in docs]

    print(f"\n{'='*60}")
    print(f"Evaluating: {model_id}")
    print(f"  GGUF: {model_cfg['gguf_path']}")
    print(f"  query_prefix: {repr(query_prefix[:60])}")
    print(f"  doc_prefix: {repr(doc_prefix[:60])}")

    proc = start_embed_server(model_cfg)
    if proc is None:
        return {
            "model_id": model_id,
            "error": "server failed to start",
            "mrr_at_5": None,
            "ndcg_at_10": None,
        }

    try:
        # Embed all docs
        print(f"\n  Embedding {len(docs)} docs …")
        doc_texts = [doc_prefix + d["text"] for d in docs]
        doc_vecs_raw = embed_batch(doc_texts, batch_size=64)
        doc_vecs = [l2_normalize(v) if v else [] for v in doc_vecs_raw]

        # Detect actual embedding dim from first non-empty vector
        actual_dim = 0
        for v in doc_vecs:
            if v:
                actual_dim = len(v)
                break
        print(f"  Detected embedding dim: {actual_dim}")

        # Embed all queries
        print(f"\n  Embedding {len(corpus)} queries …")
        query_texts = [query_prefix + p["query"] for p in corpus]
        query_vecs_raw = embed_batch(query_texts, batch_size=32)
        query_vecs = [l2_normalize(v) if v else [] for v in query_vecs_raw]

        # Compute metrics
        mrr_scores: list[float] = []
        ndcg_scores: list[float] = []

        for pair, q_vec in zip(corpus, query_vecs):
            if not q_vec:
                mrr_scores.append(0.0)
                ndcg_scores.append(0.0)
                continue
            ranked_indices = rank_docs(q_vec, doc_vecs)
            ranked_doc_ids = [doc_ids[i] for i in ranked_indices]
            rel_id = pair["relevant_id"]
            mrr_scores.append(mrr_at_k(ranked_doc_ids, rel_id, k=5))
            ndcg_scores.append(ndcg_at_k(ranked_doc_ids, rel_id, k=10))

        mrr = sum(mrr_scores) / len(mrr_scores) if mrr_scores else 0.0
        ndcg = sum(ndcg_scores) / len(ndcg_scores) if ndcg_scores else 0.0

        print(f"\n  Results for {model_id}:")
        print(f"    MRR@5   = {mrr:.4f}")
        print(f"    NDCG@10 = {ndcg:.4f}")

        return {
            "model_id": model_id,
            "gguf_path": model_cfg["gguf_path"],
            "backend": model_cfg["backend"],
            "embedding_dim": actual_dim,
            "n_queries": len(corpus),
            "n_docs": len(docs),
            "mrr_at_5": round(mrr, 4),
            "ndcg_at_10": round(ndcg, 4),
            "query_prefix": query_prefix,
            "doc_prefix": doc_prefix,
        }

    finally:
        print(f"\n  Killing llama-server …")
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        kill_embed_server()
        time.sleep(2)


# ── decision rule ─────────────────────────────────────────────────────────────

def decide_winner(results: list[dict]) -> dict:
    """
    Decision rule:
    1. If BGE-M3 MRR@5 > Qwen3 MRR@5 + 0.05 → BGE-M3 wins
    2. Harrier: SKIPPED (not available)
    3. Otherwise → Qwen3-Embedding-4B wins
    """
    by_id = {r["model_id"]: r for r in results if r.get("mrr_at_5") is not None}

    qwen = by_id.get("qwen3-embedding-4b")
    bge = by_id.get("bge-m3")

    if not qwen and not bge:
        return {"winner": None, "reason": "no valid results"}

    if not bge:
        return {"winner": "qwen3-embedding-4b", "reason": "bge-m3 failed to run"}

    if not qwen:
        return {"winner": "bge-m3", "reason": "qwen3-embedding-4b failed to run"}

    qwen_mrr = qwen["mrr_at_5"]
    bge_mrr = bge["mrr_at_5"]

    if bge_mrr > qwen_mrr + 0.05:
        return {
            "winner": "bge-m3",
            "reason": f"BGE-M3 MRR@5 ({bge_mrr:.4f}) > Qwen3 MRR@5 ({qwen_mrr:.4f}) + 0.05 threshold",
        }
    else:
        return {
            "winner": "qwen3-embedding-4b",
            "reason": f"Qwen3 MRR@5 ({qwen_mrr:.4f}) within 0.05 of BGE-M3 ({bge_mrr:.4f}); Qwen3 wins by default",
        }


# ── write config ──────────────────────────────────────────────────────────────

CONFIG_SHAPES = {
    "qwen3-embedding-4b": {
        "id": "qwen3-embedding-4b",
        "gguf_path": os.path.expanduser("~/LifeOS/models/qwen3-embedding-4b/Qwen3-Embedding-4B-Q4_K_M.gguf"),
        "ctx": 512,
        "ngl": 0,
        "port": 8091,
        "extra_args": ["--embedding", "--pooling", "last"],
        "embedding_dim": 512,
        "query_prefix": "Instruct: Given a Spanish text, retrieve the most relevant passage\nQuery: ",
        "doc_prefix": "",
        "serving_backend": "llama.cpp_gguf",
    },
    "bge-m3": {
        "id": "bge-m3",
        "gguf_path": os.path.expanduser("~/LifeOS/models/bge-m3/bge-m3-Q4_K_M.gguf"),
        "ctx": 512,
        "ngl": 0,
        "port": 8091,
        "extra_args": ["--embedding", "--pooling", "cls"],
        "embedding_dim": 1024,
        "query_prefix": "",
        "doc_prefix": "",
        "serving_backend": "llama.cpp_gguf",
    },
}


def write_config(winner_id: str) -> Path:
    config_dir = Path.home() / "LifeOS/lifeos/axi/config"
    config_dir.mkdir(parents=True, exist_ok=True)
    config_path = config_dir / "active_embed_model.json"
    cfg = CONFIG_SHAPES[winner_id]
    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    return config_path


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    print("Loading eval corpus …")
    corpus = load_corpus()
    docs = load_docs()
    print(f"  {len(corpus)} queries, {len(docs)} docs")

    results: list[dict] = []

    for model_cfg in MODELS:
        result = evaluate_model(model_cfg, corpus, docs)
        results.append(result)

    print("\n" + "="*60)
    print("RESULTS SUMMARY")
    print("="*60)
    print(f"{'Model':<28} {'MRR@5':>8} {'NDCG@10':>10} {'Backend'}")
    print("-"*60)
    for r in results:
        mrr = f"{r['mrr_at_5']:.4f}" if r.get("mrr_at_5") is not None else "FAILED"
        ndcg = f"{r['ndcg_at_10']:.4f}" if r.get("ndcg_at_10") is not None else "FAILED"
        print(f"{r['model_id']:<28} {mrr:>8} {ndcg:>10} {r.get('backend','?')}")
    print()
    print("Harrier-OSS-0.6B: SKIPPED — repo microsoft/Harrier-OSS-0.6b-GGUF not found on HuggingFace")

    decision = decide_winner(results)
    winner_id = decision["winner"]
    print(f"\nDecision: {winner_id}")
    print(f"Reason  : {decision['reason']}")

    config_path = None
    if winner_id and winner_id in CONFIG_SHAPES:
        config_path = write_config(winner_id)
        print(f"\nConfig written to: {config_path}")
        with open(config_path, encoding="utf-8") as f:
            print(json.dumps(json.load(f), indent=2))

    # Save full results JSON
    output = {
        "eval_date": "2026-06-19",
        "n_queries": len(corpus),
        "n_docs": len(docs),
        "models": results,
        "harrier": {"status": "skipped", "reason": "repo microsoft/Harrier-OSS-0.6b-GGUF not found"},
        "decision": decision,
        "config_written": str(config_path) if config_path else None,
    }
    with open(RESULTS_PATH, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
    print(f"\nFull results saved to: {RESULTS_PATH}")


if __name__ == "__main__":
    main()
