import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/graph/graph_providers.dart';
import '../../domains/data/local_domain_repository.dart';
import '../../local_model/presentation/local_model_providers.dart';
import '../data/daily_digest_service.dart';
import '../data/graph_daily_digest_store.dart';
import '../data/local_daily_digest_scheduler.dart';
import '../domain/daily_digest_notifications.dart';
import '../domain/daily_digest_preferences.dart';
import '../domain/daily_digest_scheduler.dart';

/// Local-only persistence of the digest SETTINGS (schedule). Overridden with a
/// fake in tests. The digest CONTENT lives in [dailyDigestContentStoreProvider].
final dailyDigestPreferencesProvider = Provider<DailyDigestPreferences>(
  (ref) => SharedPrefsDailyDigestPreferences(),
);

/// ENCRYPTED persistence of the digest CONTENT (the last generated digest),
/// backed by the SQLCipher graph DB. Async because the encrypted store opens
/// lazily; consumers `await ...future` and degrade gracefully when unavailable
/// (plain widget test). Overridden with a fake in tests.
final dailyDigestContentStoreProvider = FutureProvider<DailyDigestContentStore>(
  (ref) async {
    final store = await ref.watch(localGraphStoreProvider.future);
    return GraphDailyDigestContentStore(store: store);
  },
);

/// OS-level trigger for the automatic digest (AlarmManager reminder). Overridden
/// with a fake in tests.
final dailyDigestSchedulerProvider = Provider<DailyDigestScheduler>(
  (ref) => LocalDailyDigestScheduler(),
);

/// "Tu resumen está listo" notification poster. Overridden with a fake in tests.
final dailyDigestNotificationsProvider = Provider<DailyDigestNotifications>(
  (ref) => FlutterLocalDailyDigestNotifications(),
);

/// The on-device digest pipeline (aggregation + model wrap-up). Async because
/// the encrypted graph store opens lazily. Consumers `await ...future` and
/// degrade gracefully when the store is unavailable (plain widget test).
final dailyDigestServiceProvider = FutureProvider<DailyDigestService>((
  ref,
) async {
  final store = await ref.watch(localGraphStoreProvider.future);
  return DailyDigestService(
    repository: LocalDomainRepository(store),
    store: store,
    engine: ref.watch(localLlmEngineProvider),
  );
});
