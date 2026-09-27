import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

Widget _app(
  Locale locale, {
  required bool use24Hours,
  required ValueChanged<TimeOfDay?> result,
}) => ProviderScope(
  child: MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: use24Hours),
      child: child!,
    ),
    home: Consumer(
      builder: (context, ref, _) => Scaffold(
        body: TextButton(
          onPressed: () async =>
              result(await ref.read(reminderTimePickerProvider)(context)),
          child: const Text('Open picker'),
        ),
      ),
    ),
  ),
);

Future<void> _openInput(WidgetTester tester) async {
  await tester.tap(find.text('Open picker'));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.keyboard_outlined));
  await tester.pumpAndSettle();
}

Future<void> _enterTime(WidgetTester tester, String hour, String minute) async {
  final fields = find.byType(TextFormField);
  expect(fields, findsNWidgets(2));
  await tester.enterText(fields.at(0), hour);
  await tester.enterText(fields.at(1), minute);
  await tester.pump();
  await tester.tap(
    find
        .descendant(of: find.byType(Dialog), matching: find.byType(TextButton))
        .last,
  ); // dialog OK
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Spanish 24h display parses 05:43 as morning even with system flag off',
    (tester) async {
      TimeOfDay? selected;
      await tester.pumpWidget(
        _app(
          const Locale('es'),
          use24Hours: false,
          result: (time) => selected = time,
        ),
      );
      await _openInput(tester);
      expect(find.text('PM'), findsNothing);
      await _enterTime(tester, '05', '43');
      expect(selected, const TimeOfDay(hour: 5, minute: 43));
      await _openInput(tester);
      await _enterTime(tester, '17', '44');
      expect(selected, const TimeOfDay(hour: 17, minute: 44));
    },
  );

  testWidgets(
    'Spanish 24h input also accepts 17:44 and an already-24h device',
    (tester) async {
      TimeOfDay? selected;
      await tester.pumpWidget(
        _app(
          const Locale('es'),
          use24Hours: true,
          result: (time) => selected = time,
        ),
      );
      await _openInput(tester);
      await _enterTime(tester, '17', '44');
      expect(selected, const TimeOfDay(hour: 17, minute: 44));
    },
  );

  testWidgets(
    'English 12h picker exposes both periods and keeps explicit AM/PM',
    (tester) async {
      TimeOfDay? selected;
      await tester.pumpWidget(
        _app(
          const Locale('en'),
          use24Hours: false,
          result: (time) => selected = time,
        ),
      );
      await _openInput(tester);
      expect(find.text('AM'), findsOneWidget);
      expect(find.text('PM'), findsOneWidget);
      await tester.tap(find.text('AM'));
      await tester.pump();
      await _enterTime(tester, '05', '43');
      expect(selected, const TimeOfDay(hour: 5, minute: 43));

      await _openInput(tester);
      await _enterTime(tester, '05', '43'); // initial 20:00 is PM
      expect(selected, const TimeOfDay(hour: 17, minute: 43));
    },
  );
}
