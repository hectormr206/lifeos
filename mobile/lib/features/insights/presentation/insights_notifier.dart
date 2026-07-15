import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../data/insights_repository.dart';
import '../domain/digest.dart';

/// Real [InsightsRepository] used app-wide; overridden with a fake in
/// tests. Wired with the offline read cache + connectivity reporter (M3
/// slice 1).
final insightsRepositoryProvider = Provider<InsightsRepository>((ref) => HttpInsightsRepository(
      ref.watch(dioProvider),
      cache: ref.watch(responseCacheProvider),
      connectivity: ref.watch(connectivityStatusProvider.notifier),
    ));

/// The insights screen's UI state: the current cadence, the loaded digest
/// (nullable until first load / on error), loading and error.
class InsightsUiState {
  const InsightsUiState({this.digest, this.cadence = 'daily', this.loading = true, this.error});

  final DigestModel? digest;
  final String cadence;
  final bool loading;
  final String? error;

  InsightsUiState copyWith({DigestModel? digest, String? cadence, bool? loading, String? error}) => InsightsUiState(
        digest: digest ?? this.digest,
        cadence: cadence ?? this.cadence,
        loading: loading ?? this.loading,
        error: error,
      );
}

/// Manages the digest preview lifecycle (read-only "visible soul" slice —
/// see `InsightsRepository`'s scope note). Loads the daily digest on init;
/// `setCadence` switches between 'daily'/'weekly' and reloads.
class InsightsNotifier extends Notifier<InsightsUiState> {
  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial load deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  InsightsUiState build() {
    _bootstrapFuture = _load('daily');
    return const InsightsUiState(cadence: 'daily');
  }

  /// NOTE: deliberately does NOT synchronously mutate `state` before the
  /// first `await` — `build()` calls this while the provider is still
  /// being constructed (same constraint as `DomainNotifier._load`).
  Future<void> _load(String cadence) async {
    try {
      final digest = await ref.read(insightsRepositoryProvider).preview(cadence: cadence);
      state = state.copyWith(digest: digest, cadence: cadence, loading: false, error: null);
    } on InsightsException catch (error) {
      state = state.copyWith(cadence: cadence, loading: false, error: error.message);
    } catch (error) {
      state = state.copyWith(cadence: cadence, loading: false, error: 'No se pudo generar el resumen: $error');
    }
  }

  Future<void> refresh() => _load(state.cadence);

  Future<void> setCadence(String cadence) => _load(cadence);
}

final insightsNotifierProvider = NotifierProvider<InsightsNotifier, InsightsUiState>(InsightsNotifier.new);
