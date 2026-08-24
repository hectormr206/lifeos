// Ver el comentario de briefing_lead_time_test.dart: el sello dice cuándo
// TERMINÓ el boletín, no cuándo arrancó la tarea.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';

void main() {
  test('stampedAt reemplaza la hora y conserva todo lo demás', () {
    final arranque = DateTime(2026, 8, 24, 6, 40);
    final fin = DateTime(2026, 8, 24, 6, 58);
    final briefing = OnDeviceBriefing(
      articles: const [
        BriefingArticle(
          sourceName: 'F',
          section: 'Mundo',
          title: 't',
          url: 'https://a.com/1',
        ),
      ],
      skippedSources: const ['Muerta'],
      generatedAt: arranque,
    ).withSectionDigests(const {'Mundo': 'Lo de hoy.'});

    final stamped = briefing.stampedAt(fin);

    expect(stamped.generatedAt, fin);
    expect(stamped.articles, briefing.articles);
    expect(stamped.skippedSources, briefing.skippedSources);
    expect(stamped.sectionDigests, briefing.sectionDigests);
  });
}
