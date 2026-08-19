import 'dart:convert';

/// One structured item parsed out of a feed (RSS `<item>`, Atom `<entry>`, or
/// RDF `<item>`) — keeps the fields SEPARATE (not flattened to prose) so the
/// card UI can render a title, a brief description, a link, and a date, and the
/// freshness filter can act on [published].
class ParsedFeedItem {
  const ParsedFeedItem({
    required this.title,
    required this.link,
    this.description = '',
    this.published,
    this.hnObjectId,
  });

  final String title;
  final String link;
  final String description;

  /// Publication instant in UTC (null when the feed carried no parseable date).
  final DateTime? published;

  /// Hacker News Algolia `objectID`, set only for HN items.
  final String? hnObjectId;
}

/// A parsed feed: its source/channel [sourceTitle] and the [items] it carried.
class ParsedFeed {
  const ParsedFeed({required this.sourceTitle, required this.items});

  final String sourceTitle;
  final List<ParsedFeedItem> items;
}

/// Readable content pulled out of one fetched source, ready to hand to the
/// on-device model for summarization.
class SourceExtract {
  const SourceExtract({required this.title, required this.text});

  /// A human-readable source title (feed/channel title or HTML `<title>`),
  /// falling back to the host if nothing usable was found.
  final String title;

  /// The extracted readable text — feed item titles+summaries, or the stripped
  /// HTML body. Already length-capped so prompts stay small.
  final String text;

  bool get isEmpty => text.trim().isEmpty;
}

/// Pragmatic, dependency-free reader for a fetched news source.
///
/// Dart has NO XML parser in its standard library, and the app intentionally
/// carries no `xml`/`html` package, so extraction is done with robust regexes:
///   * RSS/Atom/RDF feeds → item/entry titles + summaries (the common case for
///     news sources), and
///   * anything else → HTML stripped to plain text, first chunk kept.
/// Everything here is pure (no IO) so it is fully unit-testable.
class SourceContentExtractor {
  const SourceContentExtractor({
    this.maxItems = 6,
    this.maxChars = 1600,
    this.briefMaxChars = 200,
  });

  /// Max feed items to keep (top headlines).
  final int maxItems;

  /// Hard cap on the extracted text length — the on-device model is small
  /// (~512 output tokens), so we feed it a bounded chunk.
  final int maxChars;

  /// Hard cap on a per-item BRIEF description (the card summary). Some feeds
  /// (e.g. Simon Willison's) ship raw/escaped HTML in `<description>`; once
  /// tags are stripped and entities decoded the text can still be huge, so it
  /// is bounded to a single readable snippet with an ellipsis.
  final int briefMaxChars;

  static final RegExp _itemBlock = RegExp(
    r'<(item|entry)\b[^>]*>(.*?)</\1>',
    dotAll: true,
    caseSensitive: false,
  );
  static final RegExp _titleTag = RegExp(
    r'<title\b[^>]*>(.*?)</title>',
    dotAll: true,
    caseSensitive: false,
  );
  static final RegExp _descTag = RegExp(
    r'<(description|summary|content)\b[^>]*>(.*?)</\1>',
    dotAll: true,
    caseSensitive: false,
  );
  static final RegExp _h1Tag = RegExp(
    r'<h1\b[^>]*>(.*?)</h1>',
    dotAll: true,
    caseSensitive: false,
  );
  static final RegExp _scriptStyle = RegExp(
    r'<(script|style)\b[^>]*>.*?</\1>',
    dotAll: true,
    caseSensitive: false,
  );
  static final RegExp _anyTag = RegExp(r'<[^>]+>');
  static final RegExp _cdata = RegExp(r'<!\[CDATA\[(.*?)\]\]>', dotAll: true);
  static final RegExp _whitespace = RegExp(r'\s+');

