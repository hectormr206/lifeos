// Proves the voice catalog domain: the 38 curated voices, the single shipped
// default (es_MX-claude), the derived hosted file names, the system-voice
// sentinel, and the region grouping (es-MX, es-ES, es-AR, en-US, en-GB).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/voice_settings/domain/voice_catalog.dart';

void main() {
  group('VoiceCatalog', () {
    test('holds exactly 38 voices (8 Spanish + 21 US + 9 UK)', () {
      expect(VoiceCatalog.all, hasLength(38));
      expect(VoiceCatalog.all.where((v) => v.languageTag == 'es-MX'), hasLength(2));
      expect(VoiceCatalog.all.where((v) => v.languageTag == 'es-ES'), hasLength(5));
      expect(VoiceCatalog.all.where((v) => v.languageTag == 'es-AR'), hasLength(1));
      expect(VoiceCatalog.all.where((v) => v.languageTag == 'en-US'), hasLength(21));
      expect(VoiceCatalog.all.where((v) => v.languageTag == 'en-GB'), hasLength(9));
    });

    test('every id is unique and matches the <locale>-<name> shape', () {
      final ids = VoiceCatalog.all.map((v) => v.id).toList();
      expect(ids.toSet(), hasLength(ids.length), reason: 'ids must be unique');
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[a-z]{2}_[A-Z]{2}-')), reason: id);
      }
    });

    test('the exact 38 hosted ids are present', () {
      expect(VoiceCatalog.all.map((v) => v.id).toSet(), {
        'es_MX-claude', 'es_MX-ald',
        'es_ES-davefx', 'es_ES-sharvard', 'es_ES-carlfm', 'es_ES-mls_9972', 'es_ES-mls_10246',
        'es_AR-daniela',
        'en_US-lessac', 'en_US-ryan', 'en_US-amy', 'en_US-libritts', 'en_US-libritts_r',
        'en_US-ljspeech', 'en_US-kristin', 'en_US-joe', 'en_US-john', 'en_US-kathleen',
        'en_US-hfc_female', 'en_US-hfc_male', 'en_US-arctic', 'en_US-bryce', 'en_US-danny',
        'en_US-kusal', 'en_US-l2arctic', 'en_US-mike', 'en_US-norman', 'en_US-reza_ibrahim',
        'en_US-sam',
        'en_GB-alan', 'en_GB-alba', 'en_GB-aru', 'en_GB-cori', 'en_GB-jenny_dioco',
        'en_GB-northern_english_male', 'en_GB-semaine', 'en_GB-southern_english_female',
        'en_GB-vctk',
      });
    });

    test('es_MX-claude is the one and only default, first in the list', () {
      expect(VoiceCatalog.defaultVoice.id, 'es_MX-claude');
      expect(VoiceCatalog.all.first.id, 'es_MX-claude');
      expect(VoiceCatalog.all.where((v) => v.isDefault), hasLength(1));
    });

    test('byId resolves a known voice and rejects an unknown one', () {
      expect(VoiceCatalog.byId('es_ES-davefx')?.displayName, 'Davefx (España)');
      expect(VoiceCatalog.byId('nope'), isNull);
      expect(VoiceCatalog.contains('en_US-lessac'), isTrue);
      expect(VoiceCatalog.contains('en_ZZ-none'), isFalse);
    });

    test('the system-voice sentinel is NOT a catalog voice', () {
      expect(VoiceCatalog.contains(VoiceCatalog.systemVoiceId), isFalse);
      expect(VoiceCatalog.byId(VoiceCatalog.systemVoiceId), isNull);
    });

    test('a descriptor derives its flat hosted file names + base language', () {
      final claude = VoiceCatalog.byId('es_MX-claude')!;
      expect(claude.modelFileName, 'es_MX-claude.onnx');
      expect(claude.configFileName, 'es_MX-claude.onnx.json');
      expect(claude.languageCode, 'es');
      expect(VoiceCatalog.byId('en_GB-alan')!.languageCode, 'en');
    });

    test('groups by language: Spanish (8) first, then English (30)', () {
      final groups = VoiceCatalog.groupedByLanguage;
      expect(groups.map((g) => g.languageCode), ['es', 'en']);
      expect(groups[0].voices, hasLength(8));
      expect(groups[1].voices, hasLength(30));
    });

    test('groups by region in declared order with correct counts', () {
      final groups = VoiceCatalog.groupedByRegion;
      expect(groups.map((g) => g.languageTag), ['es-MX', 'es-ES', 'es-AR', 'en-US', 'en-GB']);
      expect(groups.map((g) => g.voices.length), [2, 5, 1, 21, 9]);
      expect(groups.first.languageCode, 'es');
      expect(groups.last.languageCode, 'en');
    });

    test('a region group reports whether it contains a given voice', () {
      final mx = VoiceCatalog.groupedByRegion.first;
      expect(mx.contains('es_MX-claude'), isTrue);
      expect(mx.contains('en_US-lessac'), isFalse);
    });
  });
}
