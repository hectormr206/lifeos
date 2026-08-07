/// The Settings toggle's state, and the port it drives.
///
/// TWO RULES, and they are the feature:
///
///   1. The state shown is the state that is REALLY on the machine. It is read
///      at build and RE-READ after every change. The user can delete
///      `~/.config/autostart/lifeos.desktop` by hand, and GNOME Tweaks/KDE can
///      switch it off behind our back; a switch that reported a remembered
///      preference would disagree with the machine and the user would believe
///      the switch.
///
///   2. A failure is shown, never swallowed. Including the nastiest one: a
///      write that reports success and changes nothing. `setEnabled` is
///      followed by a read-back, and if the truth disagrees with the request
///      the state carries the error and the switch stays where reality is.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/platform_providers.dart';
import '../../../core/tray/tray_platform.dart' show runningUnderFlutterTest;
import '../data/xdg_login_autostart.dart';
import '../domain/autostart_mechanism.dart';
import '../domain/login_autostart.dart';

/// The mechanism for this host, or `null` where none is wired.
///
/// Constructed lazily and guarded by [loginAutostartIsImplementedOn], so the
/// `dart:io` implementation is never built on Android, iOS or web — the same
/// shape as the tray's platform guard.
///
/// Note it can also be null ON Linux: `XdgLoginAutostart.forHost` throws when
/// `HOME` is unset, and a provider that threw at read time would take the
/// whole Settings screen down with it. The error is preserved in
/// [loginAutostartConstructionErrorProvider] and surfaced by the tile.
final loginAutostartPortProvider = Provider<LoginAutostart?>((ref) {
  if (!loginAutostartIsImplementedOn(ref.watch(hostOperatingSystemProvider))) {
    return null;
  }
  // The widget suite runs on a real Linux box. Without this, every test that
  // builds the Settings hub would stat the developer's own
  // `~/.config/autostart/lifeos.desktop` — the same reason the tray refuses to
  // auto-start under `flutter test`. A test that wants a mechanism injects one.
  if (runningUnderFlutterTest()) return null;
  try {
    return XdgLoginAutostart.forHost();
  } catch (_) {
    return null;
  }
});

/// Why [loginAutostartPortProvider] is null on a platform that should have had
/// one. Null when there is nothing to explain.
final loginAutostartConstructionErrorProvider = Provider<String?>((ref) {
  if (!loginAutostartIsImplementedOn(ref.watch(hostOperatingSystemProvider))) {
    return null;
  }
  if (runningUnderFlutterTest()) return null;
  try {
    XdgLoginAutostart.forHost();
    return null;
  } on LoginAutostartUnavailableException catch (e) {
    return e.message;
  } catch (e) {
    return '$e';
  }
});

@immutable
class LoginAutostartState {
  const LoginAutostartState({
    this.supported = false,
    this.enabled = false,
    this.busy = false,
    this.error,
  });

  /// Whether this build can actually register with this platform's login
  /// mechanism. False on the phones (no such concept) and false on macOS and
  /// Windows (designed, no runner in this repo yet).
  final bool supported;

  /// What is REALLY registered right now, as of the last read.
  final bool enabled;

  /// A change is in flight.
  final bool busy;

  /// Why the last read or write did not do what was asked. Shown to the user.
  final String? error;

  LoginAutostartState copyWith({
    bool? supported,
    bool? enabled,
    bool? busy,
    String? error,
    bool clearError = false,
  }) =>
      LoginAutostartState(
        supported: supported ?? this.supported,
        enabled: enabled ?? this.enabled,
        busy: busy ?? this.busy,
        error: clearError ? null : (error ?? this.error),
      );
}

class LoginAutostartNotifier extends Notifier<LoginAutostartState> {
  Future<void>? _startup;

  /// Lets tests (and anything that needs a settled value) await the initial
  /// read deterministically instead of pumping until it happens to be done —
  /// the same affordance `DictationHotkeyNotifier.ready` provides.
  Future<void> get ready => _startup ?? Future<void>.value();

  @override
  LoginAutostartState build() {
    final os = ref.watch(hostOperatingSystemProvider);
    final supported =
        loginAutostartIsImplementedOn(os) && supportsLoginAutostart(os);
    if (!supported) {
      // Not a failure and not worth an error line: a phone has no login
      // session to attach to. The tile renders nothing at all.
      _startup = Future<void>.value();
      return const LoginAutostartState();
    }
    // Deferred by a microtask, not started inline: `_refresh` writes `state`,
    // and `state` does not exist until this `build()` has returned.
    _startup = Future.microtask(_refresh);
    return const LoginAutostartState(supported: true);
  }

  /// Re-reads the machine. The only way [LoginAutostartState.enabled] is ever
  /// set.
  Future<void> _refresh() async {
    final port = ref.read(loginAutostartPortProvider);
    if (port == null) {
      // A null port on a supported platform is loud ONLY when there is
      // something to say — in production that is always the case
      // (`XdgLoginAutostart.forHost` throws with a reason, which the
      // construction-error provider carries). An unexplained null means the
      // port was deliberately withheld, i.e. `flutter test`, and inventing an
      // error there would be crying wolf in ~2 000 unrelated tests.
      state = state.copyWith(
        supported: true,
        enabled: false,
        error: ref.read(loginAutostartConstructionErrorProvider),
        clearError: ref.read(loginAutostartConstructionErrorProvider) == null,
      );
      return;
    }
    try {
      state = state.copyWith(
        supported: true,
        enabled: await port.isEnabled(),
        clearError: true,
      );
    } on LoginAutostartUnavailableException catch (e) {
      state = state.copyWith(supported: true, error: e.message);
    } catch (e) {
      state = state.copyWith(
        supported: true,
        error: 'LifeOS could not read whether it starts at login: $e',
      );
    }
  }

  /// Register or unregister, then re-read the machine and show what it says.
  ///
  /// The re-read is not belt-and-braces, it is the contract: a mechanism that
  /// accepts the call and does nothing would otherwise leave the switch ON and
  /// LifeOS not starting, which is the one outcome the user could never
  /// diagnose.
  Future<void> setEnabled(bool enabled) async {
    if (!state.supported || state.busy) return;
    final port = ref.read(loginAutostartPortProvider);
    if (port == null) {
      await _refresh();
      return;
    }

    state = state.copyWith(busy: true, clearError: true);
    String? failure;
    try {
      await port.setEnabled(enabled);
    } on LoginAutostartUnavailableException catch (e) {
      failure = e.message;
    } catch (e) {
      failure = 'LifeOS could not change the login setting: $e';
    }

    // Truth first, THEN the complaint — so a failure never leaves a stale
    // "enabled" showing, and a success clears whatever went wrong last time.
    await _refresh();
    if (failure == null && state.enabled != enabled && state.error == null) {
      failure = enabled
          ? 'LifeOS did not manage to register itself to start at login, and '
              'the change did not take effect.'
          : 'LifeOS did not manage to remove its login entry, and it will '
              'keep starting at login.';
    }
    state = state.copyWith(
      busy: false,
      error: failure ?? state.error,
      clearError: failure == null && state.error == null,
    );
  }
}

final loginAutostartProvider =
    NotifierProvider<LoginAutostartNotifier, LoginAutostartState>(
        LoginAutostartNotifier.new);