  // Per-item structured parsing (RSS/Atom/RDF).
  static final RegExp _linkTag = RegExp(
    r'<link\b([^>]*)>',
    caseSensitive: false,
  );
  static final RegExp _linkTextTag = RegExp(
    r'<link\b[^>]*>(.*?)</link>',
    dotAll: true,
    caseSensitive: false,
  );
  static final RegExp _hrefAttr = RegExp(
    '''href\\s*=\\s*["']([^"']*)["']''',
    caseSensitive: false,
  );
  static final RegExp _relAttr = RegExp(
    '''rel\\s*=\\s*["']([^"']*)["']''',
    caseSensitive: false,
  );
  static final RegExp _guidTag = RegExp(
    r'<guid\b[^>]*>(.*?)</guid>',
    dotAll: true,
    caseSensitive: false,
  );
  static final RegExp _dateTag = RegExp(
    r'<(pubDate|published|updated|dc:date|date)\b[^>]*>(.*?)</\1>',
    dotAll: true,
    caseSensitive: false,
  );
  static final RegExp _rfc822 = RegExp(
    r'(\d{1,2})\s+([A-Za-z]{3})[a-z]*\s+(\d{2,4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|[A-Za-z]{1,5})?',
  );
  static const Map<String, int> _months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  /// Whether [body] looks like an RSS/Atom/RDF feed (checked on the head so a
  /// stray `<rss>` mention deep in an HTML article never misclassifies it).
  bool looksLikeFeed(String body) {
    final head = body.length > 800
        ? body.substring(0, 800).toLowerCase()
        : body.toLowerCase();
    return head.contains('<rss') ||
        head.contains('<feed') ||
        head.contains('<rdf:rdf') ||
        head.contains('<?xml') &&
            (body.toLowerCase().contains('<item') ||
                body.toLowerCase().contains('<entry'));
  }

  /// Extracts readable content from [body]. [url] provides the host fallback
  /// title. Returns an empty [SourceExtract] (isEmpty) when nothing usable
  /// could be pulled, so the pipeline can skip the source.
  SourceExtract extract(String body, {required String url}) {
    final host = _hostOf(url);
    if (looksLikeFeed(body)) {
      return _extractFeed(body, host: host);
    }
    return _extractHtml(body, host: host);
  }

  SourceExtract _extractFeed(String body, {required String host}) {
    final feedTitle = _firstTitle(body) ?? host;
    final buffer = StringBuffer();
    var count = 0;
    for (final match in _itemBlock.allMatches(body)) {
      if (count >= maxItems) break;
      final block = match.group(2) ?? '';
      final title = _clean(_titleTag.firstMatch(block)?.group(1) ?? '');
      final desc = _clean(_descTag.firstMatch(block)?.group(2) ?? '');
      if (title.isEmpty && desc.isEmpty) continue;
      if (title.isNotEmpty) buffer.writeln('- $title');
      if (desc.isNotEmpty) buffer.writeln('  $desc');
      count++;
    }
    return SourceExtract(
      title: feedTitle,
      text: _cap(buffer.toString().trim()),
    );
  }

  SourceExtract _extractHtml(String body, {required String host}) {
    final title = _clean(
      _firstTitle(body) ?? _clean(_h1Tag.firstMatch(body)?.group(1) ?? ''),
    );
    final withoutScripts = body.replaceAll(_scriptStyle, ' ');
    final stripped = _decodeEntities(withoutScripts.replaceAll(_anyTag, ' '));
    final text = stripped.replaceAll(_whitespace, ' ').trim();
    return SourceExtract(
      title: title.isNotEmpty ? title : host,
      text: _cap(text),
    );
  }

  /// Parses [body] as an RSS/Atom/RDF feed into STRUCTURED per-item records
  /// (title, link, description, published) — keeping fields separate rather
  /// than flattening to prose (that is [extract]'s job for the on-demand
  /// article read). Handles `<item>` (RSS + RDF) and `<entry>` (Atom).
  ParsedFeed parseFeed(String body, {required String url}) {
    final host = _hostOf(url);
    final feedTitle = _firstTitle(body) ?? host;
    final items = <ParsedFeedItem>[];
    for (final match in _itemBlock.allMatches(body)) {
      final block = match.group(2) ?? '';
      final title = _clean(_titleTag.firstMatch(block)?.group(1) ?? '');
      final link = _extractLink(block);
      final desc = cleanBrief(_descTag.firstMatch(block)?.group(2) ?? '');
      final published = parseFeedDate(_dateTag.firstMatch(block)?.group(2));
      if (title.isEmpty && link.isEmpty) continue;
      items.add(
        ParsedFeedItem(
          title: title,
          link: link,
          description: desc,
          published: published,
        ),
      );
    }
    return ParsedFeed(sourceTitle: feedTitle, items: items);
  }

