import 'dart:convert';

import 'briefing_source.dart' show kDefaultBriefingSection;

/// One news article inside an on-device morning briefing ("boletín matutino").
///
/// Rebuilt to mirror the laptop's per-item card (axi/templates/briefings.html):
/// a feed-native [title] + brief [description], the [url] to open the full
/// article, an optional [publishedAt], and — for Hacker News items — the
/// [hnObjectId] used to fetch the comments thread.
///
/// The two summaries are produced ON DEMAND (never during briefing generation):
/// [fullSummary] when the reader taps "Ver resumen completo" and
/// [commentsSummary] (HN only) when they tap "Ver resumen de comentarios". Both
/// are cached back onto the article so a re-tap just toggles visibility.
class BriefingArticle {
  const BriefingArticle({
    required this.sourceName,
    required this.title,
    required this.url,
    this.section = kDefaultBriefingSection,
    this.description = '',
    this.publishedAt,
    this.hnObjectId,
    this.fullSummary,
    this.commentsSummary,
    this.translatedTitle,
    this.translatedDescription,
    this.generatedBrief,
    this.sourceExcerpt,
  });

  /// Human-readable source name (feed/channel title or "Hacker News").
  final String sourceName;

  /// The THEME this article belongs to — the section configured on its source
  /// ("Mundo", "México", "Tecnología"…). It is what the briefing is grouped
  /// and summarized by: three world feeds telling the same story belong under
  /// one heading, not in three separate blocks.
  final String section;

  /// Feed-native headline (kept in its original language — see the translation
  /// note in the notifier: on-demand summaries carry the app language instead).
  final String title;

  /// Article link (tappable). May be a Hacker News item page for text posts.
  final String url;

  /// Feed-native brief summary/description (CDATA/entities decoded, tags
  /// stripped). Empty when the feed carried none.
  final String description;

  /// Publication instant (UTC), parsed from the feed. Null when undated.
  final DateTime? publishedAt;

  /// The Hacker News Algolia `objectID`, present only on HN items. Its presence
  /// is what unlocks the "Ver resumen de comentarios" action.
  final String? hnObjectId;

  /// Cached on-demand full-article summary (null until first requested).
  final String? fullSummary;

  /// Cached on-demand HN comments summary (null until first requested).
  final String? commentsSummary;

  /// Cached app-language translation of [title] (null until a source's
  /// accordion is expanded and its titles are batch-translated on device).
  /// Persisted additively in the briefing JSON so a re-expand is instant.
  final String? translatedTitle;

  /// Cached app-language translation of [description] (null until translated,
  /// or when the feed carried no brief). Persisted additively.
  final String? translatedDescription;

  /// A SHORT brief written on-device for an item whose feed carried none.
  ///
  /// Some feeds ship a headline and nothing else (Hugging Face's blog has only
  /// guid/link/pubDate/title; Hacker News has no body at all), so there is no
  /// description to read. The laptop's briefing never had this gap because it
  /// does not READ a summary — it WRITES one. This is the phone doing the same,
  /// and it is stored separately from [description] so the feed's own words are
  /// never overwritten by a model's.
  final String? generatedBrief;

  /// The article's OWN opening words, taken verbatim from the fetched page and
  /// truncated — the last rung of the "there is always a short summary" ladder.
  ///
  /// It is used when the feed carried no brief AND the model could not write
  /// one (it failed, or the run's model budget was already spent). It is stored
  /// apart from [generatedBrief] on purpose: this text is the SOURCE speaking,
  /// not the model, and the two must never be confused. Nothing here is ever
  /// invented — when the page cannot be read, this stays null and the card says
  /// so plainly.
  final String? sourceExcerpt;

  bool get isHackerNews => (hnObjectId ?? '').isNotEmpty;

  /// The headline to render: the cached translation when present, else the
  /// feed-native [title] (never blank — the translation fallback).
  String get displayTitle =>
      (translatedTitle != null && translatedTitle!.trim().isNotEmpty)
      ? translatedTitle!
      : title;

  /// The brief to render — the ladder that keeps a card from ever being blank,
  /// in strict preference order:
  ///   1. [translatedDescription] — the feed's own brief, in the app language;
  ///   2. [description] — the feed's own brief, natively;
  ///   3. [generatedBrief] — a short brief the on-device model WROTE from the
  ///      article, for feeds that ship only a headline;
  ///   4. [sourceExcerpt] — the article's own opening words, verbatim, when the
  ///      model could not write one;
  ///   5. empty — the page could not be read at all. The card says that
  ///      plainly rather than showing invented text.
  ///
  /// The feed always outranks the model, and the model always outranks a raw
  /// excerpt: a real summary beats a written one, which beats a first paragraph.
  String get displayDescription {
    if (translatedDescription != null &&
        translatedDescription!.trim().isNotEmpty) {
      return translatedDescription!;
    }
    if (description.trim().isNotEmpty) return description;
    final written = generatedBrief?.trim() ?? '';
    if (written.isNotEmpty) return written;
    return sourceExcerpt?.trim() ?? '';
  }

