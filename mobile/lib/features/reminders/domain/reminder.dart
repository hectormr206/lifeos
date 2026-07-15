/// One row from `GET /api/v1/reminders`. Shape read directly from
/// `axi/src/axi/dashboard.py` (`_reminder_to_dict`, :5764): `{id, when_ts,
/// message, channel, status, created_at, fired_at, error, recurrence,
/// last_fired_at, ends_at, occurrences_left, action_kind, action_prompt,
/// last_result_at}`. Only the fields the reminders list/create UI needs are
/// promoted to named properties; the rest lives in [raw] (same pattern as
/// `DomainEntry`).
class ReminderModel {
  const ReminderModel({
    required this.id,
    required this.whenTs,
    required this.message,
    required this.status,
    this.channel = 'push',
    this.raw = const {},
  });

  final String id;
  final DateTime whenTs;
  final String message;

  /// Engine-defined lifecycle value (`lifeos_reminders.Reminder.status`) —
  /// rendered as-is, not re-labelled client-side, to avoid drifting from
  /// the engine's actual state machine.
  final String status;

  final String channel;

  final Map<String, Object?> raw;

  @override
  bool operator ==(Object other) =>
      other is ReminderModel &&
      other.id == id &&
      other.whenTs == whenTs &&
      other.message == message &&
      other.status == status;

  @override
  int get hashCode => Object.hash(id, whenTs, message, status);

  @override
  String toString() => 'ReminderModel(id: $id, message: $message, status: $status)';
}
