// Fixed local data; no platform plugins or network. The tall hub capture shows
// every section while the other two use a phone portrait surface.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/widgets/widgets.dart';
import 'package:lifeos/features/app_update/domain/app_version_info.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest_schedule.dart';
import 'package:lifeos/features/daily_digest/presentation/daily_digest_notifier.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_schedule.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_providers.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_screen.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_sources_screen.dart';
import 'package:lifeos/features/settings/presentation/settings_hub_screen.dart';
import 'package:lifeos/features/daily_digest/presentation/daily_digest_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/morning_briefing/support/fakes.dart';
import 'support/golden_harness.dart';

class _Version implements AppVersionInfo {
  @override
  Future<int?> buildNumber() async => 800;
  @override
  Future<String> versionName() async => '0.9.19';
}

class _Digest extends DailyDigestNotifier {
  @override
  DailyDigestState build() =>
      const DailyDigestState(schedule: DailyDigestSchedule(enabled: false));
}

Widget _screen(Widget child, {List<String> sources = const []}) => ProviderScope(
      overrides: [
        appVersionInfoProvider.overrideWithValue(_Version()),
        morningBriefingPreferencesProvider.overrideWithValue(
          FakeMorningBriefingPreferences(
            initialSources: sources,
            initialSchedule: const BriefingSchedule(enabled: false),
          ),
        ),
        briefingSchedulerProvider.overrideWithValue(FakeBriefingScheduler()),
        briefingNotificationsProvider.overrideWithValue(FakeBriefingNotifications()),
        briefingBackgroundWorkProvider.overrideWithValue(FakeBriefingBackgroundWork()),
        dailyDigestNotifierProvider.overrideWith(_Digest.new),
      ],
      child: MaterialApp(
        theme: goldenTheme(),
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child ?? const SizedBox.shrink(),
        ),
        home: child,
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('hub sections keep tiles inside inset groups, with no outer dividers', (tester) async {
    useGoldenSurface(tester);
    await tester.pumpWidget(_screen(const SettingsHubScreen()));
    await tester.pumpAndSettle();
    final general = find.text('Modelo local');
    expect(find.ancestor(of: general, matching: find.byType(GroupedList)), findsOneWidget);
    expect(find.widgetWithText(SectionHeader, 'General'), findsOneWidget);
    expect(find.ancestor(of: find.byType(SegmentedButton<ThemeMode>),
        matching: find.byType(GroupedList)), findsOneWidget);
    for (final divider in tester.widgetList<Divider>(find.byType(Divider))) {
      final finder = find.byWidget(divider);
      expect(find.ancestor(of: finder, matching: find.byType(GroupedList)), findsOneWidget);
    }
  });
  testWidgets('briefing empty-state accent follows the active color scheme', (tester) async {
    useGoldenSurface(tester);
    await tester.pumpWidget(_screen(const MorningBriefingScreen()));
    await tester.pumpAndSettle();
    final icon = tester.widget<Icon>(find.byIcon(Icons.wb_sunny_outlined).last);
    final scheme = Theme.of(tester.element(find.byType(MorningBriefingScreen))).colorScheme;
    expect(icon.color, scheme.primary);
  });

  testWidgets('briefing sources stay together inside their named group', (tester) async {
    useGoldenSurface(tester);
    await tester.pumpWidget(_screen(const MorningBriefingSourcesScreen(),
        sources: ['https://example.com/feed']));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SectionHeader, 'General · 1'), findsOneWidget);
    expect(find.ancestor(of: find.text('https://example.com/feed'),
        matching: find.byType(GroupedList)), findsOneWidget);
  });

  for (final (name, screen, tall) in [
    ('settings_hub.png', const SettingsHubScreen(), true),
    ('settings_briefing.png', const MorningBriefingScreen(), false),
    ('settings_daily_digest.png', const DailyDigestScreen(), false),
  ]) {
    testWidgets('golden: $name', (tester) async {
      useGoldenSurface(tester);
      if (tall) tester.view.physicalSize = const Size(390, 1950) * kGoldenDpr;
      await tester.pumpWidget(_screen(screen));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await expectLater(find.byWidget(screen), matchesGoldenFile('images/$name'));
    });
  }
}