  /// Stable identity for caching/pending-state lookups across state rebuilds.
  String get key => url.isNotEmpty ? url : '$sourceName::$title';

  BriefingArticle copyWith({
    String? fullSummary,
    String? commentsSummary,
    String? translatedTitle,
    String? translatedDescription,
    String? generatedBrief,
    String? sourceExcerpt,
  }) => BriefingArticle(
    sourceName: sourceName,
    title: title,
    url: url,
    section: section,
    description: description,
    publishedAt: publishedAt,
    hnObjectId: hnObjectId,
    fullSummary: fullSummary ?? this.fullSummary,
    commentsSummary: commentsSummary ?? this.commentsSummary,
    translatedTitle: translatedTitle ?? this.translatedTitle,
    translatedDescription: translatedDescription ?? this.translatedDescription,
    generatedBrief: generatedBrief ?? this.generatedBrief,
    sourceExcerpt: sourceExcerpt ?? this.sourceExcerpt,
  );

  Map<String, dynamic> toJson() => {
    'sourceName': sourceName,
    'title': title,
    'url': url,
    'section': section,
    'description': description,
    if (publishedAt != null) 'publishedAt': publishedAt!.toIso8601String(),
    if (hnObjectId != null) 'hnObjectId': hnObjectId,
    if (fullSummary != null) 'fullSummary': fullSummary,
    if (commentsSummary != null) 'commentsSummary': commentsSummary,
    if (translatedTitle != null) 'translatedTitle': translatedTitle,
    if (translatedDescription != null)
      'translatedDescription': translatedDescription,
    if (generatedBrief != null) 'generatedBrief': generatedBrief,
    if (sourceExcerpt != null) 'sourceExcerpt': sourceExcerpt,
  };

