/// Whether the "Modo juego" control should exist on this setup.
///
/// Game mode frees the GPU by relocating Whisper and the llama co-pilot to
/// CPU/RAM so a demanding game gets the whole card. On a machine with no GPU
/// there is nothing to relocate, so the user's rule applies: "si todo está en
/// CPU y RAM entonces no nos sirve el modo juego y lo ocultamos." Absent, not
/// greyed out — the same rule the tray, permissions and update screens follow.
///
/// THE ENGINE DECIDES, NOT THE APP. The app runs on the Pixel as often as on
/// the laptop, and the phone has no way to know what card the paired engine
/// has. Even on the laptop the answer belongs to whoever owns the inference
/// services. So availability arrives through capability negotiation
/// (`GET /api/v1/capabilities` → `capabilities.gameMode`), which is also what
/// makes an engine too old to know about game mode degrade correctly: no
/// capability, no control, rather than a button that 404s.
library;

import '../../../core/api/capabilities.dart';

class GameModeAvailability {
  const GameModeAvailability({
    required this.available,
    this.gpuName,
    this.totalVramMb,
    this.reason = '',
  });

  /// The safe answer for every uncertain case: unpaired, an old engine, a
  /// malformed payload. Hiding a control that would fail on tap is strictly
  /// better than offering it hopefully.
  static const GameModeAvailability unavailable =
      GameModeAvailability(available: false);

  final bool available;
  final String? gpuName;
  final int? totalVramMb;

  /// Why it is unavailable. Not shown where the control is hidden — it exists
  /// so "¿por qué no me aparece?" is answerable without reading source.
  final String reason;

  factory GameModeAvailability.fromCapabilities(Capabilities? capabilities) {
    final entry = capabilities?.capabilities['gameMode'];
    if (entry == null) return unavailable;

    final extra = entry.extra;
    // `is bool` rather than `== true` on a dynamic: the engine is a separate
    // process on a separate machine, and its payload is not something this app
    // may assume well-formed.
    final flag = extra['available'];
    if (flag is! bool || !flag) {
      return GameModeAvailability(
        available: false,
        reason: extra['reason'] is String ? extra['reason'] as String : '',
      );
    }

    final gpu = extra['gpu'];
    if (gpu is! Map) {
      // Contradictory payload: available, but no card reported. Believing the
      // flag would show a control that frees nothing.
      return unavailable;
    }
    final total = gpu['total_mb'];
    return GameModeAvailability(
      available: true,
      gpuName: gpu['name'] is String ? gpu['name'] as String : null,
      totalVramMb: total is int ? total : null,
      reason: '',
    );
  }

  /// e.g. `NVIDIA GeForce RTX 5070 Ti · 12 GB`, or null when the engine did not
  /// name the card.
  String? get gpuLabel {
    if (gpuName == null) return null;
    if (totalVramMb == null) return gpuName;
    final gb = (totalVramMb! / 1024).round();
    return '$gpuName · $gb GB';
  }
}
