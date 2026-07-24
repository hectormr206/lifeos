import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'device_timezone.dart';
import 'effective_timezone.dart';
import 'timezone_preference.dart';

/// Local-only persistence of the timezone choice. Overridden with a fake in
/// tests.
final timezonePreferencesProvider =
    Provider<TimezonePreferences>((ref) => SharedPrefsTimezonePreferences());

/// Device IANA-zone detector (`flutter_timezone`). Overridden with a fake in
/// tests.
final deviceTimezoneDetectorProvider =
    Provider<DeviceTimezoneDetector>((ref) => const FlutterTimezoneDetector());

/// Resolver that turns the preference + detected device zone into an effective
/// [tz.Location].
final effectiveTimezoneResolverProvider = Provider<EffectiveTimezoneResolver>(
  (ref) => EffectiveTimezoneResolver(
    ref.watch(timezonePreferencesProvider),
    ref.watch(deviceTimezoneDetectorProvider),
  ),
);

/// The current [EffectiveTimezone]. Async because device detection crosses a
/// platform channel. Consumers `await ...future` and degrade gracefully (a
/// failed read means AUTOMATIC/device-local, unchanged behavior).
///
/// Re-armed schedules read this AFTER the timezone setting changes; the settings
/// notifier `ref.invalidate`s it so the next read reflects the new choice.
final effectiveTimezoneProvider =
    FutureProvider<EffectiveTimezone>((ref) => ref.watch(effectiveTimezoneResolverProvider).resolve());
