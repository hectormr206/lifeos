import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A small seam over "what time is it now", so callers never reach for
/// [DateTime.now] directly.
///
/// Today the only implementation is [SystemClock] (the device's local clock).
/// A FUTURE user-configurable-timezone slice can drop in a different [Clock]
/// (e.g. one that applies a stored UTC offset / IANA zone) and override
/// [clockProvider] alone — every consumer (Axi's prompt datetime, etc.) picks
/// up the change with no further edits. Tests inject a fixed clock the same way.
abstract class Clock {
  /// The current instant. [SystemClock] returns the DEVICE LOCAL time.
  DateTime now();
}

/// [Clock] backed by the device's local clock ([DateTime.now]).
class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

/// The app-wide [Clock]. Defaults to the device local clock; the timezone
/// slice (and tests) override this provider to change "now" everywhere.
final clockProvider = Provider<Clock>((ref) => const SystemClock());
