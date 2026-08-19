// "Novedades de la semana" — what the brain learned lately.
//
// The desktop Cerebro opened on this, and it is the panel that answers the
// question a user actually has in front of a graph: not "what is in there"
// (thousands of dots) but "what did it pick up from me this week". Without it
// the details column sits empty until something is tapped, and an empty column
// is the app asking the user to explore instead of showing them anything.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/features/brain3d/domain/brain3d_news.dart';

GraphNodeRecord node(String label, DateTime created, {DateTime? occurred}) =>
    GraphNodeRecord(
      uuid: label,
      kind: 'fact',
      label: label,
      createdAt: created,
      updatedAt: created,
      occurredAt: occurred,
    );

void main() {
  final now = DateTime(2026, 8, 18, 9);

  test('it shows what arrived in the last seven days', () {
    final news = brain3dWeeklyNews(
      [
        node('hoy', now.subtract(const Duration(hours: 2))),
        node('anteayer', now.subtract(const Duration(days: 2))),
        node('el mes pasado', now.subtract(const Duration(days: 30))),
      ],
      now: now,
    );

    expect([for (final n in news) n.label], ['hoy', 'anteayer']);
  });

  test('the newest comes first', () {
    final news = brain3dWeeklyNews(
      [
        node('martes', now.subtract(const Duration(days: 3))),
        node('hoy', now.subtract(const Duration(hours: 1))),
        node('ayer', now.subtract(const Duration(days: 1))),
      ],
      now: now,
    );

    expect([for (final n in news) n.label], ['hoy', 'ayer', 'martes']);
  });

  test('it dates a memory by WHEN IT HAPPENED, not when it was typed', () {
    // Telling Axi on Tuesday about last year's trip is not news this week.
    // The same rule the date filter already follows — the two panels
    // disagreeing about what "this week" means would be worse than either
    // choice.
    final news = brain3dWeeklyNews(
      [
        node('viaje viejo', now,
            occurred: now.subtract(const Duration(days: 300))),
        node('cita de ayer', now.subtract(const Duration(days: 10)),
            occurred: now.subtract(const Duration(days: 1))),
      ],
      now: now,
    );

    expect([for (final n in news) n.label], ['cita de ayer']);
  });

  test('a quiet week returns nothing, and says nothing', () {
    // No filler. An invented "novedad" in a memory app is a lie about the
    // user's own life.
    expect(
      brain3dWeeklyNews([node('viejo', now.subtract(const Duration(days: 40)))],
          now: now),
      isEmpty,
    );
  });

  test('a very busy week is capped so the panel stays readable', () {
    final many = [
      for (var i = 0; i < 50; i++)
        node('n$i', now.subtract(Duration(minutes: i))),
    ];

    expect(brain3dWeeklyNews(many, now: now), hasLength(kBrain3dNewsLimit));
    // And it keeps the NEWEST, not the first it happened to see.
    expect(brain3dWeeklyNews(many, now: now).first.label, 'n0');
  });

  test('something dated in the future is not hidden', () {
    // An appointment stored for Friday is exactly what a user wants to see in
    // "this week", and a naive `isAfter(weekAgo)` window that also demanded
    // `isBefore(now)` would drop it.
    final news = brain3dWeeklyNews(
      [node('cita', now, occurred: now.add(const Duration(days: 2)))],
      now: now,
    );

    expect([for (final n in news) n.label], ['cita']);
  });
}
