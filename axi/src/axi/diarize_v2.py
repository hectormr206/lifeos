"""Speaker diarization V2 — pyannote.audio (PRD P2.1).

Opt-in replacement for `axi.diarize` (V0, Resemblyzer + agglomerative). V2 uses
pyannote/speaker-diarization-3.1, which combines a learned segmentation model
with embedding-based clustering — generally tighter speaker turn boundaries
and better robustness on noisy meeting audio.

Design choices:

* Same public signature as V0 (`diarize_meeting(meeting_id: int) -> dict`) so
  it is a strict drop-in replacement controlled by `diarization_v2_enabled`.
  Anything else (e.g. a path-based API) would force changes to `meeting.py`
  every time the flag flips, which defeats the kill switch.
* Heavy imports (torch, pyannote) are LAZY — done inside the function. The
  daemon must not crash at module import time if pyannote breaks.
* CPU only. Blackwell (sm_120) has no torch kernels in the bundled CUDA build.
  `AXI_DIARIZE_DEVICE=cuda` overrides for future hardware; if CUDA crashes
  at runtime we silently fall back to CPU.
* ANY failure (import, model load, inference) falls back to V0 so a broken
  pyannote install never breaks meeting processing. The fallback path is
  logged via `events.log_error("diarize_v2", ...)`.

Cross-meeting matching (Persona N reuse) is still handled by V0's centroid
logic. V2 produces in-meeting clusters; we hand them off to the same DB layer
(`meeting_speakers`, `meeting_segments.speaker_label`) and let V0's
`_find_or_create_speaker` resolve identities. Centroids come from Resemblyzer
embeddings computed on the windows that fall inside each pyannote-detected
turn — this keeps the speakers table consistent regardless of which engine
ran today.
"""
from __future__ import annotations

import logging
import os
import time
from pathlib import Path

import numpy as np
import soundfile as sf

from axi import diarize as _v0
from axi import events, store

log = logging.getLogger("axi.diarize_v2")

_ENV_PATH = Path.home() / "LifeOS" / "axi" / ".env"


def _load_hf_token() -> str | None:
    """Return HF_TOKEN, sourcing `.env` if it is not already in the process env.

    We avoid python-dotenv to keep dependencies minimal — the file is a flat
    KEY=VALUE list managed by us, so a 5-line parser is enough. We never log
    the token; only its presence.
    """
    token = os.environ.get("HF_TOKEN")
    if token:
        return token
    if not _ENV_PATH.exists():
        return None
    try:
        for line in _ENV_PATH.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            if key.strip() == "HF_TOKEN":
                value = value.strip().strip('"').strip("'")
                if value:
                    os.environ["HF_TOKEN"] = value
                    return value
    except OSError as e:
        log.warning("could not read .env for HF_TOKEN: %s", e)
    return None


def _resolve_device() -> str:
    """CPU by default. `AXI_DIARIZE_DEVICE=cuda` opts into GPU once kernels
    exist for Blackwell. Anything unrecognized falls back to CPU."""
    requested = os.environ.get("AXI_DIARIZE_DEVICE", "cpu").lower()
    if requested == "cuda":
        return "cuda"
    return "cpu"


def _concatenate_system_audio(meeting_id: int) -> tuple[np.ndarray, int, list[dict]] | None:
    """Stitch all system-channel chunks of a meeting into one waveform.

    Returns (audio, sample_rate, segment_index) or None if nothing usable.
    `segment_index` maps each DB segment to its (offset_s, duration_s) within
    the concatenated buffer, which is what we need to map pyannote turns back
    to `meeting_segments.id` rows.
    """
    c = store._connect()  # noqa: SLF001
    row = c.execute(
        "SELECT data_dir FROM meetings WHERE id = ?", (meeting_id,)
    ).fetchone()
    if row is None:
        return None
    data_dir = Path(row["data_dir"])

    seg_rows = c.execute(
        "SELECT id, chunk_path, start_ms, end_ms "
        "FROM meeting_segments "
        "WHERE meeting_id = ? AND channel = 'system' "
        "ORDER BY start_ms",
        (meeting_id,),
    ).fetchall()
    if not seg_rows:
        return None

    target_sr = 16_000
    pieces: list[np.ndarray] = []
    index: list[dict] = []
    offset_s = 0.0
    for r in seg_rows:
        path = data_dir / r["chunk_path"]
        if not path.exists():
            continue
        try:
            audio, sr = sf.read(str(path))
        except Exception as e:  # noqa: BLE001
            log.warning("could not read %s: %s", path, e)
            continue
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        audio = audio.astype(np.float32)
        if sr != target_sr:
            # Linear resample — fine for diarization, which doesn't need
            # high-fidelity reconstruction. Avoids pulling in scipy/librosa
            # just for this.
            ratio = target_sr / sr
            new_len = int(round(len(audio) * ratio))
            if new_len <= 0:
                continue
            x_old = np.linspace(0.0, 1.0, num=len(audio), endpoint=False)
            x_new = np.linspace(0.0, 1.0, num=new_len, endpoint=False)
            audio = np.interp(x_new, x_old, audio).astype(np.float32)
        duration_s = len(audio) / target_sr
        pieces.append(audio)
        index.append({
            "segment_id": r["id"],
            "offset_s": offset_s,
            "duration_s": duration_s,
            "start_ms_db": int(r["start_ms"] or 0),
        })
        offset_s += duration_s

    if not pieces:
        return None
    return np.concatenate(pieces), target_sr, index


