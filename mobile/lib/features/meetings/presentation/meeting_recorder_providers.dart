/// Wiring for "Iniciar reunión": availability, live state, and the button.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../home/presentation/home_providers.dart';
import '../data/meeting_recorder_repository.dart';

final meetingRecorderRepositoryProvider = Provider<MeetingRecorderRepository>(
    (ref) => MeetingRecorderRepository(ref.watch(dioProvider)));

/// Whether the paired engine can record a meeting at all.
///
/// Negotiated, not assumed. Recording needs the microphone, the system-audio
/// monitor and the screen OF THE MACHINE THE MEETING IS ON — a property of the
/// engine, not of this app. Where it is false the control is ABSENT, so a phone
/// paired to a laptop that is not in the room never offers a button that would
/// record the wrong place.
final meetingRecorderAvailableProvider = Provider<bool>((ref) {
  final capabilities = ref.watch(engineCapabilitiesProvider).value;
  final entry = capabilities?.capabilities['meetingRecorder'];
  final available = entry?.extra['available'];
  return available is bool && available;
});

class MeetingRecorderState {
  const MeetingRecorderState({
    this.active = false,
    this.meetingId,
    this.detail = '',
    this.busy = false,
    this.error,
  });

  final bool active;
  final int? meetingId;

  /// The engine's own status line — it carries the elapsed time, which is what
  /// someone recording actually looks at.
  final String detail;

  /// A start or stop is in flight. Stopping flushes the ffmpeg pipelines and
  /// closes the segment before answering, so it is not instant.
  final bool busy;

  final String? error;

  MeetingRecorderState copyWith({
    bool? active,
    int? meetingId,
    String? detail,
    bool? busy,
    String? error,
    bool clearError = false,
  }) =>
      MeetingRecorderState(
        active: active ?? this.active,
        meetingId: meetingId ?? this.meetingId,
        detail: detail ?? this.detail,
        busy: busy ?? this.busy,
        error: clearError ? null : (error ?? this.error),
      );
}

class MeetingRecorderNotifier extends Notifier<MeetingRecorderState> {
  Future<void>? _startup;

  Future<void> get ready => _startup ?? Future<void>.value();

  @override
  MeetingRecorderState build() {
    if (ref.watch(meetingRecorderAvailableProvider)) {
      _startup = refresh();
    }
    return const MeetingRecorderState();
  }

  /// Read the live state. Starts nothing: a meeting that began on its own
  /// would be recording a room nobody agreed to record.
  Future<void> refresh() async {
    try {
      final state0 = await ref.read(meetingRecorderRepositoryProvider).status();
      state = state.copyWith(
        active: state0.active,
        meetingId: state0.meetingId,
        detail: state0.detail,
        clearError: true,
      );
    } on MeetingRecorderException catch (e) {
      state = state.copyWith(error: e.message);
    } catch (_) {
      state = state.copyWith(error: 'No se pudo leer el estado de la reunión.');
    }
  }

  /// The only thing that starts or stops a recording, and only from a tap.
  Future<void> setActive(bool active) async {
    if (state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final result =
          await ref.read(meetingRecorderRepositoryProvider).setActive(active);
      state = state.copyWith(
        active: result.active,
        meetingId: result.meetingId,
        detail: result.detail,
        busy: false,
      );
    } on MeetingRecorderException catch (e) {
      // `active` stays where it was. Claiming a meeting is recording when the
      // engine refused — a full disk is a real refusal — is the one failure
      // that loses a whole conversation.
      state = state.copyWith(busy: false, error: e.message);
    } catch (_) {
      state = state.copyWith(
          busy: false, error: 'No se pudo cambiar el estado de la reunión.');
    }
  }
}

final meetingRecorderProvider =
    NotifierProvider<MeetingRecorderNotifier, MeetingRecorderState>(
        MeetingRecorderNotifier.new);
