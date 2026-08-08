// When the "nueva versión disponible" banner is allowed on screen.
//
// The user's rule, in his words: "solo un recordatorio a lo mejor cada vez que
// abra la app o una vez al dia" and "si no instala, que le recuerde al dia
// siguiente". So dismissing is a SNOOZE, not a mute — and it is scoped to the
// version it was aimed at, because dismissing 0.9.19 is not consent to never
// hear about 0.9.20.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/update_banner_policy.dart';

void main() {
  test('never dismissed → shown', () {
    expect(
      shouldShowUpdateBanner(
        versionCode: 793,
        now: DateTime(2026, 8, 8, 10),
        dismissedVersionCode: null,
        dismissedDay: null,
      ),
      isTrue,
    );
  });

  test('dismissed today for THIS version → stays away for the rest of the day',
      () {
    expect(
      shouldShowUpdateBanner(
        versionCode: 793,
        now: DateTime(2026, 8, 8, 23, 59),
        dismissedVersionCode: 793,
        dismissedDay: '2026-08-08',
      ),
      isFalse,
    );
  });

  test('the next calendar day it comes back — the update is still not installed',
      () {
    expect(
      shouldShowUpdateBanner(
        versionCode: 793,
        now: DateTime(2026, 8, 9, 0, 1),
        dismissedVersionCode: 793,
        dismissedDay: '2026-08-08',
      ),
      isTrue,
    );
  });

  test('a NEWER version re-shows it even though the previous one was dismissed',
      () {
    // Dismissing 793 was about 793. 794 is news.
    expect(
      shouldShowUpdateBanner(
        versionCode: 794,
        now: DateTime(2026, 8, 8, 10),
        dismissedVersionCode: 793,
        dismissedDay: '2026-08-08',
      ),
      isTrue,
    );
  });

  test('the boundary is the calendar day, not 24 hours', () {
    // Dismissed at 23:00, back at 07:00 the next morning — seven hours later,
    // and correct: it is a different day for the person looking at it.
    expect(
      shouldShowUpdateBanner(
        versionCode: 793,
        now: DateTime(2026, 8, 9, 7),
        dismissedVersionCode: 793,
        dismissedDay: '2026-08-08',
      ),
      isTrue,
    );
  });
}
