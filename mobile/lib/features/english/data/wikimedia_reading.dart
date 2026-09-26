// Fetching reading material from Wikimedia, as a polite client.
//
// Since 2026 Wikimedia rate-limits API clients by identity: a request whose
// User-Agent carries no contact gets 10 a minute, a compliant one 200
// (mediawiki.org/wiki/Wikimedia_APIs/Rate_limits). Choosing the titles for
// this feature hit HTTP 429 after ten requests for exactly that reason. So:
//   * the User-Agent names the app and gives the project URL as contact.
//     A URL and not a person's email, because every installation sends it;
//   * one request at a time, and only [kArticlesPerPick] articles per pick;
//   * a 429 or 503 stops the pick and reports how long to wait (Retry-After,
//     or at least five seconds when the server did not say).
library;

import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../domain/english_goal.dart';
import '../domain/lexical_coverage.dart';
import '../domain/reading_passages.dart';

/// Articles fetched to fill one reading list: enough passages to choose
/// from, few enough requests to stay well inside any limit.
const int kArticlesPerPick = 3;

/// Passages offered per pick.
const int kPassagesPerPick = 5;

/// Wikimedia's User-Agent policy asks for a contact: the public project URL.
const String kWikimediaUserAgent =
    'LifeOS/1.0 (https://github.com/hectormr206/lifeos)';

/// The minimum wait Wikimedia asks for when a 429/503 carries no Retry-After.
const Duration kDefaultRetryAfter = Duration(seconds: 5);

/// A GET reply with the parts the existing briefing fetcher hides: the status
/// and the headers, which are exactly what a 429 is about.
class HttpReply {
  const HttpReply({
    required this.status,
    required this.headers,
    required this.body,
  });

  final int status;

  /// Header names in lower case.
  final Map<String, String> headers;
  final String body;
}

abstract interface class HttpGetter {
  Future<HttpReply> get(Uri uri, {required Map<String, String> headers});
}

/// The server asked to slow down.
class RateLimited implements Exception {
  const RateLimited(this.retryAfter);

  final Duration retryAfter;

  @override
  String toString() => 'RateLimited(retry after ${retryAfter.inSeconds}s)';
}

/// The plain text of one article.
abstract interface class ArticleTextSource {
  /// Null when the article does not exist.
  Future<String?> fetchText(ReadingArticle article);
}

class WikimediaArticleSource implements ArticleTextSource {
  WikimediaArticleSource(this._http);

  final HttpGetter _http;

  @override
  Future<String?> fetchText(ReadingArticle article) async {
    final uri = Uri.https(article.site, '/w/api.php', {
      'action': 'query',
      'prop': 'extracts',
      'explaintext': '1',
      'redirects': '1',
      'format': 'json',
      'formatversion': '2',
      'titles': article.title,
    });
    final reply = await _http.get(uri, headers: const {
      'User-Agent': kWikimediaUserAgent,
    });
    if (reply.status == 429 || reply.status == 503) {
      final seconds = int.tryParse(reply.headers['retry-after'] ?? '');
      throw RateLimited(
        seconds == null ? kDefaultRetryAfter : Duration(seconds: seconds),
      );
    }
    if (reply.status != 200) {
      throw HttpException(reply.status, uri);
    }
    final pages = (jsonDecode(reply.body) as Map)['query']?['pages'];
    if (pages is! List || pages.isEmpty) return null;
    final page = pages.first as Map;
    if (page['missing'] == true) return null;
    final extract = page['extract'];
    return extract is String && extract.trim().isNotEmpty ? extract : null;
  }
}

class HttpException implements Exception {
  const HttpException(this.status, this.uri);

  final int status;
  final Uri uri;

  @override
  String toString() => 'HTTP $status for $uri';
}

/// The real HTTP client. Never throws on a status: the caller decides.
class DioHttpGetter implements HttpGetter {
  DioHttpGetter([Dio? dio])
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              responseType: ResponseType.plain,
              validateStatus: (_) => true,
            ));

  final Dio _dio;

  @override
  Future<HttpReply> get(Uri uri, {required Map<String, String> headers}) async {
    final response = await _dio.getUri<String>(
      uri,
      options: Options(headers: headers),
    );
    return HttpReply(
      status: response.statusCode ?? 0,
      headers: {
        for (final entry in response.headers.map.entries)
          entry.key.toLowerCase(): entry.value.join(','),
      },
      body: response.data ?? '',
    );
  }
}

/// One passage to offer, with the article to credit.
class PickedReading {
  const PickedReading({required this.article, required this.ranked});

  final ReadingArticle article;
  final RankedPassage ranked;
}

/// Fills a reading list for a goal: a few articles, cut into passages,
/// ranked against the learner's placement.
class ReadingSelector {
  ReadingSelector(this._source, {Random? random}) : _random = random ?? Random();

  final ArticleTextSource _source;
  final Random _random;

  /// The best [kPassagesPerPick] passages for [goal]. A rate limit keeps
  /// whatever already arrived and stops asking; with nothing arrived, it is
  /// rethrown so the screen can say when to try again.
  Future<List<PickedReading>> pick(
    EnglishGoal goal,
    WordIndex index, {
    required List<double> knownByBand,
  }) async {
    final articles = [...readingCatalog[goal]!]..shuffle(_random);
    final articleOf = <Passage, ReadingArticle>{};
    var fetched = 0;
    for (final article in articles) {
      if (fetched == kArticlesPerPick) break;
      final String? text;
      try {
        text = await _source.fetchText(article);
      } on RateLimited {
        if (articleOf.isEmpty) rethrow;
        break;
      }
      fetched++;
      if (text == null) continue;
      for (final passage in splitPassages(text)) {
        articleOf[passage] = article;
      }
    }
    final ranked = rankPassages(
      articleOf.keys.toList(),
      index,
      knownByBand: knownByBand,
    );
    return [
      for (final r in ranked.take(kPassagesPerPick))
        PickedReading(article: articleOf[r.passage]!, ranked: r),
    ];
  }
}
