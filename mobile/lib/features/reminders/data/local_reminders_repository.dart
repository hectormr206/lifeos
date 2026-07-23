import '../../../core/graph/local_graph_store.dart';
import '../domain/local_reminder.dart';

/// CRUD for LOCAL reminders over the on-device graph store (roadmap slice
/// C2). NO schema change: a reminder is a plain node (`kind: 'reminder'`,
/// graph domain `'lifeos-events'` — the A3 calendar convention) with its
/// payload in `data` ({text, dueAt, recurrence?, status}), exactly the shape
/// `LocalGraphStore` already persists. Deletes are the store's soft deletes.
class LocalRemindersRepository {
  LocalRemindersRepository(this._store);

  final LocalGraphStore _store;

  static const String nodeKind = 'reminder';

  /// A3 convention: the product domain 'calendar' is stored as
  /// 'lifeos-events' for wire-compat with the laptop graph.
  static const String graphDomain = 'lifeos-events';

  Future<LocalReminder> create({
    required String text,
    required DateTime dueAt,
    ReminderRecurrence recurrence = ReminderRecurrence.none,
  }) async {
    final reminder = LocalReminder(
      uuid: '', // assigned by the store
      text: text,
      dueAt: dueAt,
      recurrence: recurrence,
    );
    final node = await _store.createNode(
      kind: nodeKind,
      label: text,
      domain: graphDomain,
      occurredAt: dueAt,
      data: reminder.toData(),
    );
    return LocalReminder.fromNode(node)!;
  }

  /// All live local reminders, soonest due first. [includeDone] keeps the
  /// completed ones (hidden by default — parity with the laptop's pending
  /// list).
  Future<List<LocalReminder>> list({bool includeDone = false}) async {
    final nodes = await _store.listNodesByKind(nodeKind);
    final reminders = nodes
        .map(LocalReminder.fromNode)
        .whereType<LocalReminder>()
        .where((r) => includeDone || r.status != LocalReminderStatus.done)
        .toList()
      ..sort((a, b) => a.dueAt.compareTo(b.dueAt));
    return reminders;
  }

  /// Update a reminder's [status] in place (pending → fired → done). Returns
  /// the updated reminder, or null when the node no longer exists.
  Future<LocalReminder?> setStatus(String uuid, LocalReminderStatus status) async {
    final node = await _store.getNodeByUuid(uuid);
    if (node == null) return null;
    final updated = await _store.upsertNode(
      node.copyWith(data: {...node.data, 'status': status.name}),
    );
    return LocalReminder.fromNode(updated);
  }

  /// Soft-delete the reminder node (tombstone — sync-safe).
  Future<bool> delete(String uuid) => _store.softDeleteNode(uuid);
}
