/// What the process was asked to do on the command line.
///
/// WHY THIS EXISTS. LifeOS can register itself to start at login (see
/// `features/autostart/`). An app that starts itself and then throws a window
/// at the user has defeated the point of living in the tray — the user did not
/// ask for LifeOS, the session did. So the login entry launches it with
/// [hiddenLaunchFlag] and the window stays down until it is wanted.
///
/// Pure by design: parsing is asserted in a host test, and nothing here knows
/// what a window is. The decision of what to DO with it lives in
/// `core/window/launch_visibility.dart`.
library;

import 'package:flutter/foundation.dart';

/// The flag the autostart entry writes and this parser reads. One constant, so
/// the writer and the reader cannot drift — a drift here would be invisible
/// (the app would simply show its window at every login and nobody could say
/// why).
const String hiddenLaunchFlag = '--hidden';

/// Accepted spellings of [hiddenLaunchFlag]. Aliases only, never prefixes:
/// matching by prefix would make `--hidden-debug` silently hide the window.
const Set<String> _hiddenLaunchAliases = {
  hiddenLaunchFlag,
  '--start-hidden',
  '--start-minimized',
};

@immutable
class LaunchOptions {
  const LaunchOptions({required this.startHidden});

  /// An ordinary, user-initiated launch.
  static const LaunchOptions visible = LaunchOptions(startHidden: false);

  /// Whether the window should stay down and only the tray icon appear.
  final bool startHidden;

  /// Reads the entrypoint arguments the desktop runner handed to `main`.
  ///
  /// Unknown arguments are IGNORED rather than fatal. The applications-menu
  /// entry carries `%U`, which the desktop environment expands to zero or more
  /// URLs, and a future deep link will add more; refusing to start over an
  /// argument we do not recognise would turn a launcher detail into a dead app.
  factory LaunchOptions.parse(List<String> arguments) => LaunchOptions(
        startHidden: arguments.any(_hiddenLaunchAliases.contains),
      );

  @override
  bool operator ==(Object other) =>
      other is LaunchOptions && other.startHidden == startHidden;

  @override
  int get hashCode => startHidden.hashCode;

  @override
  String toString() => 'LaunchOptions(startHidden: $startHidden)';
}
