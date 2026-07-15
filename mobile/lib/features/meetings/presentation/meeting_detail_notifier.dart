import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/meetings_repository.dart';
import '../domain/meeting_detail.dart';
import 'meetings_notifier.dart' show meetingsRepositoryProvider;

/// One meeting's detail screen state.
class MeetingDetailUiState {
  const MeetingDetailUiState({this.detail, this.loading = true, this.error});

  final MeetingDetail? detail;
  final bool loading;
  final String? error;

  MeetingDetailUiState copyWith({MeetingDetail? detail, bool? loading, String? error}) => MeetingDetailUiState(
        detail: detail ?? this.detail,
        loading: loading ?? this.loading,
        error: error,
      );
}

/// Manages one meeting's detail lifecycle. ONE notifier class, instantiated
/// per meeting id via [meetingDetailNotifierProvider]'s family (same
/// pattern as `GraphNodeNotifier`'s per-node family).
class MeetingDetailNotifier extends Notifier<MeetingDetailUiState> {
  MeetingDetailNotifier(this.meetingId);

  final int meetingId;

  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial load deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  MeetingDetailUiState build() {
    _bootstrapFuture = _load();
    return const MeetingDetailUiState();
  }

  Future<void> _load() async {
    try {
      final detail = await ref.read(meetingsRepositoryProvider).detail(meetingId);
      state = state.copyWith(detail: detail, loading: false, error: null);
    } on MeetingsException catch (error) {
      state = state.copyWith(loading: false, error: error.message);
    } catch (error) {
      state = state.copyWith(loading: false, error: 'No se pudo cargar la reunión: $error');
    }
  }

  Future<void> refresh() => _load();
}

final meetingDetailNotifierProvider = NotifierProvider.family<MeetingDetailNotifier, MeetingDetailUiState, int>(
  MeetingDetailNotifier.new,
);
