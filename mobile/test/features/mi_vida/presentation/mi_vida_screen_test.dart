// Smoke test: the "Mi vida" screen renders the consolidated view — domain
// sections with person sub-groups and entry rows. State is injected via
// provider overrides (fully synchronous — no DB in the widget fake-async zone);
// the DB-backed listing/edit/delete logic is covered by mi_vida_notifier_test.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest_schedule.dart';
import 'package:lifeos/features/daily_digest/presentation/daily_digest_notifier.dart';
import 'package:lifeos/features/domains/domain/local_domain_entry.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest.dart';
import 'package:lifeos/features/mi_vida/presentation/mi_vida_notifier.dart';
import 'package:lifeos/features/mi_vida/presentation/mi_vida_screen.dart';

class _FixedMiVida extends MiVidaNotifier {
  _FixedMiVida(this._fixed);
  final MiVidaState _fixed;
  @override
  MiVidaState build() => _fixed;
}

class _FixedDigest extends DailyDigestNotifier {
  @override
  DailyDigestState build() =>
      const DailyDigestState(schedule: DailyDigestSchedule(enabled: false));
}

void main() {
  final now = DateTime(2026, 7, 22, 12);

  LocalDomainEntry entry(String uuid, String label, {String? subject}) => LocalDomainEntry(
        uuid: uuid,
        label: label,
        timestamp: now,
        type: 'blood_pressure',
        data: {'type': 'blood_pressure', 'subject': ?subject},
      );

  testWidgets('renders domain sections grouped by person', (tester) async {
    final state = MiVidaState(
      loading: false,
      sections: [
        DigestDomainSection(
          domainKey: 'health',
          domainTitle: 'Salud',
          people: [
            DigestPersonGroup(
              personKey: '@self',
              personLabel: 'Yo',
              entries: [entry('1', 'Presión 120/80')],
            ),
            DigestPersonGroup(
              personKey: 'esposa',
              personLabel: 'Celia',
              entries: [entry('2', 'Presión 121/79', subject: 'esposa')],
            ),
          ],
        ),
      ],
      reminders: const [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          miVidaNotifierProvider.overrideWith(() => _FixedMiVida(state)),
          dailyDigestNotifierProvider.overrideWith(_FixedDigest.new),
        ],
        child: const MaterialApp(home: MiVidaScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Mi vida'), findsOneWidget);
    expect(find.textContaining('Salud'), findsWidgets);
    expect(find.text('Yo'), findsOneWidget);
    expect(find.text('Celia'), findsOneWidget);
    expect(find.text('Presión 120/80'), findsOneWidget);
    // Both entries render, each with an actions menu (edit/delete).
    expect(find.byType(PopupMenuButton<String>), findsNWidgets(2));
  });
}
