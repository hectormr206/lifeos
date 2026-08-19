// The user controls the sources, without being able to break them.
//
// Asked for: be able to DISABLE any source, ours or theirs; the ones we ship
// can only be disabled, never deleted; the ones the user added can be deleted;
// and the section has to be a pick-list "para que así el usuario no meta cosas
// que no existen".
//
// The reasoning behind each half:
//   * Disable rather than delete for the built-ins, because a curated default
//     someone turns off in a bad week is one they can turn back on. Deleted,
//     it is gone and they have to go find the URL again — which nobody does.
//   * Delete for their own, because a URL they typed by mistake should not
//     haunt the list for ever.
//   * A fixed section list, because free text produces "Tecnologia",
//     "tecnología" and "Tech" as three shelves for one idea, and the person
//     who has to live with that mess is the user.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_source.dart';

void main() {
  group('built-in versus added', () {
    test('every shipped source is marked as built-in', () {
      for (final source in defaultBriefingSources) {
        expect(source.builtIn, isTrue, reason: source.url);
      }
    });

    test('a source the user adds is not built-in', () {
      expect(
        const BriefingSource(url: 'https://mio.com/rss', section: 'Mundo').builtIn,
        isFalse,
      );
    });

    test('a built-in cannot be deleted, only disabled', () {
      final builtIn = defaultBriefingSources.first;

      expect(builtIn.canDelete, isFalse);
      expect(builtIn.canDisable, isTrue);
    });

    test('the user can delete their own', () {
      const mine = BriefingSource(url: 'https://mio.com/rss', section: 'Mundo');

      expect(mine.canDelete, isTrue);
      expect(mine.canDisable, isTrue);
    });
  });

  group('enabling and disabling', () {
    test('sources start enabled', () {
      expect(defaultBriefingSources.first.enabled, isTrue);
    });

    test('a disabled source survives a save and reload', () {
      const source = BriefingSource(
          url: 'https://x.com/rss', section: 'Mundo', enabled: false);

      final restored = BriefingSource.decode(source.encode());
      expect(restored.enabled, isFalse);
      expect(restored, source);
    });

    test('a built-in stays built-in through storage', () {
      final restored = BriefingSource.decode(defaultBriefingSources.first.encode());

      expect(restored.builtIn, isTrue);
    });

    test('a bare URL from an older version reads as enabled and NOT built-in',
        () {
      // Anything already on someone's phone is a plain URL. Reading it as
      // disabled would silently empty their briefing; reading it as built-in
      // would stop them deleting a feed they added themselves.
      final migrated = BriefingSource.decode('https://viejo.com/rss');

      expect(migrated.enabled, isTrue);
      expect(migrated.builtIn, isFalse);
    });

    test('only enabled sources are fetched', () {
      final active = enabledBriefingSources(const [
        BriefingSource(url: 'https://on.com/rss', section: 'Mundo'),
        BriefingSource(
            url: 'https://off.com/rss', section: 'Mundo', enabled: false),
      ]);

      expect([for (final s in active) s.url], ['https://on.com/rss']);
    });

    test('a disabled source still appears in the LIST, or it cannot come back',
        () {
      final all = const [
        BriefingSource(url: 'https://off.com/rss', section: 'Mundo', enabled: false),
      ];

      expect(groupBriefingSources(all).values.first, hasLength(1));
    });
  });

  group('the section pick-list', () {
    test('it offers the sections the defaults actually use', () {
      for (final source in defaultBriefingSources) {
        expect(kBriefingSections, contains(source.section));
      }
    });

    test('there is a General for anything that fits nowhere', () {
      expect(kBriefingSections, contains(kDefaultBriefingSection));
    });

    test('no duplicates in the list the user picks from', () {
      expect(kBriefingSections.toSet().length, kBriefingSections.length);
    });
  });
}
