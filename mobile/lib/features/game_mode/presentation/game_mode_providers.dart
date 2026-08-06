/// Wiring for game mode: availability (from capability negotiation) and the
/// switch itself.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/api/capabilities.dart';
import '../data/game_mode_repository.dart';
import '../domain/game_mode_availability.dart';

/// The paired engine's capabilities, or null when unpaired / not yet fetched.
/// Overridden in tests and by whatever already holds this in the app.
final gameModeCapabilitiesProvider = Provider<Capabilities?>((ref) => null);

final gameModeRepositoryProvider = Provider<GameModeRepository>(
    (ref) => GameModeRepository(ref.watch(dioProvider)));

/// Whether to show the control at all.
final gameModeAvailabilityProvider = Provider<GameModeAvailability>((ref) =>
    GameModeAvailability.fromCapabilities(
        ref.watch(gameModeCapabilitiesProvider)));

class GameModeState {
  const GameModeState({
    this.active = false,
    this.busy = false,
    this.error,
  });

  final bool active;

  /// A relocation is in flight. It stops and restarts systemd units and waits
  /// for a model to load into RAM, so it is not instant and the UI must not
  /// pretend it is.
  final bool busy;

  final String? error;

  GameModeState copyWith({
    bool? active,
    bool? busy,
    String? error,
    bool clearError = false,
  }) =>
      GameModeState(
        active: active ?? this.active,
        busy: busy ?? this.busy,
        error: clearError ? null : (error ?? this.error),
      );
}

class GameModeNotifier extends Notifier<GameModeState> {
  Future<void>? _startup;

  Future<void> get ready => _startup ?? Future<void>.value();

  @override
  GameModeState build() {
    // Only ask when the engine says it applies. On a machine with no GPU there
    // is nothing to report and the control is hidden anyway.
    if (ref.watch(gameModeAvailabilityProvider).available) {
      _startup = refresh();
    }
    return const GameModeState();
  }

  /// Read the current state. NEVER changes it: the user's rule is that he
  /// activates game mode himself, so a status read with side effects would be
  /// the bug, not a convenience.
  Future<void> refresh() async {
    try {
      final active = await ref.read(gameModeRepositoryProvider).isActive();
      state = state.copyWith(active: active, clearError: true);
    } on GameModeException catch (e) {
      state = state.copyWith(error: e.message);
    } catch (_) {
      state = state.copyWith(error: 'No se pudo leer el estado del modo juego.');
    }
  }

  /// The only thing that turns it on or off, and only from an explicit tap.
  Future<void> setActive(bool active) async {
    if (state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final result = await ref.read(gameModeRepositoryProvider).setActive(active);
      state = state.copyWith(active: result, busy: false);
    } on GameModeException catch (e) {
      // Leave `active` where it was: reporting the state we WANTED rather than
      // the one the machine is in would hide a half-applied relocation.
      state = state.copyWith(busy: false, error: e.message);
    } catch (_) {
      state = state.copyWith(
        busy: false,
        error: 'No se pudo cambiar el modo juego.',
      );
    }
  }
}

final gameModeProvider =
    NotifierProvider<GameModeNotifier, GameModeState>(GameModeNotifier.new);
