import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/launch/launch_options.dart';

/// Pins the GTK runner's copy of the hidden-launch flag to the Dart one.
///
/// WHY A TEST READS A C++ FILE. `linux/runner/my_application.cc` parses the
/// same argument independently, so it can skip the initial `gtk_widget_show`
/// and avoid a visible flash of the window at every login. That duplication is
/// the price of killing the flash — the runner decides before Dart exists —
/// and this test is what keeps the two halves from drifting.
///
/// Drift is not catastrophic (Dart still corrects the visibility through
/// `core/window/launch_visibility.dart`, so the worst case is the flash coming
/// back, never an unreachable app) but it IS invisible, which is exactly the
/// kind of quiet degradation this repo refuses to ship.
void main() {
  test('the Linux runner recognises every hidden-launch spelling Dart does',
      () {
    final runner = File('linux/runner/my_application.cc');
    expect(
      runner.existsSync(),
      isTrue,
      reason: 'run this from the `mobile/` directory',
    );
    final source = runner.readAsStringSync();

    // Every alias LaunchOptions accepts must appear in the runner's matcher.
    for (final flag in const [
      hiddenLaunchFlag,
      '--start-hidden',
      '--start-minimized',
    ]) {
      expect(
        source,
        contains('"$flag"'),
        reason: 'my_application.cc does not know about $flag, so a login '
            'started with it would flash the window',
      );
      expect(LaunchOptions.parse([flag]).startHidden, isTrue);
    }
  });

  test('the runner only skips the initial show, it never hides afterwards', () {
    // The safety property: if the runner ever grew a `gtk_widget_hide` on the
    // hidden path it could fight window_manager's show() on the tray-failed
    // path and strand the user with no window and no icon.
    final source = File('linux/runner/my_application.cc').readAsStringSync();
    expect(source, isNot(contains('gtk_widget_hide')));
  });
}
