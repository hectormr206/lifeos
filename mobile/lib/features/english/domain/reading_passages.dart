// Turning articles into passages worth reading, best fit first.
//
// A whole article is too long for one short session and too uneven to rate
// as one thing: a hard article can still hold a paragraph at the learner's
// level. So articles are cut into passages of a few paragraphs, each measured
// on its own against the placement (lexical_coverage.dart), and offered in
// order of fit.
//
// Sources are fixed per goal and openly licensed, and every passage keeps the
// article it came from so the reader can credit it (CC BY-SA requires it).
library;

import 'english_goal.dart';
import 'lexical_coverage.dart';

/// A passage is at least this long: enough context to guess a word from.
const int kPassageMinWords = 120;

/// And at most this long: one sitting, even at the 15-minute start.
const int kPassageMaxWords = 250;

/// Sections that are lists of links and citations, not prose to read.
final RegExp _backMatter = RegExp(
  r'^(references|related pages|other websites|see also|further reading|'
  r'notes|sources|external links|bibliography)$',
  caseSensitive: false,
);

final RegExp _heading = RegExp(r'^=+\s*(.*?)\s*=+$');
final RegExp _whitespace = RegExp(r'\s+');
final RegExp _sentence = RegExp(r'[^.!?]+[.!?]+(?=\s|$)|[^.!?]+$');

class Passage {
  const Passage({required this.text, required this.section});

  final String text;

  /// The heading it sits under in the article, empty before the first one.
  final String section;

  int get wordCount => _count(text);
}

int _count(String text) =>
    text.trim().isEmpty ? 0 : text.trim().split(_whitespace).length;

/// One passage and how well it fits the learner.
class RankedPassage {
  const RankedPassage({required this.passage, required this.report});

  final Passage passage;
  final CoverageReport report;
}

/// Cuts an article's plain text (MediaWiki `explaintext`: paragraphs on
/// lines, `== Heading ==` lines) into passages of [kPassageMinWords] to
/// [kPassageMaxWords] words. Back matter is dropped, and so is a leftover
/// too short to read on its own.
List<Passage> splitPassages(String text) {
  final passages = <Passage>[];
  final current = <String>[];
  var words = 0;
  var section = '';
  var currentSection = '';

  void close() {
    if (words >= kPassageMinWords) {
      passages.add(Passage(text: current.join('\n'), section: currentSection));
    }
    current.clear();
    words = 0;
  }

  void add(String piece) {
    final n = _count(piece);
    if (words > 0 && words + n > kPassageMaxWords && words >= kPassageMinWords) {
      close();
    }
    if (current.isEmpty) currentSection = section;
    current.add(piece);
    words += n;
  }

  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final heading = _heading.firstMatch(line);
    if (heading != null) {
      final name = heading.group(1)!;
      if (_backMatter.hasMatch(name)) break;
      if (words >= kPassageMinWords) close();
      section = name;
      continue;
    }
    if (_count(line) > kPassageMaxWords) {
      for (final sentence in _sentence.allMatches(line)) {
        add(sentence.group(0)!.trim());
      }
    } else {
      add(line);
    }
  }
  close();
  return passages;
}

/// Orders [passages] for the learner: at their level first (closest to the
/// middle of 95-98%), then easy ones (the least easy first), then hard ones
/// (the least hard first). Passages with fewer than [minWords] vocabulary
/// words are not offered: a list of names is not reading.
List<RankedPassage> rankPassages(
  List<Passage> passages,
  WordIndex index, {
  required List<double> knownByBand,
  int minWords = 60,
}) {
  const middle = (kEasyCoverage + kAtLevelCoverage) / 2;
  final ranked = [
    for (final passage in passages)
      RankedPassage(
        passage: passage,
        report: measureCoverage(passage.text, index, knownByBand: knownByBand),
      ),
  ]..removeWhere(
      (r) => r.report.fit == TextFit.empty || r.report.words < minWords);

  int group(TextFit fit) => switch (fit) {
        TextFit.atLevel => 0,
        TextFit.easy => 1,
        TextFit.hard => 2,
        TextFit.empty => 3,
      };
  double key(CoverageReport r) => switch (r.fit) {
        TextFit.atLevel => (r.coverage - middle).abs(),
        TextFit.easy => r.coverage,
        _ => -r.coverage,
      };

  return ranked
    ..sort((a, b) {
      final byGroup = group(a.report.fit).compareTo(group(b.report.fit));
      return byGroup != 0 ? byGroup : key(a.report).compareTo(key(b.report));
    });
}

/// One article on a MediaWiki site, fetched as plain text.
class ReadingArticle {
  const ReadingArticle({
    required this.site,
    required this.title,
    required this.license,
  });

  /// Host of the wiki, e.g. `simple.wikipedia.org`.
  final String site;
  final String title;

  /// Shown with the text: both sources require attribution.
  final String license;
}

const String _simpleWiki = 'simple.wikipedia.org';
const String _wikivoyage = 'en.wikivoyage.org';
const String _ccBySa = 'CC BY-SA';

ReadingArticle _simple(String title) =>
    ReadingArticle(site: _simpleWiki, title: title, license: _ccBySa);

ReadingArticle _voyage(String title) =>
    ReadingArticle(site: _wikivoyage, title: title, license: _ccBySa);

/// What there is to read for each goal. Every title was checked to exist and
/// to carry prose on 2026-09-25 ("Doctor" was dropped: 49 words).
final Map<EnglishGoal, List<ReadingArticle>> readingCatalog = {
  EnglishGoal.work: [
    for (final t in const [
      'Computer', 'Software', 'Computer programming', 'Database', 'Internet',
      'Email', 'Website', 'Job', 'Business', 'Money', 'Contract', 'Meeting',
    ])
      _simple(t),
  ],
  EnglishGoal.everyday: [
    for (final t in const [
      'Food', 'Cooking', 'Hospital', 'School', 'Family', 'Supermarket',
      'Weather', 'House', 'Sleep', 'Coffee', 'Bank',
    ])
      _simple(t),
  ],
  EnglishGoal.travel: [
    for (final t in const [
      'Tipping', 'Travel insurance', 'Stay healthy', 'At the airport',
      'Mexico City', 'New York City', 'London', 'Hotels', 'Rail travel',
      'Flying',
    ])
      _voyage(t),
  ],
};
