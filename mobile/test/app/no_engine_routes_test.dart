// No route may send someone to pair with a server that does not exist.
//
// The engine was the old plan: run a bigger model on a powerful machine and
// share it with every device. Today each device runs its own local model and
// the graph syncs the results, so there is nothing to pair with — and yet the
// router still redirected half a dozen routes to `/settings/connection`, a
// screen whose only button is "Emparejar".
//
// The user interface no longer links to any of them (verified: no context.go
// or context.push targets them), so the only way in was a stray deep link or
// a restored route — and what waited there was a dead end that blames the
// user's Wi-Fi.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';

void main() {
  test('the engine routes are gone', () {
    // Read from the source rather than by navigating: the point is that these
    // paths are not REGISTERED at all, and a router with no route for them
    // cannot be talked into showing one.
    for (final path in const [
      '/body',
      '/insights',
      '/briefings',
      '/digest',
      '/meetings',
      '/graph',
      '/settings/engine',
      '/settings/connection',
    ]) {
      expect(kLifeosRoutePaths, isNot(contains(path)),
          reason: '$path still exists and leads to the dead engine');
    }
  });

  test('the local routes people actually use are still there', () {
    // The other half of the claim: this removes the engine, not the app.
    for (final path in const [
      '/',
      '/chat',
      '/reminders',
      '/mi-vida',
      '/brain3d',
      '/settings',
      '/settings/sync',
      '/settings/graph',
      '/settings/local-model',
      '/settings/updates',
      '/settings/briefing',
      '/settings/daily-digest',
      '/settings/backups',
    ]) {
      expect(kLifeosRoutePaths, contains(path), reason: '$path disappeared');
    }
  });
}
