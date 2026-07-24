import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/graph/graph_providers.dart';
import '../../../core/timezone/timezone_providers.dart';
import '../data/local_reminders_repository.dart';
import '../data/local_reminders_service.dart';
import '../data/reminder_notifications.dart';
import '../domain/reminder_scheduler.dart';

/// The production notification scheduler; overridden with a fake in tests so
/// no `flutter_local_notifications` channel is touched. Alarms are built in the
/// EFFECTIVE, DST-aware zone (device zone in AUTOMATIC mode, else the override),
/// resolved lazily so a reminder repeats at the correct LOCAL wall time.
final reminderSchedulerProvider = Provider<ReminderScheduler>(
  (ref) => NotificationReminderScheduler(
    locationResolver: () async {
      try {
        return (await ref.read(effectiveTimezoneProvider.future)).location;
      } catch (_) {
        return null;
      }
    },
  ),
);

/// The app-wide LOCAL reminders write-path (store + scheduler). Async because
/// the underlying [localGraphStoreProvider] opens/keys the encrypted DB
/// lazily. Consumers `await ...future` and degrade gracefully when the store
/// is unavailable (plain widget test / keystore missing): the reminders tab
/// shows an error, the chat intent falls through to the normal model flow.
///
/// TODO(reminders): cold-start tap routing (app killed → notification tap →
/// reminders screen) needs a hook in app.dart's notification-wiring section,
/// which the morning-briefing scheduling slice is reworking in parallel —
/// wire `NotificationReminderScheduler.launchedByTap()` there in a follow-up.
/// While the app is alive, taps are handled via the payload registry
/// (registered by the reminders screen).
final localRemindersServiceProvider =
    FutureProvider<LocalRemindersService>((ref) async {
  final store = await ref.watch(localGraphStoreProvider.future);
  return LocalRemindersService(
    LocalRemindersRepository(store),
    ref.watch(reminderSchedulerProvider),
  );
});
