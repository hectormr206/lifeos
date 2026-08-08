// The in-app reminder, for when the notification was missed or closed.
//
// His words: "solo un recordatorio a lo mejor cada vez que abra la app o una
// vez al dia", and "si no instala, que le recuerde al dia siguiente". So the
// banner gets a close button, closing it is a SNOOZE until tomorrow, and it
// does not nag again the same day.
//
// Deliberately NOT platform-branched: the same rule on the Pixel, on Linux, and
// on whatever ships next. The only thing that differs per platform is the
// notification transport, and that lives in AppNotifications.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/app_update/domain/app_manifest.dart';
import 'package:lifeos/features/app_update/domain/update_status.dart';
import 'package:lifeos/features/app_update/presentation/app_update_notifier.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';
import 'package:lifeos/features/app_update/presentation/update_available_banner.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../support/fakes.dart';

class _FixedClock implements Clock {
  _FixedClock(this.instant);

  /// Moved by the test to cross a calendar-day boundary without waiting for
  /// one.
  DateTime instant;

  @override
  DateTime now() => instant;
}

const _v793 = AppManifest(
  versionCode: 793,
  versionName: '0.9.21',
  apkFilename: '',
  sha256: 'abc',
  sizeBytes: 1,
  notes: '',
  publishedAt: '',
);
const _v794 = AppManifest(
  versionCode: 794,
  versionName: '0.9.22',
  apkFilename: '',
  sha256: 'def',
  sizeBytes: 1,
  notes: '',
  publishedAt: '',
);

ProviderContainer _container({
  required FakeAppUpdatePreferences prefs,
  required _FixedClock clock,
  AppManifest manifest = _v793,
}) {
  final container = ProviderContainer(overrides: [
    hostOperatingSystemProvider.overrideWithValue('android'),
    appUpdateInitialStatusProvider
        .overrideWithValue(UpdateAvailable(manifest: manifest)),
    appUpdatePreferencesProvider.overrideWithValue(prefs),
    appVersionInfoProvider.overrideWithValue(FakeAppVersionInfo()),
    updateNotificationsProvider.overrideWithValue(FakeUpdateNotifications()),
    clockProvider.overrideWithValue(clock),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('the reminder snoozes for the day, then comes back', () {
    test('a fresh update shows the banner', () async {
      final container = _container(
        prefs: FakeAppUpdatePreferences(),
        clock: _FixedClock(DateTime(2026, 8, 8, 9)),
      );
      await container.read(appUpdateNotifierProvider.notifier).ready;

      expect(container.read(appUpdateNotifierProvider).updateBannerVisible,
          isTrue);
    });

    test('dismissing hides it and remembers WHICH version was dismissed',
        () async {
      final prefs = FakeAppUpdatePreferences();
      final container = _container(
        prefs: prefs,
        clock: _FixedClock(DateTime(2026, 8, 8, 9)),
      );
      final notifier = container.read(appUpdateNotifierProvider.notifier);
      await notifier.ready;

      await notifier.dismissUpdateBanner();

      expect(container.read(appUpdateNotifierProvider).updateBannerVisible,
          isFalse);
      expect(prefs.dismissedCode, 793,
          reason: 'a bare boolean could never re-show for a NEWER build');
      expect(prefs.dismissedDayValue, '2026-08-08');
    });

    test('it stays away for the rest of that day, even across a re-check',
        () async {
      final prefs = FakeAppUpdatePreferences()
        ..dismissedCode = 793
        ..dismissedDayValue = '2026-08-08';
      final container = _container(
        prefs: prefs,
        clock: _FixedClock(DateTime(2026, 8, 8, 22)),
      );
      await container.read(appUpdateNotifierProvider.notifier).ready;

      expect(container.read(appUpdateNotifierProvider).updateBannerVisible,
          isFalse);
    });

    test('the next day it reminds him again — the update is still missing',
        () async {
      final prefs = FakeAppUpdatePreferences()
        ..dismissedCode = 793
        ..dismissedDayValue = '2026-08-08';
      final clock = _FixedClock(DateTime(2026, 8, 8, 22));
      final container = _container(prefs: prefs, clock: clock);
      final notifier = container.read(appUpdateNotifierProvider.notifier);
      await notifier.ready;
      expect(container.read(appUpdateNotifierProvider).updateBannerVisible,
          isFalse);

      // The app stayed open past midnight (it lives in the tray), so the
      // recompute has to happen on resume, not only at launch.
      clock.instant = DateTime(2026, 8, 9, 7);
      await notifier.refreshUpdateBannerVisibility();

      expect(container.read(appUpdateNotifierProvider).updateBannerVisible,
          isTrue);
    });

    test('a NEWER version re-shows it the same day', () async {
      // Dismissing 0.9.21 was about 0.9.21. 0.9.22 is news.
      final prefs = FakeAppUpdatePreferences()
        ..dismissedCode = 793
        ..dismissedDayValue = '2026-08-08';
      final container = _container(
        prefs: prefs,
        clock: _FixedClock(DateTime(2026, 8, 8, 23)),
        manifest: _v794,
      );
      await container.read(appUpdateNotifierProvider.notifier).ready;

      expect(container.read(appUpdateNotifierProvider).updateBannerVisible,
          isTrue);
    });
  });

  group('the banner widget', () {
    Future<void> pump(
      WidgetTester tester, {
      required FakeAppUpdatePreferences prefs,
      required _FixedClock clock,
    }) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          hostOperatingSystemProvider.overrideWithValue('android'),
          appUpdateInitialStatusProvider
              .overrideWithValue(const UpdateAvailable(manifest: _v793)),
          appUpdatePreferencesProvider.overrideWithValue(prefs),
          appVersionInfoProvider.overrideWithValue(FakeAppVersionInfo()),
          updateNotificationsProvider.overrideWithValue(FakeUpdateNotifications()),
          clockProvider.overrideWithValue(clock),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          routerConfig: GoRouter(routes: [
            GoRoute(
              path: '/',
              builder: (c, s) =>
                  const Scaffold(body: UpdateAvailableBanner()),
            ),
            GoRoute(
              path: '/settings/updates',
              builder: (c, s) => const Scaffold(body: Text('UPDATES')),
            ),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('offers a close affordance — it is a reminder, not a wall',
        (tester) async {
      await pump(
        tester,
        prefs: FakeAppUpdatePreferences(),
        clock: _FixedClock(DateTime(2026, 8, 8, 9)),
      );

      expect(find.text('Nueva versión disponible'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('closing it removes the banner without opening the screen',
        (tester) async {
      final prefs = FakeAppUpdatePreferences();
      await pump(
        tester,
        prefs: prefs,
        clock: _FixedClock(DateTime(2026, 8, 8, 9)),
      );

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('Nueva versión disponible'), findsNothing);
      expect(find.text('UPDATES'), findsNothing,
          reason: 'dismissing is not the same gesture as "take me there"');
      expect(prefs.dismissedCode, 793);
    });

    testWidgets('a dismissed banner does not come back the same day',
        (tester) async {
      await pump(
        tester,
        prefs: FakeAppUpdatePreferences()
          ..dismissedCode = 793
          ..dismissedDayValue = '2026-08-08',
        clock: _FixedClock(DateTime(2026, 8, 8, 15)),
      );

      expect(find.text('Nueva versión disponible'), findsNothing);
    });
  });
}
