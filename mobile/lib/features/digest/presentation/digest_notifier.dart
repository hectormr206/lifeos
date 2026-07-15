import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../data/digest_repository.dart';
import '../domain/today_digest.dart';

/// Real [DigestRepository] used app-wide; overridden with a fake in tests.
/// Wired with the offline read cache + connectivity reporter (M3 slice 1
/// pattern).
final digestRepositoryProvider = Provider<DigestRepository>((ref) => HttpDigestRepository(
      ref.watch(dioProvider),
      cache: ref.watch(responseCacheProvider),
      connectivity: ref.watch(connectivityStatusProvider.notifier),
    ));

/// The "Resumen de hoy" screen's UI state: today's digest (loading/data/error).
class DigestUiState {
  const DigestUiState({this.digest, this.loading = true, this.error});

  final TodayDigest? digest;
  final bool loading;
  final String? error;

  DigestUiState copyWith({TodayDigest? digest, bool? loading, String? error}) => DigestUiState(
        digest: digest ?? this.digest,
        loading: loading ?? this.loading,
        error: error,
      );
}

/// Manages today's smart digest lifecycle. Read-only: mirrors
/// `OrgansNotifier`'s load/refresh pattern, no capture.
class DigestNotifier extends Notifier<DigestUiState> {
  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial load deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  DigestUiState build() {
    _bootstrapFuture = _load();
    return const DigestUiState();
  }

  Future<void> _load() async {
    try {
      final digest = await ref.read(digestRepositoryProvider).today();
      state = state.copyWith(digest: digest, loading: false);
    } on DigestException catch (error) {
      state = state.copyWith(loading: false, error: error.message);
    } catch (error) {
      state = state.copyWith(loading: false, error: 'No se pudo generar el resumen de hoy: $error');
    }
  }

  Future<void> refresh() => _load();
}

final digestNotifierProvider = NotifierProvider<DigestNotifier, DigestUiState>(DigestNotifier.new);
