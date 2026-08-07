/// Registering LifeOS to start when the user logs in.
///
/// Split from the pure value builders in `autostart_entry.dart` for the same
/// reason `global_hotkey_binder.dart` is split from `dictation_hotkey.dart`:
/// this is the only part that touches the machine, and everything else — the
/// file contents, the paths, the version rule, the settings UI — must be
/// provable without one.
///
/// WHY IT FAILS LOUDLY. Every failure mode here is invisible by nature. A
/// login entry that was never written, or was written for a path that no
/// longer exists, produces exactly one symptom: months later the user notices
/// LifeOS is not running, with nothing logged anywhere to connect it to. So
/// there is no best-effort path in this feature. Anything that cannot be done
/// is thrown, carried to the Settings toggle, and shown.
library;

/// Thrown when login autostart cannot be read or changed. Carries a message
/// meant for the user, not a stack trace.
class LoginAutostartUnavailableException implements Exception {
  const LoginAutostartUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The port. One implementation today (`XdgLoginAutostart`, Linux).
abstract class LoginAutostart {
  /// Whether LifeOS is registered to start at login, read from the SYSTEM —
  /// never from a remembered preference.
  ///
  /// The user can delete the file by hand, and desktop environments have their
  /// own autostart panels that switch it off behind our back. A cached answer
  /// would make the Settings switch disagree with the machine, and the user
  /// would believe the switch.
  ///
  /// Throws [LoginAutostartUnavailableException] when the state cannot be
  /// determined. Answering "off" in that case would be a lie the user acts on.
  Future<bool> isEnabled();

  /// Register or unregister. Throws [LoginAutostartUnavailableException] with
  /// a message the user can act on if it could not be done — including the
  /// case where the call appeared to succeed but changed nothing.
  Future<void> setEnabled(bool enabled);
}
