// The bundled pronunciation lexicon: complete, and every entry usable.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/pron_lexicon.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every pronunciation in the asset converts to IPA', () async {
    final text = await rootBundle.loadString(kPronLexiconAsset);
    final lines = text.trimRight().split('\n');

    expect(lines.length, greaterThan(60000));
    for (final line in lines) {
      final space = line.indexOf(' ');
      for (final variant in line.substring(space + 1).split('|')) {
        expect(() => arpabetToPhones(variant), returnsNormally, reason: line);
      }
    }
  });

  test('the words of a first lesson are there', () async {
    final lexicon = PronLexicon.parse(await rootBundle.loadString(kPronLexiconAsset));

    for (final word in ['the', 'think', 'very', 'ship', 'sheep', 'worked', "don't"]) {
      expect(lexicon.lookup(word), isNotEmpty, reason: word);
    }
  });
}
