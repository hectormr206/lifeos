"""Speaker diarization for meetings.

Stage 1 — within-meeting clustering:
  For each segment in the `system` channel, extract a 256-dim voice
  embedding with Resemblyzer. Cluster them with cosine-distance agglomerative
  linkage. Each cluster becomes a "Persona N" (or, after stage 2, a known
  speaker's real name).

Stage 2 — cross-meeting recognition:
  For each in-meeting cluster, average the embeddings into a "cluster
  centroid". Compare to all centroids stored in the `speakers` table.
  If cosine similarity ≥ MATCH_THRESHOLD → reuse that speaker (and update
  its running average). Otherwise create a new `Persona N` entry.

The `mic` channel is always Héctor — we never run diarization on it.

Latency: ~25 ms per second of audio on CPU. A 60 min system channel is
~1.5 min of CPU work, comfortably done in the post-meeting processing
thread without blocking interactive use.
"""
from __future__ import annotations

import io
import logging
import time
import struct
from pathlib import Path
from typing import Iterable

import numpy as np
import soundfile as sf

from axi import store

log = logging.getLogger("axi.diarize")

# Cosine similarity threshold for assigning a meeting cluster to an existing
# global speaker. 0.75 is the classical Resemblyzer same-speaker threshold
# in clean conditions; we keep it conservative to avoid merging two clients
# that sound similar.
MATCH_THRESHOLD = 0.75

# Within-meeting clustering threshold (cosine distance, not similarity).
# 0.25 was Resemblyzer's same-speaker baseline for AVERAGED utterance
# embeddings — but ours are 1.6 s windows where natural intonation
# variance produces 0.30-0.40 distances within the same speaker. With
# 0.25 we got 300+ micro-clusters; with 0.40 the real ~4-speaker
# structure emerges.
WITHIN_MEETING_DISTANCE = 0.40

# Embedding window size — Resemblyzer's recommended diarization window.
# Embedding 60-second chunks whole averaged 4 speakers into one blob and
# returned a single cluster for the whole meeting. 1.6 s windows let us
# attribute each turn separately.
WINDOW_S = 1.6
WINDOW_HOP_S = 0.8  # 50 % overlap

# Sample rate Resemblyzer expects; we'll resample 16 kHz mono if needed.
EMBED_SR = 16_000


def _lazy_encoder():
    """Load Resemblyzer's encoder on first use. Cached at module level so the
    daemon pays the 1-2 s import + model-warm cost once."""
    global _ENCODER
    try:
        return _ENCODER
    except NameError:
        pass
    log.info("loading Resemblyzer voice encoder…")
    from resemblyzer import VoiceEncoder  # noqa: PLC0415
    globals()["_ENCODER"] = VoiceEncoder("cpu")
    return globals()["_ENCODER"]


def _preprocess(audio: np.ndarray, sr: int) -> np.ndarray | None:
    """Mono + 16 kHz + Resemblyzer's loudness/silence normalization."""
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    try:
        from resemblyzer import preprocess_wav  # noqa: PLC0415
        return preprocess_wav(audio, source_sr=sr)
    except Exception as e:  # noqa: BLE001
        log.warning("preprocess_wav failed: %s", e)
        return None


def _window_embeddings(audio: np.ndarray) -> list[tuple[float, np.ndarray]]:
    """Slide a WINDOW_S window with WINDOW_HOP_S step and embed each frame.
    Returns [(window_center_seconds, 256-d embedding)]. Skips windows where
    the post-VAD trimmed audio is too short to be reliable."""
    enc = _lazy_encoder()
    win = int(WINDOW_S * EMBED_SR)
    hop = int(WINDOW_HOP_S * EMBED_SR)
    n = len(audio)
    out: list[tuple[float, np.ndarray]] = []
    for start in range(0, max(1, n - win + 1), hop):
        frame = audio[start:start + win]
        if len(frame) < EMBED_SR // 2:
            continue
        try:
            emb = enc.embed_utterance(frame).astype(np.float32)
        except Exception:  # noqa: BLE001
            continue
        center_s = (start + win / 2) / EMBED_SR
        out.append((center_s, emb))
    return out


