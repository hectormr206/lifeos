import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/core/widgets/section_header.dart';
import 'package:lifeos/features/first_day/presentation/backup_reminder.dart';
import 'package:lifeos/features/home/presentation/home_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/theme/lifeos_theme.dart';

import '../../../support/fake_token_store.dart';

class _EveningClock implements Clock {
  @override
  DateTime now() => DateTime(2026, 7, 22, 21, 30);
}

Widget _app() => ProviderScope(
      overrides: [
        clockProvider.overrideWithValue(_EveningClock()),
        tokenStoreProvider.overrideWithValue(FakeTokenStore()),
        shouldAskForBackupProvider.overrideWith((ref) async => true),
      ],
      child: MaterialApp(
        theme: lifeosLightTheme,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child ?? const SizedBox.shrink(),
        ),
        home: const HomeScreen(),
      ),
    );

void _surface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

final _title = find.text('Si pierdes este teléfono');

void main() {
  group('phone', () {
    testWidgets('greeting is above the backup reminder', (tester) async {
      _surface(tester, const Size(390, 844));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(_title, findsOneWidget);
      expect(tester.getTopLeft(find.text('Buenas noches')).dy,
          lessThan(tester.getTopLeft(_title).dy));
    });

    testWidgets('the backup reminder scrolls with the content', (tester) async {
      _surface(tester, const Size(390, 844));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(_title).dy;
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(_title).dy, lessThan(before));
    });

    testWidgets('the reminder does not double the page gutter', (tester) async {
      _surface(tester, const Size(390, 844));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(BackupReminderBanner)).left,
          tester.getRect(find.byType(SectionHeader).first).left);
    });
  });

  testWidgets('wide: the reminder sits in the right pane', (tester) async {
    _surface(tester, const Size(1280, 800));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(_title, findsOneWidget);
    expect(tester.getTopLeft(_title).dx,
        greaterThanOrEqualTo(tester.getTopLeft(find.byType(SectionHeader).first).dx - 4));
  });
}
