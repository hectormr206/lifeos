import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock/clock.dart';
import '../domain/local_reminder.dart';
import '../domain/reminder_parser.dart';
import 'local_reminders_providers.dart';

/// UI state of the LOCAL reminders tab (roadmap slice C2).
class LocalRemindersUiState {
  const LocalRemindersUiState({
    this.reminders = const [],
    this.loading = true,
    this.error,
  });

  final List<LocalReminder> reminders;
  final bool loading;
  final String? error;

  LocalRemindersUiState copyWith({
    List<LocalReminder>? reminders,
    bool? loading,
    String? error,
  }) =>
      LocalRemindersUiState(
        reminders: reminders ?? this.reminders,
        loading: loading ?? this.loading,
        error: error,
      );
}

/// Manages the LOCAL reminders list: load (+ re-arm pending alarms), NL or
/// picker create, complete, delete. Mirrors `RemindersNotifier`'s
/// load/refresh shape but is fully on-device — no pairing required.
class LocalRemindersNotifier extends Notifier<LocalRemindersUiState> {
  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial load deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  LocalRemindersUiState build() {
    _bootstrapFuture = _load(rearm: true);
    return const LocalRemindersUiState();
  }

  DateTime get _now => ref.read(clockProvider).now();

  Future<void> _load({bool rearm = false}) async {
    try {
      final service = await ref.read(localRemindersServiceProvider.future);
      // Alarms don't survive reboots: re-arm everything pending on first load.
      if (rearm) await service.reschedulePending(now: _now);
      final reminders = await service.list(now: _now);
      state = state.copyWith(reminders: reminders, loading: false);
    } catch (_) {
      // TODO(i18n): hardcoded neutral Spanish pending the i18n sweep of the
      // reminders screens.
      state = state.copyWith(
        loading: false,
        error: 'No se pudieron cargar los recordatorios locales.',
      );
    }
  }

  Future<void> refresh() => _load();

  /// Parse [text] against the device clock WITHOUT creating anything — the
  /// screen uses it to decide between direct create and the date/time picker.
  ParsedReminder? parse(String text) => parseReminder(text, now: _now);

  Future<void> create({
    required String text,
    required DateTime dueAt,
    ReminderRecurrence recurrence = ReminderRecurrence.none,
  }) async {
    try {
      final service = await ref.read(localRemindersServiceProvider.future);
      await service.create(text: text, dueAt: dueAt, recurrence: recurrence);
      await _load();
    } catch (_) {
      state = state.copyWith(error: 'No se pudo crear el recordatorio.');
    }
  }

  Future<void> complete(LocalReminder reminder) async {
    try {
      final service = await ref.read(localRemindersServiceProvider.future);
      await service.complete(reminder);
      await _load();
    } catch (_) {
      state = state.copyWith(error: 'No se pudo completar el recordatorio.');
    }
  }

  Future<void> remove(LocalReminder reminder) async {
    try {
      final service = await ref.read(localRemindersServiceProvider.future);
      await service.delete(reminder);
      await _load();
    } catch (_) {
      state = state.copyWith(error: 'No se pudo eliminar el recordatorio.');
    }
  }
}

final localRemindersNotifierProvider =
    NotifierProvider<LocalRemindersNotifier, LocalRemindersUiState>(
        LocalRemindersNotifier.new);
