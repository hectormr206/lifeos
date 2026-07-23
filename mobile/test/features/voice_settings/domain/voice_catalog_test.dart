// Proves the voice catalog domain: the six curated voices, the single shipped
// default (es_MX-claude), the derived hosted file names, and the language
// grouping (Spanish first, then English).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/voice_settings/domain/voice_catalog.dart';

void main() {
  group('VoiceCatalog', () {
    test('holds exactly the six curated voices', () {
      expect(VoiceCatalog.all.map((v) => v.id), [
        'es_MX-claude',
        'es_MX-ald',
        'es_AR-daniela',
        'es_ES-davefx',
        'en_US-lessac',
        'en_GB-alan',
      ]);
    });

    test('es_MX-claude is the one and only default', () {
      expect(VoiceCatalog.defaultVoice.id, 'es_MX-claude');
      expect(VoiceCatalog.all.where((v) => v.isDefault), hasLength(1));
    });

    test('byId resolves a known voice and rejects an unknown one', () {
      expect(VoiceCatalog.byId('es_ES-davefx')?.displayName, 'Davefx (España)');
      expect(VoiceCatalog.byId('nope'), isNull);
      expect(VoiceCatalog.contains('en_US-lessac'), isTrue);
      expect(VoiceCatalog.contains('en_ZZ-none'), isFalse);
    });

    test('a descriptor derives its flat hosted file names + base language', () {
      final claude = VoiceCatalog.byId('es_MX-claude')!;
      expect(claude.modelFileName, 'es_MX-claude.onnx');
      expect(claude.configFileName, 'es_MX-claude.onnx.json');
      expect(claude.languageCode, 'es');
      expect(VoiceCatalog.byId('en_GB-alan')!.languageCode, 'en');
    });

    test('groups by language: Spanish (4) first, then English (2)', () {
      final groups = VoiceCatalog.groupedByLanguage;
      expect(groups.map((g) => g.languageCode), ['es', 'en']);
      expect(groups[0].voices, hasLength(4));
      expect(groups[1].voices, hasLength(2));
      expect(groups[1].voices.map((v) => v.id), ['en_US-lessac', 'en_GB-alan']);
    });
  });
}
