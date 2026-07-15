import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../data/briefings_repository.dart';
import '../domain/briefing.dart';

/// Real [BriefingsRepository] used app-wide; overridden with a fake in
/// tests. Wired with the offline read cache + connectivity reporter (M3
/// slice 1 pattern).
final briefingsRepositoryProvider = Provider<BriefingsRepository>((ref) => HttpBriefingsRepository(
      ref.watch(dioProvider),
      cache: ref.watch(responseCacheProvider),
      connectivity: ref.watch(connectivityStatusProvider.notifier),
    ));

/// The Boletines screen's UI state: the briefing list (loading/data/error).
class BriefingsUiState {
  const BriefingsUiState({this.briefings = const [], this.loading = true, this.error});

  final List<BriefingModel> briefings;
  final bool loading;
  final String? error;

  BriefingsUiState copyWith({List<BriefingModel>? briefings, bool? loading, String? error}) => BriefingsUiState(
        briefings: briefings ?? this.briefings,
        loading: loading ?? this.loading,
        error: error,
      );
}

/// Manages the Boletines list lifecycle. Read-only: mirrors
/// `OrgansNotifier`'s load/refresh pattern, no capture.
class BriefingsNotifier extends Notifier<BriefingsUiState> {
  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial load deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  BriefingsUiState build() {
    _bootstrapFuture = _load();
    return const BriefingsUiState();
  }

  Future<void> _load() async {
    try {
      final briefings = await ref.read(briefingsRepositoryProvider).list();
      state = state.copyWith(briefings: briefings, loading: false);
    } on BriefingsException catch (error) {
      state = state.copyWith(loading: false, error: error.message);
    } catch (error) {
      state = state.copyWith(loading: false, error: 'No se pudieron cargar los boletines: $error');
    }
  }

  Future<void> refresh() => _load();
}

final briefingsNotifierProvider = NotifierProvider<BriefingsNotifier, BriefingsUiState>(BriefingsNotifier.new);
