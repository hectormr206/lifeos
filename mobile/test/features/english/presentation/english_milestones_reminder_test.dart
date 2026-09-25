// Milestones on screen, and a daily reminder that is an ordinary reminder.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/english_reminder.dart';
import 'package:lifeos/features/english/domain/milestones.dart';
import 'package:lifeos/features/english/presentation/english_milestones_view.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/features/english/presentation/english_reminder_tile.dart';
import 'package:lifeos/l10n/app_localizations.dart';

class _Reminder implements EnglishReminder {
  _Reminder([this.time]);
  TimeOfDay? time;
  final List<TimeOfDay> created = [];

  @override
  Future<TimeOfDay?> existingTime() async => time;

  @override
  Future<void> create(TimeOfDay time) async {
    created.add(time);
    this.time = time;
  }
}

/// Riverpod 3 does not export `Override`, so each test builds its own
/// ProviderScope around this (the repo's convention).
Widget _material(Widget child) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('milestones: how many, and which', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          milestonesProvider.overrideWith(
            (ref) async => {Milestone.placed, Milestone.firstReading},
          ),
        ],
        child: _material(const EnglishMilestonesView()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('2 de ${Milestone.values.length}'),
      findsOneWidget,
    );
    await tester.tap(find.textContaining('Logros'));
    await tester.pumpAndSettle();

    expect(find.text('Hiciste tu prueba de nivel'), findsOneWidget);
    expect(find.text('Día 66: ya es un hábito'), findsOneWidget);
    expect(find.byIcon(Icons.emoji_events), findsNWidgets(2));
  });

  testWidgets('no reminder yet: one tap sets a daily one at the chosen time', (
    tester,
  ) async {
    final reminder = _Reminder();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          englishReminderProvider.overrideWith((ref) async => reminder),
          reminderTimePickerProvider.overrideWithValue(
            (_) async => const TimeOfDay(hour: 20, minute: 30),
          ),
        ],
        child: _material(const EnglishReminderTile()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Recordarme cada día'));
    await tester.pumpAndSettle();

    expect(reminder.created.single, const TimeOfDay(hour: 20, minute: 30));
    expect(find.textContaining('20:30'), findsOneWidget);
  });

  testWidgets('an existing reminder is shown, never duplicated', (
    tester,
  ) async {
    final reminder = _Reminder(const TimeOfDay(hour: 7, minute: 0));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          englishReminderProvider.overrideWith((ref) async => reminder),
        ],
        child: _material(const EnglishReminderTile()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('7:00'), findsOneWidget);
    expect(find.text('Recordarme cada día'), findsNothing);
  });

  testWidgets('cancelling the time picker creates nothing', (tester) async {
    final reminder = _Reminder();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          englishReminderProvider.overrideWith((ref) async => reminder),
          reminderTimePickerProvider.overrideWithValue((_) async => null),
        ],
        child: _material(const EnglishReminderTile()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Recordarme cada día'));
    await tester.pumpAndSettle();

    expect(reminder.created, isEmpty);
  });
}
