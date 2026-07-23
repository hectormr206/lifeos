import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/graph/graph_providers.dart';
import '../data/local_domain_repository.dart';
import '../domain/domain_descriptor.dart';
import '../domain/local_domain_entry.dart';
import '../domain/local_entry_config.dart';

/// App-wide LOCAL domain CRUD repository. Async because the encrypted graph
/// store opens lazily (same pattern as `localRemindersServiceProvider`).
/// Consumers `await ...future` and degrade to an error state when the store
/// is unavailable (plain widget test / keystore missing).
final localDomainRepositoryProvider = FutureProvider<LocalDomainRepository>((ref) async {
  final store = await ref.watch(localGraphStoreProvider.future);
  return LocalDomainRepository(store);
});

const Object _unset = Object();

/// One domain's LOCAL tab state: the filtered entries plus the active
/// filters (type chip, period, search) and — finance only — the period
/// summary tiles.
class LocalDomainUiState {
  const LocalDomainUiState({
    this.entries = const [],
    this.loading = true,
    this.error,
    this.typeFilter,
    this.period = LocalEntryPeriod.todo,
    this.query = '',
    this.summary,
  });

  final List<LocalDomainEntry> entries;
  final bool loading;
  final String? error;

  /// Active `data.type` chip, or null = "Todos" (includes untyped chat facts).
  final String? typeFilter;
  final LocalEntryPeriod period;
  final String query;

  /// Gastos/ingresos/balance for the ACTIVE PERIOD (finance descriptor only;
  /// deliberately ignores the type chip and search so the tiles always show
  /// the whole period's picture).
  final FinanceSummary? summary;

  LocalDomainUiState copyWith({
    List<LocalDomainEntry>? entries,
    bool? loading,
    String? error,
    Object? typeFilter = _unset,
    LocalEntryPeriod? period,
    String? query,
    Object? summary = _unset,
  }) =>
      LocalDomainUiState(
        entries: entries ?? this.entries,
        loading: loading ?? this.loading,
        error: error,
        typeFilter: identical(typeFilter, _unset) ? this.typeFilter : typeFilter as String?,
        period: period ?? this.period,
        query: query ?? this.query,
        summary: identical(summary, _unset) ? this.summary : summary as FinanceSummary?,
      );
}

/// ONE notifier class for all 7 domains' LOCAL tabs, instantiated per
/// [DomainDescriptor] via the provider family — mirrors `DomainNotifier`
/// (the engine viewer) and the reusable-components invariant: filters, CRUD
/// and finance summary are parameterized by descriptor + config, never
/// duplicated per domain.
class LocalDomainNotifier extends Notifier<LocalDomainUiState> {
  LocalDomainNotifier(this.descriptor);

  final DomainDescriptor descriptor;

  Future<void>? _bootstrapFuture;

  /// Deterministic await handle for tests (same convention as
  /// `DomainNotifier.ready`).
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  LocalDomainUiState build() {
    _bootstrapFuture = _load();
    return const LocalDomainUiState();
  }

  Future<void> _load() async {
    try {
      final repo = await ref.read(localDomainRepositoryProvider.future);
      final entries = await repo.list(
        descriptor.key,
        type: state.typeFilter,
        period: state.period,
        query: state.query,
      );
      // Finance tiles: full-period entries, independent of chip/search.
      FinanceSummary? summary;
      if (descriptor.key == 'finance') {
        summary = financeSummaryOf(await repo.list(descriptor.key, period: state.period));
      }
      state = state.copyWith(entries: entries, loading: false, summary: summary);
    } catch (_) {
      state = state.copyWith(
        loading: false,
        error: 'No se pudo abrir la memoria local de este teléfono.',
      );
    }
  }

  Future<void> refresh() => _bootstrapFuture = _load();

  Future<void> setTypeFilter(String? type) {
    state = state.copyWith(typeFilter: type);
    return refresh();
  }

  Future<void> setPeriod(LocalEntryPeriod period) {
    state = state.copyWith(period: period);
    return refresh();
  }

  Future<void> setQuery(String query) {
    state = state.copyWith(query: query);
    return refresh();
  }

  /// Create via the generated form's body. Returns true on success; on
  /// failure surfaces the error inline and returns false (the sheet stays
  /// open).
  Future<bool> create(LocalEntryType entryType, Map<String, Object?> values) async {
    try {
      final repo = await ref.read(localDomainRepositoryProvider.future);
      await repo.create(descriptor.key, entryType, values);
      await refresh();
      return true;
    } on LocalDomainException catch (error) {
      state = state.copyWith(error: error.message);
      return false;
    } catch (_) {
      state = state.copyWith(error: 'No se pudo guardar el registro.');
      return false;
    }
  }

  /// Edit in place (same uuid). Returns true when the node still existed.
  Future<bool> update(String uuid, LocalEntryType entryType, Map<String, Object?> values) async {
    try {
      final repo = await ref.read(localDomainRepositoryProvider.future);
      final updated = await repo.update(uuid, entryType, values);
      await refresh();
      return updated != null;
    } catch (_) {
      state = state.copyWith(error: 'No se pudo actualizar el registro.');
      return false;
    }
  }

  Future<void> delete(String uuid) async {
    try {
      final repo = await ref.read(localDomainRepositoryProvider.future);
      await repo.delete(uuid);
      await refresh();
    } catch (_) {
      state = state.copyWith(error: 'No se pudo eliminar el registro.');
    }
  }
}

final localDomainNotifierProvider =
    NotifierProvider.family<LocalDomainNotifier, LocalDomainUiState, DomainDescriptor>(
  LocalDomainNotifier.new,
);