  /// The item link: Atom's `<link href="…"/>` (preferring rel="alternate"),
  /// falling back to RSS/RDF's `<link>url</link>` text, then a permalink guid.
  String _extractLink(String block) {
    String? alternate;
    String? firstHref;
    for (final m in _linkTag.allMatches(block)) {
      final attrs = m.group(1) ?? '';
      final href = _hrefAttr.firstMatch(attrs)?.group(1)?.trim();
      if (href == null || href.isEmpty) continue;
      firstHref ??= href;
      final rel =
          _relAttr.firstMatch(attrs)?.group(1)?.toLowerCase() ?? 'alternate';
      if (rel == 'alternate') alternate ??= href;
    }
    final atom = alternate ?? firstHref;
    if (atom != null && atom.isNotEmpty) return _decodeEntities(atom);
    final text = _clean(_linkTextTag.firstMatch(block)?.group(1) ?? '');
    if (text.startsWith('http')) return text;
    final guid = _clean(_guidTag.firstMatch(block)?.group(1) ?? '');
    if (guid.startsWith('http')) return guid;
    return '';
  }

  /// Parses a feed date string to a tz-aware UTC [DateTime], or null. Accepts
  /// ISO-8601 (Atom `updated`/`published`, a trailing `Z` normalized) and
  /// RFC-822 (RSS `pubDate`, sometimes `dc:date`). Public + static so it is
  /// unit-testable on its own.
  static DateTime? parseFeedDate(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return null;
    final iso = s.endsWith('Z') ? '${s.substring(0, s.length - 1)}+00:00' : s;
    final isoDt = DateTime.tryParse(iso);
    if (isoDt != null) return isoDt.toUtc();
    final m = _rfc822.firstMatch(s);
    if (m == null) return null;
    final month = _months[m.group(2)!.toLowerCase()];
    if (month == null) return null;
    var year = int.parse(m.group(3)!);
    if (year < 100) year += 2000;
    final day = int.parse(m.group(1)!);
    final hour = int.parse(m.group(4)!);
    final minute = int.parse(m.group(5)!);
    final second = int.tryParse(m.group(6) ?? '0') ?? 0;
    final base = DateTime.utc(year, month, day, hour, minute, second);
    final tz = m.group(7);
    final offset = _offsetOf(tz);
    return base.subtract(offset);
  }

  static Duration _offsetOf(String? tz) {
    if (tz == null || tz.isEmpty) return Duration.zero;
    final numeric = RegExp(r'^([+-])(\d{2})(\d{2})$').firstMatch(tz);
    if (numeric != null) {
      final sign = numeric.group(1) == '-' ? -1 : 1;
      final h = int.parse(numeric.group(2)!);
      final min = int.parse(numeric.group(3)!);
      return Duration(hours: sign * h, minutes: sign * min);
    }
    // Named zones we normalize to UTC (feeds overwhelmingly use GMT/UTC).
    return Duration.zero;
  }

