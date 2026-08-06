import 'package:flutter/foundation.dart';

/// What the system tray is currently doing, as a value the UI can render.
///
/// The reason this is a status and not a `bool` — or nothing at all — is the
/// house rule: a feature that cannot start must fail LOUDLY. A tray that
/// silently did not appear looks identical to a tray the user simply has not
/// noticed, so the failure has to become visible state that a widget can show.
@immutable
sealed class TrayStatus {
  const TrayStatus();
}

/// Nothing has been attempted yet (app start, before the first frame).
class TrayPending extends TrayStatus {
  const TrayPending();
}

/// This platform has no system tray, and that is not a fault: Android, iOS and
/// web. Renders NOTHING — telling a phone user his tray is missing would be
/// crying wolf on every launch.
class TrayNotApplicable extends TrayStatus {
  const TrayNotApplicable(this.operatingSystem);

  final String operatingSystem;
}

/// The icon is in the tray.
class TrayActive extends TrayStatus {
  const TrayActive();
}

/// A platform that SHOULD have had a tray did not get one. This is the loud
/// case: the app keeps running, and the UI says so out loud.
///
/// [error] and [stackTrace] are retained deliberately — discarding them is
/// exactly the quiet degradation this class exists to prevent.
class TrayUnavailable extends TrayStatus {
  const TrayUnavailable({
    required this.reason,
    required this.error,
    required this.stackTrace,
  });

  /// Human-readable explanation, safe to show in the UI.
  final String reason;

  /// The original thrown object, untouched.
  final Object error;

  final StackTrace stackTrace;
}
