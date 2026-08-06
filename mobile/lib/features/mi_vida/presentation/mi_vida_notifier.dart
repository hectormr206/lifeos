import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock/clock.dart';
import '../../../core/graph/graph_providers.dart';
import '../../daily_digest/domain/daily_digest.dart';
import '../../domains/domain/domain_descriptor.dart';
import '../../domains/domain/local_domain_entry.dart';
import '../../domains/domain/local_entry_config.dart';
import '../../domains/presentation/local_domain_notifier.dart';
import '../../memory/domain/person_directory.dart';
import '../../reminders/domain/local_reminder.dart';
import '../../reminders/presentation/local_reminders_providers.dart';
import '../domain/mi_vida_grouping.dart';

/// UI state of the unified "Mi vida" view: all domain data grouped by
/// domain + person, plus the local reminders (notifications), filtered by an
/// optional search query.
class MiVidaState {
  const MiVidaState({
    this.loading = true,
    this.error,
    this.sections = const [],
    this.reminders = const [],
    this.query = '',
  });

  final bool loading;
  final String? error;

  /// Domain → person → entries (newest first). Empty domains omitted.
  final List<DigestDomainSection> sections;

  /// Local reminders (soonest first), including disabled ones.
  final List<LocalReminder> reminders;

  final String query;

  int get totalEntries => sections.fold(0, (sum, s) => sum + s.count);

  MiVidaState copyWith({
    bool? loading,
    String? error,
    List<DigestDomainSection>? sections,
    List<LocalReminder>? reminders,
    String? query,
  }) =>
      MiVidaState(
        loading: loading ?? this.loading,
        error: error,
        sections: sections ?? this.sections,
        reminders: reminders ?? this.reminders,
        query: query ?? this.query,
      );
}

/// Aggregates the "Mi vida" surface from the on-device stores and drives its
/// edits. Reuses the existing local domain repository (CRUD + cascade delete)
/// and the local reminders service (edit / enable / delete) — no new write
/// paths.
class MiVidaNotifier extends Notifier<MiVidaState> {
  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial load deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  MiVidaState build() {
    _bootstrapFuture = _load();
    return const MiVidaState();
  }

  DateTime get _now => ref.read(clockProvider).now();

  Future<void> _load() async {
    try {
      final repo = await ref.read(localDomainRepositoryProvider.future);
      final store = await ref.read(localGraphStoreProvider.future);
      // The provider may be invalidated mid-load (e.g. a full wipe rebuilds
      // this notifier). Bail before touching `state` on a disposed Ref.
      if (!ref.mounted) return;

      final entriesByDomain = <String, List<LocalDomainEntry>>{};
      for (final descriptor in domainDescriptors) {
        entriesByDomain[descriptor.key] = await repo.list(
          descriptor.key,
          query: state.query,
        );
      }
      final directory = PersonDirectory.fromNodes(await store.listNodesByKind('person'));
      final sections = groupByDomainAndPerson(entriesByDomain, directory: directory);

      var reminders = const <LocalReminder>[];
      try {
        final service = await ref.read(localRemindersServiceProvider.future);
        reminders = await service.list(now: _now);
      } catch (_) {
        // Reminders store unavailable — show the domain data anyway.
      }

      if (!ref.mounted) return;
      state = state.copyWith(
        loading: false,
        sections: sections,
        reminders: reminders,
      );
    } catch (_) {
      if (!ref.mounted) return;
      state = state.copyWith(
        loading: false,
        error: 'No se pudo abrir la memoria local de este dispositivo.',
      );
    }
  }

  Future<void> refresh() => _bootstrapFuture = _load();

  Future<void> setQuery(String query) {
    state = state.copyWith(query: query);
    return refresh();
  }

  // ── Domain entry edit / delete (reuse LocalDomainRepository) ────────────────

  /// Edit a domain entry in place. Returns true when the node still existed.
  Future<bool> updateEntry(String uuid, LocalEntryType type, Map<String, Object?> values) async {
    try {
      final repo = await ref.read(localDomainRepositoryProvider.future);
      final updated = await repo.update(uuid, type, values);
      await refresh();
      return updated != null;
    } catch (_) {
      state = state.copyWith(error: 'No se pudo actualizar el registro.');
      return false;
    }
  }

  /// Delete a domain entry (soft-delete cascade to vectors + graph edges).
  Future<void> deleteEntry(String uuid) async {
    try {
      final repo = await ref.read(localDomainRepositoryProvider.future);
      await repo.delete(uuid);
      await refresh();
    } catch (_) {
      state = state.copyWith(error: 'No se pudo eliminar el registro.');
    }
  }

  // ── Reminder management (reuse LocalRemindersService) ───────────────────────

  Future<void> setReminderEnabled(LocalReminder reminder, bool enabled) async {
    try {
      final service = await ref.read(localRemindersServiceProvider.future);
      await service.setEnabled(reminder, enabled);
      await refresh();
    } catch (_) {
      state = state.copyWith(error: 'No se pudo actualizar el recordatorio.');
    }
  }

  Future<void> deleteReminder(LocalReminder reminder) async {
    try {
      final service = await ref.read(localRemindersServiceProvider.future);
      await service.delete(reminder);
      await refresh();
    } catch (_) {
      state = state.copyWith(error: 'No se pudo eliminar el recordatorio.');
    }
  }

  Future<void> editReminder(
    LocalReminder reminder, {
    required String text,
    required DateTime dueAt,
    ReminderRecurrence recurrence = ReminderRecurrence.none,
  }) async {
    try {
      final service = await ref.read(localRemindersServiceProvider.future);
      await service.edit(reminder, text: text, dueAt: dueAt, recurrence: recurrence);
      await refresh();
    } catch (_) {
      state = state.copyWith(error: 'No se pudo editar el recordatorio.');
    }
  }
}

final miVidaNotifierProvider =
    NotifierProvider<MiVidaNotifier, MiVidaState>(MiVidaNotifier.new);