def _cosine_distance(a: np.ndarray, b: np.ndarray) -> float:
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    if na == 0 or nb == 0:
        return 1.0
    return 1.0 - float(np.dot(a, b) / (na * nb))


def _cluster_embeddings(embeddings: list[np.ndarray]) -> list[int]:
    """Agglomerative clustering on cosine distance via scipy.

    scipy's `linkage` is C-implemented and runs in O(N² log N), which is the
    only feasible complexity at ~2000 windows per meeting. The previous
    Python-loop single-linkage was O(N³) and hung indefinitely on real
    inputs. Cuts the cluster tree at `WITHIN_MEETING_DISTANCE` (cosine
    distance). Returns parallel cluster ids starting at 0.
    """
    from scipy.cluster.hierarchy import linkage, fcluster
    from scipy.spatial.distance import pdist

    n = len(embeddings)
    if n == 0:
        return []
    if n == 1:
        return [0]
    matrix = np.vstack(embeddings).astype(np.float32)
    # Pre-normalize so euclidean distance ≈ √(2·(1−cos)). Then a euclidean
    # cut of 2·sin(θ/2) corresponds to a cosine-distance cut. With our
    # threshold of 0.25 cosine distance → euclidean ≈ √0.5 ≈ 0.71.
    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    matrix = matrix / norms
    distances = pdist(matrix, metric="cosine")
    Z = linkage(distances, method="average")  # average-linkage is more robust than single
    labels = fcluster(Z, t=WITHIN_MEETING_DISTANCE, criterion="distance")
    # fcluster returns 1-indexed labels; remap to 0-indexed contiguous.
    seen: dict[int, int] = {}
    out: list[int] = []
    for lbl in labels:
        if lbl not in seen:
            seen[lbl] = len(seen)
        out.append(seen[lbl])
    return out


# ─────────────────── cross-meeting matching ──────────────────────────

def _load_all_speakers() -> list[dict]:
    """Return [{id, name, embedding (np), embedding_count}] for every speaker
    that has a stored embedding."""
    c = store._connect()  # noqa: SLF001
    rows = c.execute(
        "SELECT id, name, embedding, embedding_count FROM speakers "
        "WHERE embedding IS NOT NULL"
    ).fetchall()
    out = []
    for r in rows:
        try:
            emb = _blob_to_vec(r["embedding"])
        except Exception:  # noqa: BLE001
            continue
        out.append({
            "id": r["id"],
            "name": r["name"],
            "embedding": emb,
            "embedding_count": r["embedding_count"] or 1,
        })
    return out


def _vec_to_blob(v: np.ndarray) -> bytes:
    arr = v.astype(np.float32)
    return struct.pack("<I", arr.size) + arr.tobytes()


def _blob_to_vec(b: bytes) -> np.ndarray:
    if not b or len(b) < 4:
        raise ValueError("empty blob")
    (n,) = struct.unpack("<I", b[:4])
    return np.frombuffer(b[4:4 + n * 4], dtype=np.float32)


