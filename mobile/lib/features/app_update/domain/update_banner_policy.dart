/// When the in-app "nueva versión disponible" reminder may be on screen.
///
/// The notification is the primary channel, but it can be missed or swiped
/// away, so the banner is the backstop — and a backstop that cannot be closed
/// is not a reminder, it is a wall. His words: "solo un recordatorio a lo mejor
/// cada vez que abra la app o una vez al dia", and "si no instala, que le
/// recuerde al dia siguiente".
///
/// So closing it is a SNOOZE, and the snooze is stored KEYED BY VERSION rather
/// than as a bare boolean. That is what makes the last rule expressible at all:
/// dismissing 0.9.21 is not consent to never hear about 0.9.22.
///
/// The day boundary is a CALENDAR day in the user's effective zone, not "24
/// hours later". Dismissed at 23:00 and back at 07:00 is correct — it is a
/// different day for the person looking at it. This is the same shape as
/// `shouldNotifyForUpdate`, deliberately: two channels, one rule, so they can
/// never disagree about whether today is today.
library;

import 'update_notification_policy.dart' show dayKey;

bool shouldShowUpdateBanner({
  required int versionCode,
  required DateTime now,
  required int? dismissedVersionCode,
  required String? dismissedDay,
}) {
  // A different build than the one that was dismissed — including a newer one
  // — is news, and news is shown.
  if (dismissedVersionCode != versionCode) return true;
  return dismissedDay != dayKey(now);
}