  /// Parses the Hacker News Algolia `search?tags=front_page` JSON into dated
  /// candidates, each carrying its `objectID` (as [ParsedFeedItem.hnObjectId])
  /// so the comments feature can fetch the thread later. Never throws.
  ParsedFeed parseHackerNews(String body, {String sourceName = 'Hacker News'}) {
    final items = <ParsedFeedItem>[];
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final hits = decoded['hits'];
        if (hits is List) {
          for (final hit in hits) {
            if (hit is! Map) continue;
            final oid = (hit['objectID'] ?? '').toString().trim();
            final title = _clean((hit['title'] ?? '').toString());
            if (title.isEmpty) continue;
            var link = (hit['url'] ?? '').toString().trim();
            if (link.isEmpty && oid.isNotEmpty) {
              link = 'https://news.ycombinator.com/item?id=$oid';
            }
            if (link.isEmpty) continue;
            items.add(
              ParsedFeedItem(
                title: title,
                link: link,
                published: parseFeedDate(hit['created_at']?.toString()),
                hnObjectId: oid.isEmpty ? null : oid,
              ),
            );
          }
        }
      }
    } catch (_) {
      // Malformed/non-JSON body → no HN items (source skipped).
    }
    return ParsedFeed(sourceTitle: sourceName, items: items);
  }

  /// Flattens the first-level comments of a Hacker News Algolia item thread
  /// (`items/<objectID>` JSON) into bounded readable text for on-demand
  /// summarization. Returns '' on any malformed/empty input.
  String extractHnComments(String body, {int maxComments = 15}) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return '';
      final buffer = StringBuffer();
      var count = 0;
      final children = decoded['children'];
      if (children is List) {
        for (final child in children) {
          if (count >= maxComments) break;
          if (child is! Map) continue;
          final text = _clean((child['text'] ?? '').toString());
          if (text.isEmpty) continue;
          final author = (child['author'] ?? '').toString().trim();
          buffer.writeln(author.isNotEmpty ? '- $author: $text' : '- $text');
          count++;
        }
      }
      return _cap(buffer.toString().trim());
    } catch (_) {
      return '';
    }
  }

  /// The FEED/channel title = the first `<title>` OUTSIDE an item block. Since
  /// item titles also match, we take the first title that appears before the
  /// first `<item`/`<entry`.
  String? _firstTitle(String body) {
    final firstItem = _itemBlock.firstMatch(body);
    final scope = firstItem == null ? body : body.substring(0, firstItem.start);
    final m = _titleTag.firstMatch(scope) ?? _titleTag.firstMatch(body);
    final title = _clean(m?.group(1) ?? '');
    return title.isEmpty ? null : title;
  }

  String _clean(String raw) {
    // Unwrap any CDATA sections, keeping their inner content.
    var s = raw.replaceAllMapped(_cdata, (m) => m.group(1) ?? '');
    s = s.replaceAll(_anyTag, ' ');
    s = _decodeEntities(s);
    return s.replaceAll(_whitespace, ' ').trim();
  }

  /// Removes invisible non-whitespace and normalises surrounding space.
  ///
  /// For text that did NOT come from a feed — a small on-device model's output,
  /// for instance — where there are no tags to strip but the same invisible
  /// characters can still appear and indent the card for no visible reason.
  String stripInvisible(String s) =>
      s.replaceAll(_invisible, '').replaceAll(_whitespace, ' ').trim();

  /// Cleans + caps a per-item BRIEF description for the card. Handles feeds that
  /// double-encode HTML (escaped tags like `&lt;p&gt;` that only reappear AFTER
  /// entity decoding): strips tags, decodes entities, strips the revealed tags,
  /// decodes once more, collapses whitespace, then caps to [briefMaxChars] with
  /// an ellipsis. Public so the brief-cleaning is unit-testable on its own.
  String cleanBrief(String raw) {
    var s = raw.replaceAllMapped(_cdata, (m) => m.group(1) ?? '');
    s = s.replaceAll(_anyTag, ' '); // strip literal tags
    s = _decodeEntities(s); // escaped tags/entities reappear
    s = s.replaceAll(_anyTag, ' '); // strip the now-revealed tags
    s = _decodeEntities(s); // decode any remaining nested entities
    // Drop invisible non-whitespace BEFORE collapsing, so what is left is
    // ordinary space that collapse+trim can actually remove.
    s = s.replaceAll(_invisible, '');
    s = s.replaceAll(_whitespace, ' ').trim();
    if (s.length <= briefMaxChars) return s;
    return '${s.substring(0, briefMaxChars).trimRight()}…';
  }

  /// Characters that are INVISIBLE but are not Unicode whitespace, so neither
  /// [String.trim] nor `\s` removes them. A feed (or a small on-device model)
  /// that emits one at the start of a brief produces a card that looks
  /// mysteriously indented, with nothing in the text to explain it.
  static final RegExp _invisible = RegExp(
    r'[\u200B-\u200D\u2060\uFEFF\u180E\u2800]',
  );

  /// `&#160;` / `&#xA0;` — numeric entities of every codepoint. The named list
  /// below only ever covered a handful, so a numeric non-breaking space reached
  /// the card as the literal text "&#160;" instead of becoming a space that
  /// collapsing and trimming could then remove.
  static final RegExp _numericEntity = RegExp(r'&#(x[0-9a-fA-F]+|[0-9]+);');

  String _decodeEntities(String s) {
    var out = s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#8217;', "'")
        .replaceAll('&#8220;', '"')
        .replaceAll('&#8221;', '"');
    out = out.replaceAllMapped(_numericEntity, (m) {
      final raw = m.group(1)!;
      final code = raw.startsWith('x') || raw.startsWith('X')
          ? int.tryParse(raw.substring(1), radix: 16)
          : int.tryParse(raw);
      // Out-of-range or unparseable: leave it alone rather than corrupt text.
      if (code == null || code < 0x20 || code > 0x10FFFF) return m.group(0)!;
      return String.fromCharCode(code);
    });
    return out;
  }

  String _cap(String s) =>
      s.length <= maxChars ? s : '${s.substring(0, maxChars)}…';

  String _hostOf(String url) {
    try {
      final host = Uri.parse(url).host;
      return host.isEmpty ? url : host;
    } catch (_) {
      return url;
    }
  }
}
