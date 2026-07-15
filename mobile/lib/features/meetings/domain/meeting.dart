/// One meeting list item. Shape read directly from
/// `axi/src/axi/dashboard.py` (`list_meetings`, `GET /api/meetings`, aliased
/// `/api/v1/meetings`): a raw JSON array (NOT wrapped in an object key) of
/// `{id, start, start_ts, end, duration_s, status, source, has_transcript,
/// has_summary}`. `start`/`end` are already server-formatted
/// ("%Y-%m-%d %H:%M", engine's own timezone via `_fmt_ts`) — rendered as-is,
/// no client-side re-formatting. Read-only in v1 (spec meetings-viewer):
/// the phone is not the recorder, just a faithful viewer.
class MeetingModel {
  const MeetingModel({
    required this.id,
    required this.start,
    required this.startTs,
    this.end,
    required this.durationS,
    required this.status,
    this.source,
    this.hasTranscript = false,
    this.hasSummary = false,
  });

  final int id;
  final String start;

  /// The raw `start_ts` (unix seconds) as a [DateTime], kept in case the UI
  /// ever needs to sort/filter — the display string is [start].
  final DateTime startTs;
  final String? end;
  final int durationS;
  final String status;
  final String? source;
  final bool hasTranscript;
  final bool hasSummary;

  @override
  bool operator ==(Object other) =>
      other is MeetingModel &&
      other.id == id &&
      other.start == start &&
      other.end == end &&
      other.durationS == durationS &&
      other.status == status &&
      other.source == source &&
      other.hasTranscript == hasTranscript &&
      other.hasSummary == hasSummary;

  @override
  int get hashCode => Object.hash(id, start, end, durationS, status, source, hasTranscript, hasSummary);

  @override
  String toString() => 'MeetingModel(id: $id, start: $start, status: $status)';
}
