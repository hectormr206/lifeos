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

/// The sections the user picks from.
///
/// A fixed list rather than free text: typing produces "Tecnologia",
/// "tecnología" and "Tech" as three shelves for one idea, and the person who
/// has to live with that mess is the user.
const List<String> kBriefingSections = [
  'Mundo',
  'México',
  'Tecnología',
  'Inteligencia artificial',
  'Linux',
  'Ciencia y salud',
  'Deportes',
  'Negocios',
  'Cultura',
  kDefaultBriefingSection,
];

class BriefingSource {
  const BriefingSource({
    required this.url,
    required this.section,
    this.enabled = true,
    this.builtIn = false,
  });

  final String url;
  final String section;

  /// Disabled sources stay in the list and are skipped when fetching.
  ///
  /// Turning one off is not the same as losing it: a curated default someone
  /// mutes in a bad week is one they can turn back on, while a deleted one
  /// means going to find the URL again — which nobody does.
  final bool enabled;

  /// Shipped with the app. These can be disabled but never deleted, so the
  /// starting set stays recoverable.
  final bool builtIn;

  bool get canDelete => !builtIn;
  bool get canDisable => true;

  /// The same source, marked as shipped with the app.
  BriefingSource asBuiltIn() => BriefingSource(
    url: url,
    section: section,
    enabled: enabled,
    builtIn: true,
  );

  BriefingSource copyWith({bool? enabled, String? section}) => BriefingSource(
    url: url,
    section: section ?? this.section,
    enabled: enabled ?? this.enabled,
    builtIn: builtIn,
  );

  /// Never blank: an empty heading looks like a rendering bug.
  String get displaySection =>
      section.trim().isEmpty ? kDefaultBriefingSection : section.trim();

  /// One storage line: `section|flags|url`.
  ///
  /// The URL goes LAST and the split stops after two separators, so a URL full
  /// of query-string pipes survives the round trip.
  String encode() =>
      '$displaySection|${enabled ? 'on' : 'off'}${builtIn ? '+b' : ''}|$url';