def _find_or_create_speaker(centroid: np.ndarray, known: list[dict],
                            next_persona_idx: int) -> tuple[int, str, bool]:
    """Return (speaker_id, name, created_new). Updates centroid average if matched."""
    best_id = None
    best_name = None
    best_dist = float("inf")
    for k in known:
        d = _cosine_distance(centroid, k["embedding"])
        if d < best_dist:
            best_dist = d
            best_id = k["id"]
            best_name = k["name"]
    similarity = 1.0 - best_dist
    if best_id is not None and similarity >= MATCH_THRESHOLD:
        # Update the matched speaker's running-average embedding.
        target = next(k for k in known if k["id"] == best_id)
        n_old = target["embedding_count"]
        new_emb = (target["embedding"] * n_old + centroid) / (n_old + 1)
        target["embedding"] = new_emb
        target["embedding_count"] = n_old + 1
        now = time.time()
        with store._tx() as c:  # noqa: SLF001
            c.execute(
                "UPDATE speakers SET embedding = ?, embedding_count = ?, updated_at = ? WHERE id = ?",
                (_vec_to_blob(new_emb), n_old + 1, now, best_id),
            )
        return best_id, best_name, False

    # New speaker — assigned a placeholder name the user will rename later.
    name = f"Persona {next_persona_idx}"
    now = time.time()
    with store._tx() as c:  # noqa: SLF001
        cur = c.execute(
            "INSERT INTO speakers(name, embedding, embedding_count, created_at, updated_at) "
            "VALUES (?, ?, 1, ?, ?)",
            (name, _vec_to_blob(centroid), now, now),
        )
        new_id = cur.lastrowid
    return new_id, name, True


# ─────────────────────────── orchestrator ──────────────────────────────

def diarize_meeting(meeting_id: int) -> dict:
    """Cluster the system-channel segments of a meeting and assign speaker
    labels. Returns a summary dict: {clusters, segments_updated, new_speakers}.

    Safe to call multiple times — re-runs replace previous labels.
    """
    c = store._connect()  # noqa: SLF001
    row = c.execute(
        "SELECT data_dir FROM meetings WHERE id = ?", (meeting_id,)
    ).fetchone()
    if row is None:
        return {"error": "meeting not found"}
    data_dir = Path(row["data_dir"])

    seg_rows = c.execute(
        "SELECT id, channel, chunk_path, start_ms, end_ms "
        "FROM meeting_segments "
        "WHERE meeting_id = ? AND channel = 'system' "
        "ORDER BY start_ms",
        (meeting_id,),
    ).fetchall()
    if not seg_rows:
        return {"clusters": 0, "segments_updated": 0, "new_speakers": 0}

    log.info("diarizing meeting %d: %d system segments", meeting_id, len(seg_rows))

    # Step 1: split every chunk into 1.6 s windows and embed each. We track
    # both the global meeting timestamp of the window and which DB segment
    # it belongs to, so we can vote per-segment in step 3.
    window_embeddings: list[np.ndarray] = []
    window_segment_ids: list[int] = []           # parallel to window_embeddings
    for r in seg_rows:
        path = data_dir / r["chunk_path"]
        if not path.exists():
            continue
        try:
            audio, sr = sf.read(str(path))
        except Exception as e:  # noqa: BLE001
            log.warning("could not read %s: %s", path, e)
            continue
        audio = _preprocess(audio, sr)
        if audio is None or len(audio) < EMBED_SR // 2:
            continue
        for _center_s, emb in _window_embeddings(audio):
            window_embeddings.append(emb)
            window_segment_ids.append(r["id"])

    if not window_embeddings:
        return {"clusters": 0, "segments_updated": 0, "new_speakers": 0}

    log.info("embedded %d voice windows (~%.0fs of speech)",
             len(window_embeddings),
             len(window_embeddings) * WINDOW_HOP_S)

    # Step 2: cluster all windows within the meeting.
    cluster_labels = _cluster_embeddings(window_embeddings)
    n_clusters = max(cluster_labels) + 1
    log.info("found %d distinct voice clusters in meeting %d", n_clusters, meeting_id)

    # Step 3: per cluster, compute centroid + match against known speakers.
    known = _load_all_speakers()
    # Persona N numbering: continues from the highest existing if all are unmatched.
    existing_persona = 0
    for k in known:
        if k["name"].lower().startswith("persona "):
            try:
                existing_persona = max(existing_persona, int(k["name"].split()[-1]))
            except ValueError:
                pass
    next_persona = existing_persona + 1

    # Clear any previous diarization for this meeting.
    with store._tx() as txc:  # noqa: SLF001
        txc.execute("DELETE FROM meeting_speakers WHERE meeting_id = ?", (meeting_id,))

    cluster_to_speaker: dict[int, tuple[int, str]] = {}
    new_count = 0
    for cid in range(n_clusters):
        member_embs = [window_embeddings[i] for i, c in enumerate(cluster_labels) if c == cid]
        centroid = np.mean(member_embs, axis=0).astype(np.float32)
        speaker_id, speaker_name, created = _find_or_create_speaker(
            centroid, known, next_persona,
        )
        if created:
            next_persona += 1
            new_count += 1
            # Append to `known` so subsequent clusters compare against this one too.
            known.append({
                "id": speaker_id, "name": speaker_name,
                "embedding": centroid, "embedding_count": 1,
            })
        cluster_to_speaker[cid] = (speaker_id, speaker_name)
        with store._tx() as txc:  # noqa: SLF001
            txc.execute(
                "INSERT INTO meeting_speakers(meeting_id, cluster_id, speaker_id, created_at) "
                "VALUES (?, ?, ?, ?)",
                (meeting_id, cid, speaker_id, time.time()),
            )

    # Step 4: each segment gets the speaker_label of the DOMINANT cluster
    # among its windows. If multiple speakers actually take turns inside one
    # chunk, the chosen one is whoever spoke MOST in that window — accurate
    # enough for executive notes; a future improvement can split a segment
    # into multiple speaker turns if turns matter.
    from collections import Counter, defaultdict
    seg_votes: dict[int, Counter] = defaultdict(Counter)
    for cid, seg_id in zip(cluster_labels, window_segment_ids):
        seg_votes[seg_id][cid] += 1
    updated = 0
    for seg_id, votes in seg_votes.items():
        dominant_cid, _ = votes.most_common(1)[0]
        _spk_id, spk_name = cluster_to_speaker[dominant_cid]
        with store._tx() as txc:  # noqa: SLF001
            txc.execute(
                "UPDATE meeting_segments SET speaker_label = ? WHERE id = ?",
                (spk_name, seg_id),
            )
            updated += 1

    log.info("meeting %d: %d clusters, %d segments updated, %d new speakers",
             meeting_id, n_clusters, updated, new_count)
    return {
        "clusters": n_clusters,
        "segments_updated": updated,
        "new_speakers": new_count,
    }


