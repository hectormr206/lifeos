import '../../../core/graph/graph_records.dart';

/// How a LOCAL reminder repeats. Slice C2 covers the laptop's most-used
/// recurrence ("todos los días a las 7"); weekly/cron parity is a later slice.
enum ReminderRecurrence { none, daily }

/// Lifecycle of a LOCAL reminder:
///   * [pending]  — scheduled, its notification has not fired yet.
///   * [fired]    — its due instant passed (the notification fired, or would
///     have); still visible so the user can complete/delete it.
///   * [done]     — the user marked it done. Hidden from the default list.
///   * [disabled] — the user turned it OFF without deleting it: the row stays
///     (still visible so it can be re-enabled) but its scheduled notification
///     is cancelled. Re-enabling returns it to [pending] and reschedules.
enum LocalReminderStatus { pending, fired, done, disabled }

/// A reminder created AND stored ON-DEVICE (roadmap slice C2 — laptop
/// parity for `lifeos_reminders` without a paired engine).
///
/// Persisted in the local graph as a node `kind: 'reminder'` under the
/// `'lifeos-events'` graph domain (the A3 convention: the product domain
/// 'calendar' is stored as 'lifeos-events' for wire-compat with the laptop
/// graph). Distinct from [ReminderModel] in `reminder.dart`, which is the
/// read-only VIEWER row fetched from the paired engine.
class LocalReminder {
  const LocalReminder({
    required this.uuid,
    required this.text,
    required this.dueAt,
    this.recurrence = ReminderRecurrence.none,
    this.status = LocalReminderStatus.pending,
  });

  /// The graph node's stable uuid — also the key the notification id is
  /// derived from (see [notificationId]).
  final String uuid;

  /// What to remind ("llamar al doctor").
  final String text;

  /// When to fire, DEVICE-LOCAL time. For a daily reminder this is the FIRST
  /// occurrence; the schedule then repeats at the same time every day.
  final DateTime dueAt;

  final ReminderRecurrence recurrence;
  final LocalReminderStatus status;

  /// Stable, positive 31-bit notification id derived from [uuid]. The high
  /// bit block (0x40000000) keeps it clearly out of the app's small fixed
  /// notification ids (app-update, briefing, …).
  int get notificationId => 0x40000000 | (uuid.hashCode & 0x3fffffff);

  LocalReminder copyWith({
    String? text,
    DateTime? dueAt,
    ReminderRecurrence? recurrence,
    LocalReminderStatus? status,
  }) =>
      LocalReminder(
        uuid: uuid,
        text: text ?? this.text,
        dueAt: dueAt ?? this.dueAt,
        recurrence: recurrence ?? this.recurrence,
        status: status ?? this.status,
      );

  /// Whether this reminder's alarm is currently OFF (user deactivated it).
  bool get isDisabled => status == LocalReminderStatus.disabled;

  /// The node `data` payload (A3-style: everything the row needs to round-trip,
  /// timestamps as UTC ISO-8601 strings).
  Map<String, Object?> toData() => <String, Object?>{
        'text': text,
        'dueAt': dueAt.toUtc().toIso8601String(),
        'recurrence': recurrence == ReminderRecurrence.daily ? 'daily' : null,
        'status': status.name,
      };

  /// Rebuild from a graph node. Returns null for rows that don't carry a
  /// parseable due instant (defensive: the store is shared with sync).
  static LocalReminder? fromNode(GraphNodeRecord node) {
    final rawDue = node.data['dueAt'];
    final due = rawDue is String ? DateTime.tryParse(rawDue) : node.occurredAt;
    if (due == null) return null;
    final status = LocalReminderStatus.values.asNameMap()[node.data['status']] ??
        LocalReminderStatus.pending;
    return LocalReminder(
      uuid: node.uuid,
      text: (node.data['text'] as String?) ?? node.label,
      dueAt: due.toLocal(),
      recurrence: node.data['recurrence'] == 'daily'
          ? ReminderRecurrence.daily
          : ReminderRecurrence.none,
      status: status,
    );
  }
}
