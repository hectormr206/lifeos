// Proves the re-notify de-dup policy: notify on a new build, re-notify once
// per day for a still-pending build, stay silent on same-day repeats.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/update_notification_policy.dart';

void main() {
  final now = DateTime(2026, 7, 20, 9);

  test('notifies when nothing was ever notified', () {
    expect(
      shouldNotifyForUpdate(
        versionCode: 12,
        now: now,
        lastNotifiedVersionCode: null,
        lastNotifiedDay: null,
      ),
      isTrue,
    );
  });

  test('notifies for a different (newer) build even on the same day', () {
    expect(
      shouldNotifyForUpdate(
        versionCode: 13,
        now: now,
        lastNotifiedVersionCode: 12,
        lastNotifiedDay: '2026-07-20',
      ),
      isTrue,
    );
  });

  test('stays silent for the same build on the same day', () {
    expect(
      shouldNotifyForUpdate(
        versionCode: 12,
        now: now,
        lastNotifiedVersionCode: 12,
        lastNotifiedDay: '2026-07-20',
      ),
      isFalse,
    );
  });

  test('re-notifies for the same build on a new day', () {
    expect(
      shouldNotifyForUpdate(
        versionCode: 12,
        now: now,
        lastNotifiedVersionCode: 12,
        lastNotifiedDay: '2026-07-19',
      ),
      isTrue,
    );
  });

  test('dayKey formats as yyyy-mm-dd', () {
    expect(dayKey(DateTime(2026, 1, 5)), '2026-01-05');
  });
}
