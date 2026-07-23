// GOLDEN: the "Mi vida" screen with seeded domain entries across two people
// (Yo + Celia) and two domains (health + exercise). State is injected via
// provider overrides — fully synchronous, no DB, no plugins — so the render is
// deterministic. The DB-backed listing logic is covered by mi_vida_notifier_test;
// this captures what the consolidated view actually LOOKS like.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest_schedule.dart';
import 'package:lifeos/features/daily_digest/presentation/daily_digest_notifier.dart';
import 'package:lifeos/features/domains/domain/local_domain_entry.dart';
import 'package:lifeos/features/mi_vida/presentation/mi_vida_notifier.dart';
import 'package:lifeos/features/mi_vida/presentation/mi_vida_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import 'support/golden_harness.dart';

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

  LocalDomainEntry entry(String uuid, String label, String type,
          {String? subject}) =>
      LocalDomainEntry(
        uuid: uuid,
        label: label,
        timestamp: now,
        type: type,
        data: {'type': type, 'subject': ?subject},
      );

  testWidgets('golden: Mi vida — 2 people, 2 domains', (tester) async {
    useGoldenSurface(tester);

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
              entries: [
                entry('h1', 'Presión 122/77, pulso 55', 'blood_pressure'),
                entry('h2', 'Glucosa 95 mg/dL', 'glucose'),
              ],
            ),
            DigestPersonGroup(
              personKey: 'esposa',
              personLabel: 'Celia',
              entries: [
                entry('h3', 'Presión 120/60, pulso 49', 'blood_pressure',
                    subject: 'esposa'),
              ],
            ),
          ],
        ),
        DigestDomainSection(
          domainKey: 'exercise',
          domainTitle: 'Ejercicio',
          people: [
            DigestPersonGroup(
              personKey: '@self',
              personLabel: 'Yo',
              entries: [
                entry('e1', 'Corrió 5 km en la mañana', 'activity'),
              ],
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
        child: MaterialApp(
          theme: goldenTheme(),
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const MiVidaScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(MiVidaScreen),
      matchesGoldenFile('images/mi_vida_screen.png'),
    );
  });
}
