import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../../../core/outbox/outbox.dart';
import '../../chat/data/chat_repository.dart';
import '../../chat/presentation/chat_notifier.dart' show chatRepositoryProvider;
import '../data/domain_repository.dart';
import '../domain/domain_descriptor.dart';
import '../domain/domain_entry.dart';

/// Real [DomainRepository] used app-wide; overridden with a fake in tests.
/// Wired with the offline read cache + connectivity reporter (M3 slice 1)
/// and the offline write outbox + pending-sync reporter (M3 slice 2, same
/// wiring as `settingsRepositoryProvider`) for structured create (spec
/// structured-domain-forms).
final domainRepositoryProvider = Provider<DomainRepository>((ref) => HttpDomainRepository(
      ref.watch(dioProvider),
      cache: ref.watch(responseCacheProvider),
      connectivity: ref.watch(connectivityStatusProvider.notifier),
      outbox: ref.watch(outboxProvider),
      pendingSync: ref.watch(pendingSyncCountProvider.notifier),
    ));

/// One domain screen's UI state: the list (loading/data/error) plus the
/// NL quick-capture sub-state (capturing/captureError).
class DomainUiState {
  const DomainUiState({
    this.entries = const [],
    this.loading = true,
    this.error,
    this.capturing = false,
    this.captureError,
    this.creating = false,
    this.createError,
  });

  final List<DomainEntry> entries;
  final bool loading;
  final String? error;
  final bool capturing;
  final String? captureError;

  /// Structured create-form sub-state (spec structured-domain-forms) —
  /// mirrors `capturing`/`captureError`'s shape for the NL quick-capture bar.
  final bool creating;
  final String? createError;

  DomainUiState copyWith({
    List<DomainEntry>? entries,
    bool? loading,
    String? error,
    bool? capturing,
    String? captureError,
    bool? creating,
    String? createError,
  }) =>
      DomainUiState(
        entries: entries ?? this.entries,
        loading: loading ?? this.loading,
        error: error,
        capturing: capturing ?? this.capturing,
        captureError: captureError,
        creating: creating ?? this.creating,
        createError: createError,
      );
}

/// Manages one domain's list + NL quick-capture lifecycle (spec
/// `mobile-domain-crud`). ONE notifier class, instantiated per
/// [DomainDescriptor] via [domainNotifierProvider]'s family — health,
/// finance and exercise (soon all 7 domains) share this exact code.
class DomainNotifier extends Notifier<DomainUiState> {
  DomainNotifier(this.descriptor);

  final DomainDescriptor descriptor;

  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial load deterministically, mirroring
  /// `ChatNotifier.ready`/`ConnectionNotifier.ready`.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  DomainUiState build() {
    _bootstrapFuture = _load();
    return const DomainUiState();
  }

  /// NOTE: deliberately does NOT synchronously set `state = ...loading: true`
  /// before the first `await` — `build()` calls this while the provider is
  /// still being constructed, and mutating `state` before `build()` returns
  /// throws riverpod's "Tried to read the state of an uninitialized
  /// provider". `build()`'s returned default (`loading: true`) already
  /// covers the initial case; `refresh()` intentionally leaves the previous
  /// entries/error visible until the new result lands (RefreshIndicator's
  /// own pull animation is the loading affordance for that path).
  Future<void> _load() async {
    try {
      final entries = await ref.read(domainRepositoryProvider).list(descriptor);
      state = state.copyWith(entries: entries, loading: false);
    } on DomainException catch (error) {
      state = state.copyWith(loading: false, error: error.message);
    } catch (error) {
      state = state.copyWith(loading: false, error: 'No se pudieron cargar los registros: $error');
    }
  }

  Future<void> refresh() => _load();

  /// NL quick-capture (documented decision, spec `mobile-domain-crud`
  /// follow-up): reuses the SAME `POST /api/v1/chat/ask` endpoint and
  /// [ChatRepository] the chat feature already talks to. The engine's
  /// existing autoroute/regex extraction ("presión 120/80", "gasté 500 en
  /// el súper", "salí a correr 5km", "mi esposa tuvo 96 pulsos") does the
  /// domain + field parsing server-side — no new engine endpoint or
  /// client-side parsing is needed for this slice. Structured per-field
  /// create forms (`POST .../entries` with typed bodies) are a later slice.
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

  /// Structured create (spec structured-domain-forms): POSTs [body] (built
  /// by `buildDomainEntryBody` from the domain's `DomainEntryForm`) via the
  /// repository, then prepends the resulting entry to the list — the
  /// repository already handles the offline-enqueue path (returning a
  /// best-effort local entry instead of throwing), so this optimistic
  /// prepend covers both the online AND offline-queued cases the same way.
  /// Returns `true` on success (including offline-enqueued), `false` on a
  /// definite rejection from the engine (see [DomainUiState.createError]).
  Future<bool> createEntry(Map<String, Object?> body) async {
    state = state.copyWith(creating: true, createError: null);
    try {
      final entry = await ref.read(domainRepositoryProvider).createEntry(descriptor, body);
      state = state.copyWith(creating: false, entries: [entry, ...state.entries]);
      return true;
    } on DomainException catch (error) {
      state = state.copyWith(creating: false, createError: error.message);
      return false;
    } catch (error) {
      state = state.copyWith(creating: false, createError: 'No se pudo guardar: $error');
      return false;
    }
  }
}

final domainNotifierProvider = NotifierProvider.family<DomainNotifier, DomainUiState, DomainDescriptor>(
  DomainNotifier.new,
);