  static BriefingSource decode(String line) {
    final first = line.indexOf('|');
    // No separator: a bare URL from before any of this existed. Reading it as
    // disabled would silently empty someone's briefing; reading it as built-in
    // would stop them deleting a feed they added themselves.
    if (first < 0) {
      return BriefingSource(url: line, section: kDefaultBriefingSection);
    }
    final second = line.indexOf('|', first + 1);
    // Only one separator: the section|url format, before enable/disable.
    if (second < 0) {
      return BriefingSource(
        section: line.substring(0, first),
        url: line.substring(first + 1),
      );
    }
    final flags = line.substring(first + 1, second);
    return BriefingSource(
      section: line.substring(0, first),
      url: line.substring(second + 1),
      enabled: !flags.startsWith('off'),
      builtIn: flags.contains('+b'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BriefingSource &&
      other.url == url &&
      other.section == section &&
      other.enabled == enabled &&
      other.builtIn == builtIn;

  @override
  int get hashCode => Object.hash(url, section, enabled, builtIn);

  @override
  String toString() => 'BriefingSource($section, $url)';
}

/// The starting set. Verified reachable on 2026-08-19.
///
/// `builtIn` is applied to the whole list below rather than written on each
/// entry: relying on eighteen separate reminders is how one ends up deletable
/// by accident.
List<BriefingSource> get defaultBriefingSources => [
  for (final source in _shipped) source.asBuiltIn(),
];

const List<BriefingSource> _shipped = [
  // Mundo
  BriefingSource(
    url: 'https://feeds.bbci.co.uk/mundo/rss.xml',
    section: 'Mundo',
  ),
  BriefingSource(
    // No la portada de `elpais.com/rss/...`: ese feed sirve noticias de 2020
    // (medido el 2026-08-24). Ver [deadBriefingSources].
    url: 'https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/portada',
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
  // BBC retiró su feed de ciencia: esa URL responde 301 al feed general, así
  // que enviarla dejaba "BBC Mundo" dos veces con las mismas noticias
  // (medido el 2026-08-20). Muy Interesante cubre el hueco en español.
  BriefingSource(
    url: 'https://www.muyinteresante.com/feed/',
    section: 'Ciencia y salud',
  ),
  BriefingSource(
    url: 'https://www.scientificamerican.com/platform/syndication/rss/',
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

/// The sources that actually get fetched.
List<BriefingSource> enabledBriefingSources(List<BriefingSource> sources) => [
  for (final source in sources)
    if (source.enabled) source,
];

/// The key that decides whether two entries are the same feed.
///
/// Host case and a trailing slash are noise — the server answers the same
/// bytes either way — but the PATH is not: BBC Mundo and BBC Ciencia share a
/// host and are different sources. Anything that is not a URL falls back to
/// its own trimmed text so a malformed entry never swallows another.
String briefingSourceKey(String url) {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasAuthority) return trimmed.toLowerCase();
  var path = uri.path;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}'
      '$path${uri.hasQuery ? '?${uri.query}' : ''}';
}

/// One feed, one entry.
///
/// A list can arrive with the same URL twice — pasted by hand, or the same
/// feed filed under two sections. Fetching it twice costs double and shows
/// the same headlines in two groups with the same name, which reads like a
/// bug because it is one. The first entry wins so the order the user sees
/// does not shuffle.
/// Built-in feeds that stopped publishing, mapped to their live replacement
/// (or to null when there is none and the entry should simply go).
///
/// WHY A MAP AND NOT JUST AN EDIT TO `_shipped`. The source list is written to
/// the device the first time the briefing screen is opened, and from then on
/// [MorningBriefingPreferences.sources] returns THAT list — editing the
/// shipped defaults never reaches anyone who already used the app. This is the
/// same lesson the BBC duplicate taught in `mergeHarvestsByName`, one layer up.
///
/// Measured 2026-08-24, each by fetching the feed and reading the date of its
/// NEWEST item:
///   * El País portada  → newest item from 27 February 2020 (six years stale);
///     `feeds.elpais.com/mrss-s/...` is the live one, 145 items from today.
///   * Genbeta          → newest item 31 December 2025; `/feed` returns 404.
///   * OMS (inglés)     → newest item 25 February 2026.
const Map<String, String?> deadBriefingSources = {
  'https://elpais.com/rss/elpais/portada.xml':
      'https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/portada',
  'https://www.genbeta.com/index.xml': null,
  'https://www.who.int/rss-feeds/news-english.xml': null,
};

/// Rewrites dead built-in feeds to their live replacement and drops the ones
/// that have none, leaving everything else — including anything the user added
/// by hand — exactly as it was.
///
/// A source the user switched OFF stays off: healing fixes a broken address,
/// it does not overrule a decision. Running it twice changes nothing.
List<BriefingSource> healBriefingSources(List<BriefingSource> sources) {
  final healed = <BriefingSource>[];
  for (final source in sources) {
    final key = briefingSourceKey(source.url);
    final dead = deadBriefingSources.keys.where(
      (url) => briefingSourceKey(url) == key,
    );
    var url = source.url;
    if (dead.isNotEmpty) {
      final replacement = deadBriefingSources[dead.first];
      if (replacement == null) continue; // no live equivalent → it goes
      url = replacement;
    }
    healed.add(
      BriefingSource(
        url: url,
        section: _sectionFor(url, source.section),
        enabled: source.enabled,
        builtIn: source.builtIn,
      ),
    );
  }
  // A device whose list already held the replacement now holds it twice.
  return dedupeBriefingSources(healed);
}

/// The theme a source belongs to.
///
/// FOUND ON THE TEST PIXEL, 2026-08-24: that phone had stored its feeds as
/// bare URLs — the format from before sections existed — so all eighteen read
/// as "General" and the whole briefing rendered as ONE block of 74 articles.
/// With a per-section cap that would not just look wrong, it would DROP whole
/// topics. So a feed we shipped gets its shipped theme back.
///
/// A theme the user actually chose always wins: healing repairs what was never
/// filled in, it never overrules a decision.
String _sectionFor(String url, String stored) {
  if (stored.trim().isNotEmpty && stored.trim() != kDefaultBriefingSection) {
    return stored;
  }
  final key = briefingSourceKey(url);
  for (final shipped in _shipped) {
    if (briefingSourceKey(shipped.url) == key) return shipped.section;
  }
  return stored;
}

List<BriefingSource> dedupeBriefingSources(List<BriefingSource> sources) {
  final seen = <String>{};
  return [
    for (final source in sources)
      if (seen.add(briefingSourceKey(source.url))) source,
  ];
}
