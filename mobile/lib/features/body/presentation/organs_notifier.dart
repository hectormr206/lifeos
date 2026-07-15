import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../data/organs_repository.dart';
import '../domain/organ.dart';

/// Real [OrgansRepository] used app-wide; overridden with a fake in tests.
/// Wired with the offline read cache + connectivity reporter (M3 slice 1).
final organsRepositoryProvider = Provider<OrgansRepository>((ref) => HttpOrgansRepository(
      ref.watch(dioProvider),
      cache: ref.watch(responseCacheProvider),
      connectivity: ref.watch(connectivityStatusProvider.notifier),
    ));

/// The body screen's UI state: the organ list (loading/data/error).
class OrgansUiState {
  const OrgansUiState({this.organs = const [], this.loading = true, this.error});

  final List<OrganState> organs;
  final bool loading;
  final String? error;

  OrgansUiState copyWith({List<OrganState>? organs, bool? loading, String? error}) => OrgansUiState(
        organs: organs ?? this.organs,
        loading: loading ?? this.loading,
        error: error,
      );
}

/// Manages the organ list lifecycle ("Axi's body" — the visible-soul slice).
/// Read-only: mirrors `DomainNotifier`'s load/refresh pattern, no capture.
class OrgansNotifier extends Notifier<OrgansUiState> {
  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial load deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  OrgansUiState build() {
    _bootstrapFuture = _load();
    return const OrgansUiState();
  }

  Future<void> _load() async {
    try {
      final organs = await ref.read(organsRepositoryProvider).list();
      state = state.copyWith(organs: organs, loading: false);
    } on OrgansException catch (error) {
      state = state.copyWith(loading: false, error: error.message);
    } catch (error) {
      state = state.copyWith(loading: false, error: 'No se pudo leer el cuerpo de Axi: $error');
    }
  }

  Future<void> refresh() => _load();
}

final organsNotifierProvider = NotifierProvider<OrgansNotifier, OrgansUiState>(OrgansNotifier.new);
