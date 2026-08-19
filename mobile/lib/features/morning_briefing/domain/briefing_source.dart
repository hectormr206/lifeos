// A news source and the SECTION it belongs to.
//
// The briefing used to keep nine bare URLs. That is unreadable the moment it
// grows: "https://blog.desdelinux.net/feed/" next to
// "https://feeds.bbci.co.uk/mundo/rss.xml" tells the user nothing about what
// either one is for, let alone which to drop. A section is the name the user
// gives a shelf, and it is what the briefing groups by.
//
// EVERY DEFAULT BELOW WAS FETCHED before being added. Two obvious Mexican
// candidates (Animal Político, El Universal) answered 404 and are deliberately
// absent — a dead feed in the defaults is a silent hole in someone's morning,
// and the person who notices is the user, not us.
library;

import '../../memory/domain/subject.dart' show foldAccents;

/// The section used when none was given.
const String kDefaultBriefingSection = 'General';

class BriefingSource {
  const BriefingSource({required this.url, required this.section});

  final String url;
  final String section;

  /// Never blank: an empty heading looks like a rendering bug.
  String get displaySection =>
      section.trim().isEmpty ? kDefaultBriefingSection : section.trim();

  /// One storage line: `section|url`.
  ///
  /// The section goes FIRST and the split is on the first separator only, so a
  /// URL full of query-string pipes survives the round trip.
  String encode() => '${displaySection}|$url';

  static BriefingSource decode(String line) {
    final at = line.indexOf('|');
    // No separator: a bare URL saved before sections existed. Everything
    // already on someone's phone looks like this, and losing a list they
    // curated by hand would be unforgivable.
    if (at < 0) {
      return BriefingSource(url: line, section: kDefaultBriefingSection);
    }
    return BriefingSource(
      section: line.substring(0, at),
      url: line.substring(at + 1),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BriefingSource && other.url == url && other.section == section;

  @override
  int get hashCode => Object.hash(url, section);

  @override
  String toString() => 'BriefingSource($section, $url)';
}

/// The starting set. Verified reachable on 2026-08-19.
const List<BriefingSource> defaultBriefingSources = [
  // Mundo
  BriefingSource(
    url: 'https://feeds.bbci.co.uk/mundo/rss.xml',
    section: 'Mundo',
  ),
  BriefingSource(
    url: 'https://elpais.com/rss/elpais/portada.xml',
    section: 'Mundo',
  ),
  BriefingSource(
    url: 'https://rss.nytimes.com/services/xml/rss/nyt/World.xml',
    section: 'Mundo',
  ),
  // México
  BriefingSource(url: 'https://expansion.mx/rss', section: 'México'),
  BriefingSource(
    url: 'https://www.jornada.com.mx/rss/edicion.xml',
    section: 'México',
  ),
  // Tecnología
  BriefingSource(
    url: 'https://www.xataka.com/index.xml',
    section: 'Tecnología',
  ),
  BriefingSource(url: 'https://hipertextual.com/feed', section: 'Tecnología'),
  BriefingSource(
    url: 'https://www.genbeta.com/index.xml',
    section: 'Tecnología',
  ),
  BriefingSource(
    url: 'https://www.microsiervos.com/index.xml',
    section: 'Tecnología',
  ),
  // Inteligencia artificial
  BriefingSource(
    url: 'https://simonwillison.net/atom/everything/',
    section: 'Inteligencia artificial',
  ),
  BriefingSource(
    url: 'https://huggingface.co/blog/feed.xml',
    section: 'Inteligencia artificial',
  ),
  // Linux
  BriefingSource(url: 'https://www.muylinux.com/feed/', section: 'Linux'),
  BriefingSource(url: 'https://www.linuxadictos.com/feed/', section: 'Linux'),
  BriefingSource(url: 'https://blog.desdelinux.net/feed/', section: 'Linux'),
  // Ciencia y salud
  BriefingSource(
    url: 'https://feeds.bbci.co.uk/mundo/ciencia_tecnologia/rss.xml',
    section: 'Ciencia y salud',
  ),
  BriefingSource(
    url: 'https://www.scientificamerican.com/platform/syndication/rss/',
    section: 'Ciencia y salud',
  ),
  BriefingSource(
    url: 'https://www.who.int/rss-feeds/news-english.xml',
    section: 'Ciencia y salud',
  ),
  // Deportes
  BriefingSource(
    url: 'https://www.marca.com/rss/futbol/mexico.xml',
    section: 'Deportes',
  ),
];

/// Sources grouped by section, sections in the order they first appear.
///
/// Sections are matched accent- and case-insensitively: someone typing
/// "tecnologia" today and "Tecnología" tomorrow meant the same shelf, and two
/// near-identical headings read as a bug.
Map<String, List<BriefingSource>> groupBriefingSources(
  List<BriefingSource> sources,
) {
  final byKey = <String, String>{};
  final grouped = <String, List<BriefingSource>>{};
  for (final source in sources) {
    final key = foldAccents(source.displaySection.toLowerCase());
    final heading = byKey.putIfAbsent(key, () => source.displaySection);
    grouped.putIfAbsent(heading, () => []).add(source);
  }
  return grouped;
}
