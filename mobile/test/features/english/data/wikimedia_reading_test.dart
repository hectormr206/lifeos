// Fetching reading material from Wikimedia, as a polite client.
//
// Wikimedia rate-limits API clients since 2026: a request with no contact in
// its User-Agent gets 10 a minute, one with a compliant User-Agent gets 200.
// This was hit for real while choosing the titles (HTTP 429 after ten
// requests), so these tests pin the behaviour that avoids it: a User-Agent
// with a contact URL, one request at a time, and Retry-After respected.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/wikimedia_reading.dart';
import 'package:lifeos/features/english/domain/english_goal.dart';
import 'package:lifeos/features/english/domain/lexical_coverage.dart';
import 'package:lifeos/features/english/domain/reading_passages.dart';
import 'package:lifeos/features/english/domain/vocab_placement_session.dart';

class _FakeHttp implements HttpGetter {
  _FakeHttp(this.reply);

  final HttpReply Function(Uri uri) reply;
  final List<Uri> requested = [];
  Map<String, String> lastHeaders = const {};

  @override
  Future<HttpReply> get(Uri uri, {required Map<String, String> headers}) async {
    requested.add(uri);
    lastHeaders = headers;
    return reply(uri);
  }
}

HttpReply _page(String title, String extract) => HttpReply(
      status: 200,
      headers: const {},
      body: '{"query":{"pages":[{"title":"$title","extract":"$extract"}]}}',
    );

const _article = ReadingArticle(
  site: 'simple.wikipedia.org',
  title: 'Rail travel',
  license: 'CC BY-SA',
);

void main() {
  group('asking Wikimedia for an article', () {
    test('it asks for plain text of one page, on the right wiki', () async {
      final http = _FakeHttp((_) => _page('Rail travel', 'Trains go.'));

      await WikimediaArticleSource(http).fetchText(_article);

      final uri = http.requested.single;
      expect(uri.host, 'simple.wikipedia.org');
      expect(uri.path, '/w/api.php');
      expect(uri.queryParameters['titles'], 'Rail travel');
      expect(uri.queryParameters['explaintext'], '1');
      expect(uri.queryParameters['formatversion'], '2');
    });

    test('it says who is asking and how to reach them', () async {
      final http = _FakeHttp((_) => _page('Rail travel', 'Trains go.'));

      await WikimediaArticleSource(http).fetchText(_article);

      expect(http.lastHeaders['User-Agent'],
          contains('https://github.com/hectormr206/lifeos'));
    });

    test('it returns the article text', () async {
      final http = _FakeHttp((_) => _page('Rail travel', 'Trains go.'));

      expect(await WikimediaArticleSource(http).fetchText(_article),
          'Trains go.');
    });

    test('a page that does not exist is no text, not an error', () async {
      final http = _FakeHttp((_) => const HttpReply(
            status: 200,
            headers: {},
            body: '{"query":{"pages":[{"title":"Nope","missing":true}]}}',
          ));

      expect(await WikimediaArticleSource(http).fetchText(_article), isNull);
    });

    test('a 429 says how long to wait, as the server asked', () async {
      final http = _FakeHttp((_) => const HttpReply(
            status: 429,
            headers: {'retry-after': '30'},
            body: 'You are making too many requests',
          ));

      await expectLater(
        WikimediaArticleSource(http).fetchText(_article),
        throwsA(isA<RateLimited>().having(
            (e) => e.retryAfter, 'retryAfter', const Duration(seconds: 30))),
      );
    });

    test('without Retry-After it waits at least five seconds', () async {
      final http = _FakeHttp((_) =>
          const HttpReply(status: 503, headers: {}, body: 'busy'));

      await expectLater(
        WikimediaArticleSource(http).fetchText(_article),
        throwsA(isA<RateLimited>().having(
            (e) => e.retryAfter, 'retryAfter', const Duration(seconds: 5))),
      );
    });
  });

  group('picking passages to read', () {
    final index = WordIndex(const VocabBank(
      bands: [
        ['the', 'go', 'to', 'river', 'train', 'city', 'and', 'is', 'a'],
      ],
      pseudowords: [],
    ));
    // 130 words, all known: an easy passage.
    final prose = List.filled(26, 'the train go to the city.').join(' ');

    test('it reads a few articles, one at a time', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final source = _FakeSource((article) async {
        inFlight++;
        maxInFlight = max(maxInFlight, inFlight);
        await Future<void>.delayed(Duration.zero);
        inFlight--;
        return prose;
      });

      await ReadingSelector(source, random: Random(1)).pick(
        EnglishGoal.everyday,
        index,
        knownByBand: const [1.0],
      );

      expect(source.fetched, hasLength(kArticlesPerPick));
      expect(maxInFlight, 1);
    });

    test('each passage keeps the article it came from', () async {
      final source = _FakeSource((_) async => prose);

      final picked = await ReadingSelector(source, random: Random(2)).pick(
        EnglishGoal.travel,
        index,
        knownByBand: const [1.0],
      );

      expect(picked, isNotEmpty);
      for (final reading in picked) {
        expect(readingCatalog[EnglishGoal.travel], contains(reading.article));
      }
    });

    test('a rate limit after some articles keeps what already arrived',
        () async {
      var calls = 0;
      final source = _FakeSource((_) async {
        if (++calls > 1) throw const RateLimited(Duration(seconds: 5));
        return prose;
      });

      final picked = await ReadingSelector(source, random: Random(3)).pick(
        EnglishGoal.work,
        index,
        knownByBand: const [1.0],
      );

      expect(picked, isNotEmpty);
      expect(calls, 2, reason: 'it stops asking once told to slow down');
    });

    test('a rate limit before anything arrived is reported', () async {
      final source = _FakeSource(
          (_) async => throw const RateLimited(Duration(seconds: 5)));

      await expectLater(
        ReadingSelector(source, random: Random(4)).pick(
          EnglishGoal.work,
          index,
          knownByBand: const [1.0],
        ),
        throwsA(isA<RateLimited>()),
      );
    });
  });
}

class _FakeSource implements ArticleTextSource {
  _FakeSource(this._text);

  final Future<String?> Function(ReadingArticle article) _text;
  final List<ReadingArticle> fetched = [];

  @override
  Future<String?> fetchText(ReadingArticle article) {
    fetched.add(article);
    return _text(article);
  }
}
