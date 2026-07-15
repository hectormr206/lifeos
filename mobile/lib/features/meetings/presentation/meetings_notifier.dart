import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../data/meetings_repository.dart';
import '../domain/meeting.dart';

/// Real [MeetingsRepository] used app-wide; overridden with a fake in tests.
/// Wired with the offline read cache + connectivity reporter (M3 slice 1
/// pattern).
final meetingsRepositoryProvider = Provider<MeetingsRepository>((ref) => HttpMeetingsRepository(
      ref.watch(dioProvider),
      cache: ref.watch(responseCacheProvider),
      connectivity: ref.watch(connectivityStatusProvider.notifier),
    ));

/// The meetings list screen's UI state.
class MeetingsUiState {
  const MeetingsUiState({this.meetings = const [], this.loading = true, this.error});

  final List<MeetingModel> meetings;
  final bool loading;
  final String? error;

  MeetingsUiState copyWith({List<MeetingModel>? meetings, bool? loading, String? error}) => MeetingsUiState(
        meetings: meetings ?? this.meetings,
        loading: loading ?? this.loading,
        error: error,
      );
}

/// Manages the meetings list lifecycle. Read-only: mirrors
/// `BriefingsNotifier`'s load/refresh pattern, no capture (the phone is not
/// the recorder in v1).
class MeetingsNotifier extends Notifier<MeetingsUiState> {
  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial load deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  MeetingsUiState build() {
    _bootstrapFuture = _load();
    return const MeetingsUiState();
  }

  Future<void> _load() async {
    try {
      final meetings = await ref.read(meetingsRepositoryProvider).list();
      state = state.copyWith(meetings: meetings, loading: false);
    } on MeetingsException catch (error) {
      state = state.copyWith(loading: false, error: error.message);
    } catch (error) {
      state = state.copyWith(loading: false, error: 'No se pudieron cargar las reuniones: $error');
    }
  }

  Future<void> refresh() => _load();
}

final meetingsNotifierProvider = NotifierProvider<MeetingsNotifier, MeetingsUiState>(MeetingsNotifier.new);
