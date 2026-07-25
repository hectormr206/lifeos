// Proves the pre-frame lock-flag resolution fails SAFE: a read ERROR defaults
// to LOCKED (the lock might be armed and we cannot know), while a successful
// read — including the missing-key → false contract — stays authoritative.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/main.dart';

import '../support/fakes.dart';

void main() {
  test('a read ERROR fails CLOSED (locked)', () async {
    // Regression: the catch block used to fall back to `false`, silently
    // starting the app UNLOCKED for a user whose lock was armed.
    expect(
      await resolveInitialAppLockEnabled(ThrowingAppLockPreferences()),
      isTrue,
    );
  });

  test('a successful "off" read stays off (missing key = lock disabled)', () async {
    expect(
      await resolveInitialAppLockEnabled(FakeAppLockPreferences()),
      isFalse,
    );
  });

  test('a successful "on" read locks', () async {
    expect(
      await resolveInitialAppLockEnabled(FakeAppLockPreferences(enabled: true)),
      isTrue,
    );
  });
}
