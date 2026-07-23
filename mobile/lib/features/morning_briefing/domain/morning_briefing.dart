import 'dart:convert';

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
    this.description = '',
    this.publishedAt,
    this.hnObjectId,
    this.fullSummary,
    this.commentsSummary,
  });

  /// Human-readable source name (feed/channel title or "Hacker News").
  final String sourceName;

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

  bool get isHackerNews => (hnObjectId ?? '').isNotEmpty;

  /// Stable identity for caching/pending-state lookups across state rebuilds.
  String get key => url.isNotEmpty ? url : '$sourceName::$title';

  BriefingArticle copyWith({String? fullSummary, String? commentsSummary}) => BriefingArticle(
        sourceName: sourceName,
        title: title,
        url: url,
        description: description,
        publishedAt: publishedAt,
        hnObjectId: hnObjectId,
        fullSummary: fullSummary ?? this.fullSummary,
        commentsSummary: commentsSummary ?? this.commentsSummary,
      );

  Map<String, dynamic> toJson() => {
        'sourceName': sourceName,
        'title': title,
        'url': url,
        'description': description,
        if (publishedAt != null) 'publishedAt': publishedAt!.toIso8601String(),
        if (hnObjectId != null) 'hnObjectId': hnObjectId,
        if (fullSummary != null) 'fullSummary': fullSummary,
        if (commentsSummary != null) 'commentsSummary': commentsSummary,
      };

  factory BriefingArticle.fromJson(Map<String, dynamic> json) => BriefingArticle(
        sourceName: (json['sourceName'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        url: (json['url'] as String?) ?? '',
        description: (json['description'] as String?) ?? '',
        publishedAt: DateTime.tryParse((json['publishedAt'] as String?) ?? ''),
        hnObjectId: json['hnObjectId'] as String?,
        fullSummary: json['fullSummary'] as String?,
        commentsSummary: json['commentsSummary'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is BriefingArticle &&
      other.sourceName == sourceName &&
      other.title == title &&
      other.url == url &&
      other.description == description &&
      other.publishedAt == publishedAt &&
      other.hnObjectId == hnObjectId &&
      other.fullSummary == fullSummary &&
      other.commentsSummary == commentsSummary;

  @override
  int get hashCode => Object.hash(
      sourceName, title, url, description, publishedAt, hnObjectId, fullSummary, commentsSummary);
}

/// A run of consecutive articles that share a source, for the grouped card UI
/// (a source header followed by its item cards).
class BriefingGroup {
  const BriefingGroup({required this.sourceName, required this.articles});

  final String sourceName;
  final List<BriefingArticle> articles;
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
    required this.generatedAt,
  });

  /// All fresh articles, in source order (build order). Group consecutively by
  /// [BriefingArticle.sourceName] via [groups].
  final List<BriefingArticle> articles;

  /// Names of sources that returned zero fresh items today (shown as a
  /// "sin novedades hoy" note).
  final List<String> skippedSources;

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
        out.add(BriefingGroup(sourceName: article.sourceName, articles: [article]));
      }
    }
    return out;
  }

  /// Returns a copy with the article identified by [key] replaced by [updated].
  OnDeviceBriefing replaceArticle(String key, BriefingArticle updated) => OnDeviceBriefing(
        articles: articles.map((a) => a.key == key ? updated : a).toList(),
        skippedSources: skippedSources,
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
        'generatedAt': generatedAt.toIso8601String(),
      };

  factory OnDeviceBriefing.fromJson(Map<String, dynamic> json) => OnDeviceBriefing(
        articles: ((json['articles'] as List<dynamic>?) ?? const [])
            .map((e) => BriefingArticle.fromJson(e as Map<String, dynamic>))
            .toList(),
        skippedSources: ((json['skippedSources'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        generatedAt: DateTime.tryParse((json['generatedAt'] as String?) ?? '') ?? DateTime.now(),
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
      if (briefing.articles.isEmpty && !decoded.containsKey('articles')) return null;
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
      other.generatedAt == generatedAt;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(articles), Object.hashAll(skippedSources), generatedAt);
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
