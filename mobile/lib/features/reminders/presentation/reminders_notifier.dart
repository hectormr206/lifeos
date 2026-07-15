import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../chat/data/chat_repository.dart';
import '../../chat/presentation/chat_notifier.dart' show chatRepositoryProvider;
import '../data/reminders_repository.dart';
import '../domain/reminder.dart';

/// Real [RemindersRepository] used app-wide; overridden with a fake in
/// tests.
final remindersRepositoryProvider =
    Provider<RemindersRepository>((ref) => HttpRemindersRepository(ref.watch(dioProvider)));

/// The reminders screen's UI state: the pending list (loading/data/error)
/// plus the NL quick-create sub-state (capturing/captureError) — mirrors
/// `DomainUiState`.
class RemindersUiState {
  const RemindersUiState({
    this.reminders = const [],
    this.loading = true,
    this.error,
    this.capturing = false,
    this.captureError,
  });

  final List<ReminderModel> reminders;
  final bool loading;
  final String? error;
  final bool capturing;
  final String? captureError;

  RemindersUiState copyWith({
    List<ReminderModel>? reminders,
    bool? loading,
    String? error,
    bool? capturing,
    String? captureError,
  }) =>
      RemindersUiState(
        reminders: reminders ?? this.reminders,
        loading: loading ?? this.loading,
        error: error,
        capturing: capturing ?? this.capturing,
        captureError: captureError,
      );
}

/// Manages the pending-reminders list + NL quick-create + "mark done"
/// lifecycle. Mirrors `DomainNotifier`'s load/refresh/capture pattern.
class RemindersNotifier extends Notifier<RemindersUiState> {
  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial load deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  RemindersUiState build() {
    _bootstrapFuture = _load();
    return const RemindersUiState();
  }

  Future<void> _load() async {
    try {
      final reminders = await ref.read(remindersRepositoryProvider).list();
      state = state.copyWith(reminders: reminders, loading: false);
    } on RemindersException catch (error) {
      state = state.copyWith(loading: false, error: error.message);
    } catch (error) {
      state = state.copyWith(loading: false, error: 'No se pudieron cargar los recordatorios: $error');
    }
  }

  Future<void> refresh() => _load();

  /// Marks a reminder done. The engine has no separate "complete" endpoint
  /// — `DELETE /api/v1/reminders/{id}` (cancel) is the only action that
  /// removes a pending reminder, so it is used here as "done".
  Future<void> markDone(String id) async {
    try {
      await ref.read(remindersRepositoryProvider).cancel(id);
      await _load();
    } on RemindersException catch (error) {
      state = state.copyWith(error: error.message);
    }
  }

  /// NL quick-create (documented decision, same as `DomainNotifier.capture`):
  /// reuses `POST /api/v1/chat/ask` — the engine's bilingual reminder
  /// parser handles phrasings like "recuérdame llamar al doctor mañana a
  /// las 3" server-side. No client-side date parsing needed.
  Future<void> capture(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    state = state.copyWith(capturing: true, captureError: null);
    try {
      await ref.read(chatRepositoryProvider).sendMessage(trimmed);
      state = state.copyWith(capturing: false);
      await _load();
    } on ChatException catch (error) {
      state = state.copyWith(capturing: false, captureError: error.message);
    } catch (error) {
      state = state.copyWith(capturing: false, captureError: 'No se pudo capturar: $error');
    }
  }
}

final remindersNotifierProvider = NotifierProvider<RemindersNotifier, RemindersUiState>(RemindersNotifier.new);
