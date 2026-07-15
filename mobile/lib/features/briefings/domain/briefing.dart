/// The latest structured result of one agentic recurring reminder ("Boletín"
/// card). Shape read directly from `axi/src/axi/dashboard.py`
/// (`_briefing_to_dict`, :5784): `null` when the reminder has never fired,
/// otherwise `{title, summary, items, ok, markdown}` — `markdown` is the
/// reminder's raw `last_result` text, ready to render as-is.
class BriefingResult {
  const BriefingResult({this.title, this.summary, this.items = const [], this.ok = true, this.markdown});

  final String? title;
  final String? summary;
  final List<String> items;
  final bool ok;
  final String? markdown;

  @override
  bool operator ==(Object other) =>
      other is BriefingResult &&
      other.title == title &&
      other.summary == summary &&
      other.ok == ok &&
      other.markdown == markdown;

  @override
  int get hashCode => Object.hash(title, summary, ok, markdown);

  @override
  String toString() => 'BriefingResult(title: $title, ok: $ok)';
}

/// One row from `GET /api/v1/briefings`. Shape read directly from
/// `axi/src/axi/dashboard.py` (`_briefing_to_dict`, :5784, `api_briefings_list`,
/// :5825): `{id, message, action_prompt, recurrence, status, when_ts,
/// last_result_at, result}`. There is no per-id detail route — the detail
/// view (see `BriefingsScreen`) is rendered entirely from this same list
/// item, expanded in place.
class BriefingModel {
  const BriefingModel({
    required this.id,
    required this.message,
    required this.whenTs,
    this.actionPrompt,
    this.recurrence,
    this.status = 'pending',
    this.lastResultAt,
    this.result,
  });

  final String id;
  final String message;
  final DateTime whenTs;
  final String? actionPrompt;
  final String? recurrence;
  final String status;
  final DateTime? lastResultAt;
  final BriefingResult? result;

  @override
  bool operator ==(Object other) =>
      other is BriefingModel &&
      other.id == id &&
      other.message == message &&
      other.whenTs == whenTs &&
      other.status == status &&
      other.result == result;

  @override
  int get hashCode => Object.hash(id, message, whenTs, status, result);

  @override
  String toString() => 'BriefingModel(id: $id, message: $message, status: $status)';
}