  factory BriefingArticle.fromJson(Map<String, dynamic> json) =>
      BriefingArticle(
        sourceName: (json['sourceName'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        url: (json['url'] as String?) ?? '',
        // A briefing cached before sections existed has no field; it reads as
        // the default shelf rather than crashing or vanishing.
        section:
            (json['section'] as String?) ?? kDefaultBriefingSection,
        description: (json['description'] as String?) ?? '',
        publishedAt: DateTime.tryParse((json['publishedAt'] as String?) ?? ''),
        hnObjectId: json['hnObjectId'] as String?,
        fullSummary: json['fullSummary'] as String?,
        commentsSummary: json['commentsSummary'] as String?,
        translatedTitle: json['translatedTitle'] as String?,
        translatedDescription: json['translatedDescription'] as String?,
        generatedBrief: json['generatedBrief'] as String?,
        sourceExcerpt: json['sourceExcerpt'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is BriefingArticle &&
      other.sourceName == sourceName &&
      other.title == title &&
      other.url == url &&
      other.section == section &&
      other.description == description &&
      other.publishedAt == publishedAt &&
      other.hnObjectId == hnObjectId &&
      other.fullSummary == fullSummary &&
      other.commentsSummary == commentsSummary &&
      other.translatedTitle == translatedTitle &&
      other.translatedDescription == translatedDescription &&
      other.generatedBrief == generatedBrief &&
      other.sourceExcerpt == sourceExcerpt;

  @override
  int get hashCode => Object.hash(
    sourceName,
    title,
    url,
    section,
    description,
    publishedAt,
    hnObjectId,
    fullSummary,
    commentsSummary,
    translatedTitle,
    translatedDescription,
    generatedBrief,
    sourceExcerpt,
  );
}

/// A run of consecutive articles that share a source, for the grouped card UI
/// (a source header followed by its item cards).
class BriefingGroup {
  const BriefingGroup({required this.sourceName, required this.articles});

  final String sourceName;
  final List<BriefingArticle> articles;
}

/// A run of articles that share a SECTION — the theme block the reader
/// actually navigates ("Mundo", "México"…), with the sources mixed inside.
class BriefingSectionGroup {
  const BriefingSectionGroup({required this.section, required this.articles});

  final String section;
  final List<BriefingArticle> articles;

  /// The distinct sources feeding this theme, in appearance order — what the
  /// header credits so the reader still knows who is talking.
  List<String> get sourceNames {
    final seen = <String>[];
    for (final a in articles) {
      if (!seen.contains(a.sourceName)) seen.add(a.sourceName);
    }
    return seen;
  }
}

/// A briefing built entirely ON DEVICE — the phone fetching, parsing, and
/// freshness-filtering its configured news feeds plus Hacker News, with NO bulk
/// model summarization (that runs only on demand, per item). Deliberately
/// SEPARATE from [BriefingModel] in features/briefings (the pairing-gated
/// laptop-dashboard viewer): this one never leaves the device.
class OnDeviceBriefing {
  const OnDeviceBriefing({
    required this.articles,
    this.skippedSources = const [],
    this.sectionDigests = const {},
    required this.generatedAt,
  });

  /// All fresh articles, in source order (build order). Group consecutively by
  /// [BriefingArticle.sourceName] via [groups].
  final List<BriefingArticle> articles;

  /// Names of sources that returned zero fresh items today (shown as a
  /// "sin novedades hoy" note).
  final List<String> skippedSources;

  /// One short paragraph per section, written on-device from the headlines of
  /// that theme — what the reader reads to decide what to open. A section
  /// missing from this map has no paragraph, and its headlines speak for
  /// themselves; nothing is ever invented to fill the gap.
  final Map<String, String> sectionDigests;

  /// When this briefing was produced (device local time).
  final DateTime generatedAt;

  bool get isEmpty => articles.isEmpty;

  /// Articles grouped into consecutive same-source runs (build order preserved).
  List<BriefingGroup> get groups {
    final out = <BriefingGroup>[];
    for (final article in articles) {
      if (out.isNotEmpty && out.last.sourceName == article.sourceName) {
        out.last.articles.add(article);
      } else {
        out.add(
          BriefingGroup(sourceName: article.sourceName, articles: [article]),
        );
      }
    }
    return out;
  }

  /// Articles grouped into consecutive same-SECTION runs (build order
  /// preserved). This is the grouping the screen renders.
  List<BriefingSectionGroup> get sections {
    final out = <BriefingSectionGroup>[];
    for (final article in articles) {
      if (out.isNotEmpty && out.last.section == article.section) {
        out.last.articles.add(article);
      } else {
        out.add(
          BriefingSectionGroup(section: article.section, articles: [article]),
        );
      }
    }
    return out;
  }

  /// Returns a copy with the article identified by [key] replaced by [updated].
  OnDeviceBriefing replaceArticle(String key, BriefingArticle updated) =>
      OnDeviceBriefing(
        articles: articles.map((a) => a.key == key ? updated : a).toList(),
        skippedSources: skippedSources,
        sectionDigests: sectionDigests,
        generatedAt: generatedAt,
      );

  /// Returns a copy stamped with the instant the briefing FINISHED.
  ///
  /// The stamp used to be taken before the first fetch, so "Generado 08:10"
  /// meant "started at 08:10" and read to the user as "this is what 08:10
  /// looked like". It is the only visible evidence of whether the automatic
  /// run happened, so it has to say when the briefing was actually ready.
  OnDeviceBriefing stampedAt(DateTime finishedAt) => OnDeviceBriefing(
    articles: articles,
    skippedSources: skippedSources,
    sectionDigests: sectionDigests,
    generatedAt: finishedAt,
  );

  /// Returns a copy carrying [digests] as its per-section paragraphs.
  OnDeviceBriefing withSectionDigests(Map<String, String> digests) =>
      OnDeviceBriefing(
        articles: articles,
        skippedSources: skippedSources,
        sectionDigests: digests,
        generatedAt: generatedAt,
      );

  BriefingArticle? articleForKey(String key) {
    for (final a in articles) {
      if (a.key == key) return a;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'articles': articles.map((a) => a.toJson()).toList(),
    'skippedSources': skippedSources,
    if (sectionDigests.isNotEmpty) 'sectionDigests': sectionDigests,
    'generatedAt': generatedAt.toIso8601String(),
  };

  factory OnDeviceBriefing.fromJson(Map<String, dynamic> json) =>
      OnDeviceBriefing(
        articles: ((json['articles'] as List<dynamic>?) ?? const [])
            .map((e) => BriefingArticle.fromJson(e as Map<String, dynamic>))
            .toList(),
        skippedSources: ((json['skippedSources'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        sectionDigests: {
          for (final entry
              in ((json['sectionDigests'] as Map<dynamic, dynamic>?) ??
                      const {})
                  .entries)
            entry.key.toString(): entry.value.toString(),
        },
        generatedAt:
            DateTime.tryParse((json['generatedAt'] as String?) ?? '') ??
            DateTime.now(),
      );

  /// Round-trips through [toJson] for shared_preferences string storage.
  String encode() => jsonEncode(toJson());

  /// Rebuilds a briefing from [encode]d text; null on any malformed payload so
  /// a corrupt/legacy cache never crashes the screen (it just regenerates).
  static OnDeviceBriefing? decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final briefing = OnDeviceBriefing.fromJson(decoded);
      // A legacy payload (old {intro, items:[{sourceTitle,summary}]} shape) has
      // no `articles`, so it decodes to an empty briefing → treat as no cache.
      if (briefing.articles.isEmpty && !decoded.containsKey('articles'))
        return null;
      return briefing;
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is OnDeviceBriefing &&
      _listEquals(other.articles, articles) &&
      _stringListEquals(other.skippedSources, skippedSources) &&
      _sameDigests(other.sectionDigests, sectionDigests) &&
      other.generatedAt == generatedAt;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(articles),
    Object.hashAll(skippedSources),
    Object.hashAll(sectionDigests.entries.map((e) => Object.hash(e.key, e.value))),
    generatedAt,
  );
}

bool _sameDigests(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

bool _listEquals(List<BriefingArticle> a, List<BriefingArticle> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _stringListEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