def _assign_segment_labels(
    turns: list[dict], index: list[dict]
) -> dict[int, str]:
    """For each DB segment in `index`, pick the dominant pyannote turn that
    overlaps it. Returns {segment_id: pyannote_label}.

    Concatenated-time math: a segment lives at [offset_s, offset_s + duration].
    Any turn that intersects that interval votes proportional to overlap.
    """
    out: dict[int, str] = {}
    for seg in index:
        seg_start = seg["offset_s"]
        seg_end = seg_start + seg["duration_s"]
        votes: dict[str, float] = {}
        for t in turns:
            ov = max(0.0, min(seg_end, t["end"]) - max(seg_start, t["start"]))
            if ov > 0:
                votes[t["label"]] = votes.get(t["label"], 0.0) + ov
        if not votes:
            continue
        out[seg["segment_id"]] = max(votes, key=votes.get)
    return out


def _run_pyannote(audio: np.ndarray, sr: int, token: str, device: str) -> list[dict]:
    """Run pyannote on an in-memory mono waveform. Returns
    [{start, end, label}] in seconds.

    Pyannote's Pipeline accepts an in-memory dict {"waveform": Tensor[1,N], "sample_rate": sr}
    — saves us a round-trip through a temporary WAV.
    """
    # Lazy imports: we MUST tolerate pyannote being broken at module import time.
    import inspect  # noqa: PLC0415
    import torch  # noqa: PLC0415
    from pyannote.audio import Pipeline  # noqa: PLC0415

    # pyannote.audio renamed the auth kwarg between 3.x and 4.x:
    #   3.x:  use_auth_token=
    #   4.x:  token=
    # CachyOS pulled 4.0.4 with the new name and the old call silently
    # raised TypeError, killing diarization without surfacing. Inspect
    # the signature once and pass the right kwarg.
    sig = inspect.signature(Pipeline.from_pretrained)
    token_kwarg = "token" if "token" in sig.parameters else "use_auth_token"
    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        **{token_kwarg: token},
    )
    if pipeline is None:
        raise RuntimeError(
            "Pipeline.from_pretrained returned None — likely missing license "
            "acceptance for pyannote/speaker-diarization-3.1 or "
            "pyannote/segmentation-3.0."
        )

    target_device = torch.device(device)
    try:
        pipeline.to(target_device)
    except Exception as e:  # noqa: BLE001
        # Most likely path: CUDA requested on Blackwell — torch loads, kernel
        # call later explodes. Fall back to CPU immediately.
        log.warning("device=%s failed (%s); falling back to cpu", device, e)
        pipeline.to(torch.device("cpu"))

    waveform = torch.from_numpy(audio).unsqueeze(0)  # [1, N]
    diarization = pipeline({"waveform": waveform, "sample_rate": sr})

    turns: list[dict] = []
    for turn, _track, label in diarization.itertracks(yield_label=True):
        turns.append({
            "start": float(turn.start),
            "end": float(turn.end),
            "label": str(label),
        })
    return turns