def rename_speaker(speaker_id: int, new_name: str) -> int:
    """Rename a global speaker. Also updates the cached `speaker_label` on
    every segment that was attributed to this speaker (across meetings).

    Returns the number of segments retroactively relabeled.
    """
    new_name = (new_name or "").strip()
    if not new_name:
        raise ValueError("name cannot be empty")
    c = store._connect()  # noqa: SLF001
    row = c.execute("SELECT name FROM speakers WHERE id = ?", (speaker_id,)).fetchone()
    if not row:
        raise ValueError(f"speaker {speaker_id} not found")
    old_name = row["name"]
    if old_name == new_name:
        return 0
    now = time.time()
    with store._tx() as txc:  # noqa: SLF001
        txc.execute(
            "UPDATE speakers SET name = ?, updated_at = ? WHERE id = ?",
            (new_name, now, speaker_id),
        )
        # Walk meeting_speakers and update every segment that this speaker
        # was assigned to across all the meetings that mention them.
        ms_rows = txc.execute(
            "SELECT meeting_id, cluster_id FROM meeting_speakers WHERE speaker_id = ?",
            (speaker_id,),
        ).fetchall()
        updated_total = 0
        for ms in ms_rows:
            # We don't store cluster→segment mapping explicitly; instead we
            # rely on the current speaker_label being the OLD name and rewrite.
            cur = txc.execute(
                "UPDATE meeting_segments SET speaker_label = ? "
                "WHERE meeting_id = ? AND speaker_label = ?",
                (new_name, ms["meeting_id"], old_name),
            )
            updated_total += cur.rowcount or 0
    return updated_total
