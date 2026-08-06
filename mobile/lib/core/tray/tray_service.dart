import 'package:flutter/foundation.dart';

import 'tray_controller.dart';
import 'tray_labels.dart';
import 'tray_platform.dart';
import 'tray_status.dart';

/// Signature of the failure sink. Defaults to [debugPrint] plus Flutter's own
/// error reporter; injected in tests so a deliberate failure does not have to
/// pollute the console.
typedef TrayErrorReporter = void Function(Object error, StackTrace stackTrace);

/// Owns the lifecycle of the system-tray icon, and enforces the two rules that
/// matter more than the feature itself.
///
/// RULE 1 — MOBILE IS UNTOUCHED. The injected `createController` closure is the
/// single place where `tray_manager`/`window_manager` are constructed, and on a platform without
/// a tray it is NEVER INVOKED. Not "invoked and then it fails": not invoked.
/// No channel is opened, no listener is registered, no plugin call is made.
/// (Nothing is registered natively either — neither package declares an
/// android/ios plugin platform; `tray_plugin_isolation_test.dart` asserts that
/// against the resolved plugin map rather than against a comment.)
///
/// RULE 2 — A TRAY THAT CANNOT START FAILS LOUDLY. On a desktop platform, a
/// failed install becomes a [TrayUnavailable] carrying the original exception,
/// is pushed to the error reporter, and is rendered by `TrayNotice`. The
/// app keeps running — it just never pretends the tray worked.
class TrayService {
  TrayService({
    required this.operatingSystem,
    required this._createController,
    TrayErrorReporter? reportError,
  }) : _reportError = reportError ?? _defaultReportError;

  /// Builds a service for the host this process is actually running on.
  factory TrayService.forHost({
    required TrayController Function() createController,
    TrayErrorReporter? reportError,
  }) =>
      TrayService(
        operatingSystem: currentTrayPlatform(),
        createController: createController,
        reportError: reportError,
      );

  final String operatingSystem;

  /// Named `createController` at call sites: Dart drops the leading underscore
  /// of a private initializing formal.
  final TrayController Function() _createController;
  final TrayErrorReporter _reportError;

  TrayController? _controller;
  TrayStatus _status = const TrayPending();

  /// The last outcome. `TrayPending` until [start] has run.
  TrayStatus get status => _status;

  /// Installs the tray icon, or re-labels it if one is already up.
  ///
  /// Safe to call repeatedly: the app calls it once after the first frame and
  /// again whenever the language changes. Installing twice would leave two
  /// icons in the top bar, so the second call only rebuilds the menu.
  Future<TrayStatus> start(TrayMenuLabels labels) async {
    if (!trayIsSupportedOn(operatingSystem)) {
      // Not a failure: a phone / a browser tab has no system tray by
      // definition. Silent on purpose — see [TrayNotApplicable].
      return _status = TrayNotApplicable(operatingSystem);
    }

    final existing = _controller;
    if (existing != null) {
      try {
        await existing.applyLabels(labels);
        return _status = const TrayActive();
      } catch (error, stackTrace) {
        return _status = _fail(error, stackTrace);
      }
    }

    try {
      // The ONLY construction site of the desktop tray plugins, guarded above.
      // Inside the try because the production factory resolves the icon file
      // while constructing and raises when none exists — letting that escape
      // would turn a missing icon into a crash in the caller's post-frame
      // callback instead of a visible notice.
      final controller = _createController();
      await controller.install(labels);
      _controller = controller;
      return _status = const TrayActive();
    } catch (error, stackTrace) {
      // Deliberately NOT retained: a controller that failed to install may be
      // half-wired, and keeping it would make the next start() take the
      // "already up, just re-label" path against an icon that does not exist.
      // Dropping it lets the user retry (e.g. after starting a tray host).
      return _status = _fail(error, stackTrace);
    }
  }

  /// Removes the icon. Called on app teardown so the desktop environment is
  /// not left with a ghost icon pointing at a dead process.
  Future<void> stop() async {
    final controller = _controller;
    _controller = null;
    _status = TrayNotApplicable(operatingSystem);
    if (controller == null) return;
    try {
      await controller.dispose();
    } catch (error, stackTrace) {
      // Teardown, so there is no UI left to show a banner in — but it still
      // goes to the reporter rather than to /dev/null.
      _reportError(error, stackTrace);
    }
  }

  TrayUnavailable _fail(Object error, StackTrace stackTrace) {
    _reportError(error, stackTrace);
    return TrayUnavailable(
      reason: error is TrayUnavailableException ? error.message : '$error',
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void _defaultReportError(Object error, StackTrace stackTrace) {
    // Loud on both channels: the console gets a readable line, and Flutter's
    // error reporter gets the full record so it shows up wherever the app's
    // errors are already collected.
    debugPrint('LifeOS system tray unavailable: $error');
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'lifeos/core/tray',
        context: ErrorDescription('installing the system tray icon'),
      ),
    );
  }
}