def diarize_meeting(meeting_id: int) -> dict:
    """V2 entry point. Drop-in replacement for `axi.diarize.diarize_meeting`.

    Returns the same shape: {clusters, segments_updated, new_speakers}.
    On ANY failure path we delegate to V0 and log via the event store.
    """
    token = _load_hf_token()
    if not token:
        events.log_error(
            "diarize_v2",
            "HF_TOKEN not available — falling back to V0",
            {"meeting_id": meeting_id},
        )
        return _v0.diarize_meeting(meeting_id)

    try:
        stitched = _concatenate_system_audio(meeting_id)
        if stitched is None:
            # No audio — same empty result V0 would return.
            return {"clusters": 0, "segments_updated": 0, "new_speakers": 0}
        audio, sr, index = stitched

        device = _resolve_device()
        log.info(
            "diarize_v2: meeting %d, %d segments, %.1fs audio, device=%s",
            meeting_id, len(index), len(audio) / sr, device,
        )

        t0 = time.time()
        turns = _run_pyannote(audio, sr, token, device)
        log.info(
            "diarize_v2: pyannote produced %d turns in %.2fs",
            len(turns), time.time() - t0,
        )
    except Exception as e:  # noqa: BLE001
        events.log_error(
            "diarize_v2",
            f"pyannote pipeline failed — falling back to V0: {e!r}",
            {"meeting_id": meeting_id, "error_type": type(e).__name__},
        )
        return _v0.diarize_meeting(meeting_id)

    # Map pyannote turns onto DB segments.
    seg_to_label = _assign_segment_labels(turns, index)
    unique_labels = sorted(set(seg_to_label.values()))
    if not unique_labels:
        return {"clusters": 0, "segments_updated": 0, "new_speakers": 0}

    # ── Cross-meeting matching using V0's centroid logic ─────────────────
    # For each pyannote cluster, compute a Resemblyzer centroid by embedding
    # the windows from each cluster's segments. This keeps the `speakers`
    # table compatible with V0 so renames + Persona N numbering still work.
    try:
        cluster_centroids = _centroids_per_cluster(meeting_id, index, turns)
    except Exception as e:  # noqa: BLE001
        # Embedding failure shouldn't lose the diarization; record without
        # cross-meeting matching by assigning fresh persona names.
        log.warning("diarize_v2: centroid pass failed (%s); using fresh personas", e)
        cluster_centroids = {}

    return _persist_clusters(meeting_id, seg_to_label, unique_labels, cluster_centroids)


def _centroids_per_cluster(
    meeting_id: int, index: list[dict], turns: list[dict]
) -> dict[str, np.ndarray]:
    """Compute one centroid per pyannote cluster using Resemblyzer windows.

    We slice the concatenated audio at the turn boundaries and feed each
    slice through V0's embedding helper. Cheap because we reuse V0's cached
    encoder and only embed turn-sized chunks (no full-meeting embedding pass).
    """
    c = store._connect()  # noqa: SLF001
    row = c.execute(
        "SELECT data_dir FROM meetings WHERE id = ?", (meeting_id,)
    ).fetchone()
    if row is None:
        return {}
    data_dir = Path(row["data_dir"])

    # Re-read all system audio to grab raw slices. Cheaper than re-stitching
    # the float buffer — soundfile gives us original sample rates we can pass
    # straight to Resemblyzer's preprocess_wav.
    per_path: dict[str, tuple[np.ndarray, int, float]] = {}
    offset_cursor = 0.0
    for seg in index:
        rel_offset = seg["offset_s"]
        # Find chunk path by segment_id
        srow = c.execute(
            "SELECT chunk_path FROM meeting_segments WHERE id = ?",
            (seg["segment_id"],),
        ).fetchone()
        if srow is None:
            continue
        path = data_dir / srow["chunk_path"]
        if not path.exists():
            continue
        try:
            audio, sr = sf.read(str(path))
        except Exception:  # noqa: BLE001
            continue
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        per_path[srow["chunk_path"]] = (audio.astype(np.float32), sr, rel_offset)
        offset_cursor = rel_offset + seg["duration_s"]

    # For each turn, locate the segment it overlaps the most and embed the
    # corresponding raw audio slice. This avoids reproducing pyannote's
    # internal embeddings; we just want a Resemblyzer centroid for storage.
    by_cluster: dict[str, list[np.ndarray]] = {}
    for t in turns:
        # Find best-overlapping DB segment.
        best = None
        best_ov = 0.0
        for seg in index:
            ov = max(0.0, min(seg["offset_s"] + seg["duration_s"], t["end"])
                     - max(seg["offset_s"], t["start"]))
            if ov > best_ov:
                best_ov = ov
                best = seg
        if best is None or best_ov < 0.3:  # need at least 0.3 s of overlap
            continue
        srow = c.execute(
            "SELECT chunk_path FROM meeting_segments WHERE id = ?",
            (best["segment_id"],),
        ).fetchone()
        if srow is None:
            continue
        rec = per_path.get(srow["chunk_path"])
        if rec is None:
            continue
        audio, sr, rel_offset = rec
        rel_start = max(0.0, t["start"] - rel_offset)
        rel_end = max(rel_start, t["end"] - rel_offset)
        s = int(rel_start * sr)
        e = int(rel_end * sr)
        if e - s < sr // 2:
            continue
        slice_audio = audio[s:e]
        pre = _v0._preprocess(slice_audio, sr)  # noqa: SLF001
        if pre is None or len(pre) < 8_000:
            continue
        windows = _v0._window_embeddings(pre)  # noqa: SLF001
        if not windows:
            continue
        for _center_s, emb in windows:
            by_cluster.setdefault(t["label"], []).append(emb)

    out: dict[str, np.ndarray] = {}
    for label, embs in by_cluster.items():
        out[label] = np.mean(np.vstack(embs), axis=0).astype(np.float32)
    return out


