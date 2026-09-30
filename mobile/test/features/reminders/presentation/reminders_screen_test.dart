// The reminders screen — a single LOCAL surface.
//
// The engine-viewer tests that used to live here went with the tab they
// covered: reminders on a paired server are not a thing any more, because
// every device runs its own model and the graph syncs the results. What is
// left is this device's own composer and list.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/english/data/english_reminder.dart';
import 'package:lifeos/features/reminders/data/local_reminders_repository.dart';
import 'package:lifeos/features/reminders/data/local_reminders_service.dart';
import 'package:lifeos/features/reminders/domain/local_reminder.dart';
import 'package:lifeos/features/reminders/domain/reminder_scheduler.dart';
import 'package:lifeos/features/reminders/presentation/local_reminders_providers.dart';
import 'package:lifeos/features/reminders/presentation/reminders_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/core/widgets/widgets.dart';
import 'package:lifeos/theme/lifeos_theme.dart';
import 'package:lifeos/theme/lifeos_tokens.dart';

// The real reminder repository/service share this synchronous in-memory graph.
// Flutter widget tests use a fake clock and cannot await sqflite FFI in fakeAsync.
class _Graph extends Fake implements LocalGraphStore {
  final nodes = <String, GraphNodeRecord>{};
  Completer<void>? firstListGate;
  int nextId = 0;
  @override
  Future<GraphNodeRecord> createNode({
    required String kind,
    required String label,
    Map<String, Object?> data = const {},
    String? domain,
    DateTime? occurredAt,
    String? createdTz,
    String? originNode,
  }) async {
    final now = DateTime(2026, 9, 25, 3);
    final node = GraphNodeRecord(
      uuid: '${++nextId}',
      kind: kind,
      label: label,
      data: data,
      domain: domain,
      occurredAt: occurredAt,
      createdAt: now,
      updatedAt: now,
    );
    nodes[node.uuid] = node;
    return node;
  }

  @override
  Future<List<GraphNodeRecord>> listNodesByKind(
    String kind, {
    int? limit,
    bool includeDeleted = false,
  }) async {
    final snapshot = nodes.values
        .where((n) => n.kind == kind && (includeDeleted || !n.isDeleted))
        .take(limit ?? nodes.length)
        .toList();
    final gate = firstListGate;
    firstListGate = null;
    if (gate != null) await gate.future;
    return snapshot;
  }

  @override
  Future<GraphNodeRecord?> getNodeByUuid(
    String uuid, {
    bool includeDeleted = false,
  }) async => nodes[uuid];
  @override
  Future<bool> softDeleteNode(String uuid) async => nodes.remove(uuid) != null;
}

class _Clock implements Clock {
  @override
  DateTime now() => DateTime(2026, 9, 25, 3);
}

class _Scheduler implements ReminderScheduler {
  final scheduled = <LocalReminder>[];
  final cancelled = <LocalReminder>[];
  @override
  Future<void> schedule(LocalReminder reminder) async =>
      scheduled.add(reminder);
  @override
  Future<void> cancel(LocalReminder reminder) async => cancelled.add(reminder);
}

Widget _routes({
  required LocalRemindersService service,
  required _Scheduler scheduler,
  Future<void>? serviceGate,
}) => ProviderScope(
  overrides: [
    clockProvider.overrideWithValue(_Clock()),
    reminderSchedulerProvider.overrideWithValue(scheduler),
    localRemindersServiceProvider.overrideWith((ref) async {
      await serviceGate;
      return service;
    }),
  ],
  child: MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const RemindersScreen()),
          ),
          child: const Text('Open reminders'),
        ),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Open reminders'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _delete(WidgetTester tester, String text) async {
  final tile = find.ancestor(
    of: find.text(text),
    matching: find.byType(ListTile),
  );
  await tester.tap(
    find.descendant(of: tile, matching: find.byType(PopupMenuButton<String>)),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Eliminar').last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Widget _localizedApp() => const ProviderScope(
  child: MaterialApp(
    locale: Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: RemindersScreen(),
  ),
);

