/// One meeting's full detail + its speakers. Shape read directly from
/// `axi/src/axi/dashboard.py`:
/// - `meeting_detail` (`GET /api/meetings/{mid}`, aliased
///   `/api/v1/meetings/{id}`): `{id, start, end, duration_s, status,
///   transcript, summary, data_dir, screen_count, screens,
///   segments: [{channel, start_ms, end_ms, text, speaker_label}, ...]}`.
///   `screens`/`screen_count`/`data_dir` are deliberately NOT modeled here —
///   screen-capture images are out of scope for this slice (an auth'd
///   binary endpoint, `GET /api/meetings/{mid}/screen/{filename}` — future
///   add).
/// - `meeting_speakers` (`GET /api/meetings/{mid}/speakers`, aliased
///   `/api/v1/meetings/{id}/speakers`): `[{id, name, segment_count,
///   first_ms}, ...]`.
/// Merged client-side into one [MeetingDetail] (mirrors
/// `SettingsRepository.fetchConfig`'s two-GET merge pattern) and cached
/// under a single `meetings:detail:{id}` key.
library;

/// One transcript utterance. `speakerLabel` is the engine's raw diarization
/// label (renamed speakers show their real name here, via `rename_speaker`
/// on the laptop — kept verbatim, no client-side remapping).
class MeetingSegment {
  const MeetingSegment({
    required this.channel,
    required this.startMs,
    this.endMs,
    required this.text,
    this.speakerLabel,
  });

  final String channel;
  final int startMs;
  final int? endMs;
  final String text;
  final String? speakerLabel;

  @override
  bool operator ==(Object other) =>
      other is MeetingSegment &&
      other.channel == channel &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.text == text &&
      other.speakerLabel == speakerLabel;

  @override
  int get hashCode => Object.hash(channel, startMs, endMs, text, speakerLabel);
}

/// One speaker detected in the meeting (`meeting_speakers`'s row) — the
/// "Participantes" section.
class MeetingSpeaker {
  const MeetingSpeaker({required this.id, required this.name, this.segmentCount = 0, this.firstMs});

  final int id;
  final String name;
  final int segmentCount;
  final int? firstMs;

  @override
  bool operator ==(Object other) =>
      other is MeetingSpeaker &&
      other.id == id &&
      other.name == name &&
      other.segmentCount == segmentCount &&
      other.firstMs == firstMs;

  @override
  int get hashCode => Object.hash(id, name, segmentCount, firstMs);
}

class MeetingDetail {
  const MeetingDetail({
    required this.id,
    required this.start,
    this.end,
    required this.durationS,
    required this.status,
    this.transcript,
    this.summary,
    this.segments = const [],
    this.speakers = const [],
  });

  final int id;
  final String start;
  final String? end;
  final int durationS;
  final String status;
  final String? transcript;
  final String? summary;
  final List<MeetingSegment> segments;
  final List<MeetingSpeaker> speakers;
}