def _persist_clusters(
    meeting_id: int,
    seg_to_label: dict[int, str],
    unique_labels: list[str],
    cluster_centroids: dict[str, np.ndarray],
) -> dict:
    """Write meeting_speakers + meeting_segments.speaker_label rows.

    Reuses V0's `_find_or_create_speaker` so Persona N numbering and rename
    propagation stay consistent across engines.
    """
    known = _v0._load_all_speakers()  # noqa: SLF001
    existing_persona = 0
    for k in known:
        if k["name"].lower().startswith("persona "):
            try:
                existing_persona = max(existing_persona, int(k["name"].split()[-1]))
            except ValueError:
                pass
    next_persona = existing_persona + 1

    with store._tx() as txc:  # noqa: SLF001
        txc.execute(
            "DELETE FROM meeting_speakers WHERE meeting_id = ?", (meeting_id,)
        )

    # Stable cluster_id mapping: position in `unique_labels` after sort.
    label_to_cid = {lbl: i for i, lbl in enumerate(unique_labels)}
    cluster_to_speaker: dict[str, tuple[int, str]] = {}
    new_count = 0
    for label in unique_labels:
        centroid = cluster_centroids.get(label)
        if centroid is None:
            # No centroid (embedding pass failed for this cluster) — register
            # a fresh persona with a zero vector so we never accidentally
            # match it later. embedding_count=0 prevents it from polluting
            # averages.
            centroid = np.zeros(256, dtype=np.float32)
            with store._tx() as txc:  # noqa: SLF001
                cur = txc.execute(
                    "INSERT INTO speakers(name, embedding, embedding_count, "
                    "created_at, updated_at) VALUES (?, ?, 0, ?, ?)",
                    (f"Persona {next_persona}", _v0._vec_to_blob(centroid),  # noqa: SLF001
                     time.time(), time.time()),
                )
                speaker_id = cur.lastrowid
            speaker_name = f"Persona {next_persona}"
            next_persona += 1
            new_count += 1
        else:
            speaker_id, speaker_name, created = _v0._find_or_create_speaker(  # noqa: SLF001
                centroid, known, next_persona,
            )
            if created:
                next_persona += 1
                new_count += 1
                known.append({
                    "id": speaker_id, "name": speaker_name,
                    "embedding": centroid, "embedding_count": 1,
                })
        cluster_to_speaker[label] = (speaker_id, speaker_name)
        with store._tx() as txc:  # noqa: SLF001
            txc.execute(
                "INSERT INTO meeting_speakers(meeting_id, cluster_id, speaker_id, created_at) "
                "VALUES (?, ?, ?, ?)",
                (meeting_id, label_to_cid[label], speaker_id, time.time()),
            )

    updated = 0
    for seg_id, label in seg_to_label.items():
        _spk_id, spk_name = cluster_to_speaker[label]
        with store._tx() as txc:  # noqa: SLF001
            txc.execute(
                "UPDATE meeting_segments SET speaker_label = ? WHERE id = ?",
                (spk_name, seg_id),
            )
            updated += 1

    log.info(
        "diarize_v2: meeting %d → %d clusters, %d segments labeled, %d new speakers",
        meeting_id, len(unique_labels), updated, new_count,
    )
    return {
        "clusters": len(unique_labels),
        "segments_updated": updated,
        "new_speakers": new_count,
    }