/// The local tab keeps a progress indicator running while it loads, so
/// `pumpAndSettle` would wait for an animation that is the point of the
/// screen.
Future<void> _settleEnough(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('empty reminder guidance remains scrollable in a short viewport', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final scheduler = _Scheduler();
    final service = LocalRemindersService(LocalRemindersRepository(_Graph()), scheduler);
    await tester.pumpWidget(ProviderScope(overrides: [
      clockProvider.overrideWithValue(_Clock()),
      reminderSchedulerProvider.overrideWithValue(scheduler),
      localRemindersServiceProvider.overrideWith((ref) async => service),
    ], child: MaterialApp(theme: lifeosLightTheme, home: const RemindersScreen())));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.textContaining('Escribe uno abajo'));
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsOneWidget);
  });

  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('reminder time uses tabular display figures at width $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final scheduler = _Scheduler();
      final service = LocalRemindersService(LocalRemindersRepository(_Graph()), scheduler);
      await service.create(text: 'Llamar al doctor', dueAt: DateTime(2026, 9, 25, 9, 30));
      await tester.pumpWidget(ProviderScope(overrides: [
        clockProvider.overrideWithValue(_Clock()),
        reminderSchedulerProvider.overrideWithValue(scheduler),
        localRemindersServiceProvider.overrideWith((ref) async => service),
      ], child: MaterialApp(theme: lifeosLightTheme, home: const RemindersScreen())));
      await tester.pumpAndSettle();
      final time = tester.widget<Text>(find.text('09:30'));
      expect(time.style?.fontFeatures, contains(const FontFeature.tabularFigures()));
      expect(time.style?.fontFamily, lifeosLightTheme.textTheme.titleLarge?.fontFamily);
      expect(find.ancestor(of: find.text('Llamar al doctor'), matching: find.byType(GroupedList)), findsOneWidget);
      expect(tester.getSize(find.byType(GroupedList)).width, lessThanOrEqualTo(kContentMaxWidth - 2 * kPageGutter));
      expect(tester.getSize(find.byType(TextField)).width, lessThanOrEqualTo(kContentMaxWidth - 2 * kPageGutter));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'reopening global reminders reloads English direct writes and targeted deletion',
    (tester) async {
      final scheduler = _Scheduler();
      final service = LocalRemindersService(
        LocalRemindersRepository(_Graph()),
        scheduler,
      );
      final english = LocalEnglishReminder(
        service,
        text: 'Inglés: tu práctica de hoy',
        knownTexts: const {'Inglés: tu práctica de hoy'},
        clock: () => DateTime(2026, 9, 25, 3),
      );

      await service.create(text: 'Owned old', dueAt: DateTime(2026, 9, 25, 9));
      await tester.pumpWidget(_routes(service: service, scheduler: scheduler));
      await _open(tester);
      expect(find.text('Owned old'), findsOneWidget);
      await _delete(tester, 'Owned old');
      expect(find.textContaining('No tienes recordatorios'), findsOneWidget);
      Navigator.of(tester.element(find.byType(RemindersScreen))).pop();
      await tester.pumpAndSettle();

      final unrelated = await service.create(
        text: 'Keep this',
        dueAt: DateTime(2026, 9, 25, 10),
      );
      await english.create(const TimeOfDay(hour: 17, minute: 43));
      expect(
        await english.existingTime(),
        const TimeOfDay(hour: 17, minute: 43),
      );
      final target = (await service.list(
        now: DateTime(2026, 9, 25, 3),
      )).singleWhere((r) => r.text == 'Inglés: tu práctica de hoy');

      await _open(tester);
      expect(find.text('Inglés: tu práctica de hoy'), findsOneWidget);
      expect(find.text('Todos los días a las 17:43'), findsOneWidget);
      expect(find.text('Keep this'), findsOneWidget);
      await _delete(tester, 'Inglés: tu práctica de hoy');
      expect(await english.existingTime(), isNull);
      expect(find.text('Keep this'), findsOneWidget);
      expect(scheduler.cancelled.map((r) => r.uuid), contains(target.uuid));
      expect(
        scheduler.cancelled.map((r) => r.uuid),
        isNot(contains(unrelated.uuid)),
      );
      expect(
        (await service.list(now: DateTime(2026, 9, 25, 3))).map((r) => r.uuid),
        [unrelated.uuid],
      );
    },
  );

  testWidgets('initial empty load cannot overwrite an on-entry reload', (
    tester,
  ) async {
    final scheduler = _Scheduler();
    final graph = _Graph()..firstListGate = Completer<void>();
    final gate = graph.firstListGate!;
    final service = LocalRemindersService(
      LocalRemindersRepository(graph),
      scheduler,
    );
    final english = LocalEnglishReminder(
      service,
      text: 'Inglés: tu práctica de hoy',
      knownTexts: const {'Inglés: tu práctica de hoy'},
      clock: () => DateTime(2026, 9, 25, 3),
    );
    await tester.pumpWidget(_routes(service: service, scheduler: scheduler));
    await _open(tester);
    expect(
      graph.firstListGate,
      isNull,
      reason: 'the initial list is suspended',
    );
    await english.create(const TimeOfDay(hour: 17, minute: 43));
    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Inglés: tu práctica de hoy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving during initial load does not launch a late refresh', (
    tester,
  ) async {
    final scheduler = _Scheduler();
    final service = LocalRemindersService(
      LocalRemindersRepository(_Graph()),
      scheduler,
    );
    final gate = Completer<void>();
    await tester.pumpWidget(
      _routes(service: service, scheduler: scheduler, serviceGate: gate.future),
    );
    await tester.tap(find.text('Open reminders'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    Navigator.of(tester.element(find.byType(RemindersScreen))).pop();
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the create button is dead until there is something to create', (
    tester,
  ) async {
    // Seen on the test Pixel: with the box empty, tapping the alarm icon did
    // absolutely nothing — no form, no message, no hint. The handler returned
    // early on empty text while the button still looked and behaved like a
    // live control, so the only thing the app communicated was that it was
    // broken. A disabled button says "not yet" by being grey.
    await tester.pumpWidget(_localizedApp());
    await _settleEnough(tester);

    final button = find.widgetWithIcon(IconButton, Icons.alarm_add);
    expect(
      tester.widget<IconButton>(button).onPressed,
      isNull,
      reason: 'an empty box offers nothing to create',
    );

    await tester.enterText(find.byType(TextField).first, 'comprar pan');
    await tester.pump();

    expect(
      tester.widget<IconButton>(button).onPressed,
      isNotNull,
      reason: 'with text typed the button must come alive',
    );
  });

  testWidgets('whitespace alone does not count as text', (tester) async {
    await tester.pumpWidget(_localizedApp());
    await _settleEnough(tester);

    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.pump();

    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.alarm_add))
          .onPressed,
      isNull,
    );
  });
}
