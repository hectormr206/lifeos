// Whether the "Modo juego" control exists at all, on THIS setup.
//
// The rule is the user's: "solo si tenemos VRAM; si todo está en CPU y RAM
// entonces no nos sirve el modo juego y lo ocultamos." Game mode works by
// moving Whisper and the llama co-pilot off the GPU so a game gets the whole
// card. With no GPU there is nothing to move, so the control must be ABSENT —
// the same product rule the tray, the permissions and the update screen follow.
//
// The engine decides, not the app. The app frequently runs on the Pixel, which
// has no way to know what card the paired laptop has; and even on the laptop,
// the answer belongs to whoever owns the inference services.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/api/capabilities.dart';
import 'package:lifeos/features/game_mode/domain/game_mode_availability.dart';

Capabilities _caps(Map<String, Object?>? gameMode) => Capabilities.fromJson({
      'api_version': '1',
      'engine_version': '0.9.19',
      'capabilities': {
        'chat': {'v': 1},
        if (gameMode != null) 'gameMode': {'v': 1, ...gameMode},
      },
    });

void main() {
  test('a GPU with VRAM means the control is offered', () {
    final availability = GameModeAvailability.fromCapabilities(_caps({
      'available': true,
      'gpu': {'name': 'NVIDIA GeForce RTX 5070 Ti', 'total_mb': 12282},
      'reason': '',
    }));

    expect(availability.available, isTrue);
    expect(availability.gpuName, 'NVIDIA GeForce RTX 5070 Ti');
    expect(availability.totalVramMb, 12282);
  });

  test('no GPU means the control is hidden, and says why', () {
    final availability = GameModeAvailability.fromCapabilities(_caps({
      'available': false,
      'gpu': null,
      'reason': 'No hay GPU con VRAM en esta máquina.',
    }));

    expect(availability.available, isFalse);
    expect(availability.reason, contains('GPU'));
  });

  test('an engine too old to know about game mode hides it', () {
    // D4's rule: a client degrades per-capability. An engine that never heard
    // of game mode cannot perform it, so the control is absent rather than a
    // button that 404s.
    final availability = GameModeAvailability.fromCapabilities(_caps(null));

    expect(availability.available, isFalse);
  });

  test('no capabilities at all — unpaired — hides it', () {
    // On a fresh install there is no engine to ask. Showing the control
    // hopefully and failing on tap is worse than not showing it.
    expect(GameModeAvailability.fromCapabilities(null).available, isFalse);
  });

  test('a malformed capability is treated as unavailable, not as a crash', () {
    // The engine is a separate process on a separate machine; its payload is
    // not something the app may assume well-formed.
    final availability = GameModeAvailability.fromCapabilities(_caps({
      'available': 'sí, claro',
      'gpu': 'no es un objeto',
    }));

    expect(availability.available, isFalse);
  });

  test('available without a usable GPU block is still unavailable', () {
    // Contradictory payload: claiming availability while reporting no card.
    // Believing the flag would show a control that frees nothing.
    final availability = GameModeAvailability.fromCapabilities(_caps({
      'available': true,
      'gpu': null,
      'reason': '',
    }));

    expect(availability.available, isFalse,
        reason: 'no GPU block means nothing to free, whatever the flag says');
  });
}
