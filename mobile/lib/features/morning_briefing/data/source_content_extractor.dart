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
  const SourceContentExtractor({this.maxItems = 6, this.maxChars = 1600});

  /// Max feed items to keep (top headlines).
  final int maxItems;

  /// Hard cap on the extracted text length — the on-device model is small
  /// (~512 output tokens), so we feed it a bounded chunk.
  final int maxChars;

  static final RegExp _itemBlock = RegExp(r'<(item|entry)\b[^>]*>(.*?)</\1>', dotAll: true, caseSensitive: false);
  static final RegExp _titleTag = RegExp(r'<title\b[^>]*>(.*?)</title>', dotAll: true, caseSensitive: false);
  static final RegExp _descTag =
      RegExp(r'<(description|summary|content)\b[^>]*>(.*?)</\1>', dotAll: true, caseSensitive: false);
  static final RegExp _h1Tag = RegExp(r'<h1\b[^>]*>(.*?)</h1>', dotAll: true, caseSensitive: false);
  static final RegExp _scriptStyle =
      RegExp(r'<(script|style)\b[^>]*>.*?</\1>', dotAll: true, caseSensitive: false);
  static final RegExp _anyTag = RegExp(r'<[^>]+>');
  static final RegExp _cdata = RegExp(r'<!\[CDATA\[(.*?)\]\]>', dotAll: true);
  static final RegExp _whitespace = RegExp(r'\s+');

  /// Whether [body] looks like an RSS/Atom/RDF feed (checked on the head so a
  /// stray `<rss>` mention deep in an HTML article never misclassifies it).
  bool looksLikeFeed(String body) {
    final head = body.length > 800 ? body.substring(0, 800).toLowerCase() : body.toLowerCase();
    return head.contains('<rss') ||
        head.contains('<feed') ||
        head.contains('<rdf:rdf') ||
        head.contains('<?xml') && (body.toLowerCase().contains('<item') || body.toLowerCase().contains('<entry'));
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
    return SourceExtract(title: feedTitle, text: _cap(buffer.toString().trim()));
  }

  SourceExtract _extractHtml(String body, {required String host}) {
    final title = _clean(_firstTitle(body) ?? _clean(_h1Tag.firstMatch(body)?.group(1) ?? ''));
    final withoutScripts = body.replaceAll(_scriptStyle, ' ');
    final stripped = _decodeEntities(withoutScripts.replaceAll(_anyTag, ' '));
    final text = stripped.replaceAll(_whitespace, ' ').trim();
    return SourceExtract(title: title.isNotEmpty ? title : host, text: _cap(text));
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

  String _decodeEntities(String s) => s
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

  String _cap(String s) => s.length <= maxChars ? s : '${s.substring(0, maxChars)}…';

  String _hostOf(String url) {
    try {
      final host = Uri.parse(url).host;
      return host.isEmpty ? url : host;
    } catch (_) {
      return url;
    }
  }
}
