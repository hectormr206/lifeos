import 'package:flutter_timezone/flutter_timezone.dart';

/// Reads the DEVICE's current IANA zone id (e.g. `America/Mexico_City`).
///
/// Abstracted so the effective-zone resolver depends on the interface and tests
/// inject a fake detector (returning a fixed id, or throwing to exercise the
/// detection-failure fallback) without the `flutter_timezone` platform channel.
abstract class DeviceTimezoneDetector {
  /// The device's IANA zone id, or `null` if it could not be determined.
  Future<String?> currentZoneId();
}

/// [DeviceTimezoneDetector] backed by `flutter_timezone`.
class FlutterTimezoneDetector implements DeviceTimezoneDetector {
  const FlutterTimezoneDetector();

  @override
  Future<String?> currentZoneId() async {
    try {
      final id = await FlutterTimezone.getLocalTimezone();
      return id.trim().isEmpty ? null : id.trim();
    } catch (_) {
      // No platform channel (tests) / detection error — the resolver falls back.
      return null;
    }
  }
}
