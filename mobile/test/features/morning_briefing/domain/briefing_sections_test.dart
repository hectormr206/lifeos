// News sources belong to SECTIONS.
//
// Asked for: more sources, "y que las separaras por secciones, así el usuario
// puede agregar más URLs y su sección".
//
// The list used to be nine flat URLs, which is unreadable the moment it grows:
// a user looking at "https://blog.desdelinux.net/feed/" next to
// "https://feeds.bbci.co.uk/mundo/rss.xml" cannot tell what either one is for,
// let alone decide which to drop. A section is the name the user gives it, and
// it is also what the briefing groups by.
//
// EVERY DEFAULT SOURCE HERE WAS FETCHED before being added — two candidates
// (Animal Político, El Universal) returned 404 and are deliberately absent. A
// dead feed in the defaults is a silent hole in someone's morning.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_source.dart';

void main() {
  group('a source carries its section', () {
    test('it round-trips through storage as one line', () {
      const source = BriefingSource(url: 'https://ejemplo.com/rss', section: 'Mundo');

      expect(BriefingSource.decode(source.encode()), source);
    });

    test('a URL with no section reads as General', () {
      // Everything already saved on someone's phone is a bare URL. Losing
      // their sources on upgrade would be unforgivable for a list they curated
      // by hand.
      final migrated = BriefingSource.decode('https://feeds.bbci.co.uk/mundo/rss.xml');

      expect(migrated.url, 'https://feeds.bbci.co.uk/mundo/rss.xml');
      expect(migrated.section, 'General');
    });

    test('a URL containing the separator survives', () {
      // Query strings have every character in them.
      const source = BriefingSource(
          url: 'https://ejemplo.com/rss?a=1|b=2', section: 'Tecnología');

      expect(BriefingSource.decode(source.encode()).url,
          'https://ejemplo.com/rss?a=1|b=2');
    });

    test('an empty section falls back rather than showing a blank heading', () {
      expect(const BriefingSource(url: 'https://x.com/rss', section: '  ')
          .displaySection, 'General');
    });
  });

  group('the defaults', () {
    test('every one has a section', () {
      for (final source in defaultBriefingSources) {
        expect(source.section.trim(), isNotEmpty, reason: source.url);
      }
    });

    test('there are several sections, not one big pile', () {
      final sections = {for (final s in defaultBriefingSources) s.section};

      expect(sections.length, greaterThanOrEqualTo(4));
    });

    test('no duplicate URLs', () {
      final urls = [for (final s in defaultBriefingSources) s.url];

      expect(urls.toSet().length, urls.length);
    });

    test('the two feeds that returned 404 are not here', () {
      // Pinned by name: a future contributor adding "obvious" Mexican outlets
      // would reach for exactly these two.
      final urls = [for (final s in defaultBriefingSources) s.url].join(' ');

      expect(urls, isNot(contains('animalpolitico')));
      expect(urls, isNot(contains('eluniversal')));
    });

    test('they are all https', () {
      for (final source in defaultBriefingSources) {
        expect(source.url, startsWith('https://'), reason: source.url);
      }
    });
  });

  group('grouping for the screen', () {
    test('sources come back grouped, sections in first-seen order', () {
      final grouped = groupBriefingSources(const [
        BriefingSource(url: 'https://a', section: 'Mundo'),
        BriefingSource(url: 'https://b', section: 'Linux'),
        BriefingSource(url: 'https://c', section: 'Mundo'),
      ]);

      expect(grouped.keys.toList(), ['Mundo', 'Linux']);
      expect(grouped['Mundo']!.length, 2);
    });

    test('sections that differ only in case or accent are ONE section', () {
      // Someone typing "tecnologia" today and "Tecnología" tomorrow meant the
      // same shelf, and two near-identical headings look like a bug.
      final grouped = groupBriefingSources(const [
        BriefingSource(url: 'https://a', section: 'Tecnología'),
        BriefingSource(url: 'https://b', section: 'tecnologia'),
      ]);

      expect(grouped.keys.length, 1);
      expect(grouped.values.first.length, 2);
    });
  });
}
