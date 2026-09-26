// The phone model (ZIPA) is fetched on first use and verified byte for byte.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/pron_model.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('pron-model'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('PronModelSourceConfig', () {
    test('the placeholder base URL is not configured; a real one is', () {
      expect(const PronModelSourceConfig().isConfigured, isFalse);
      expect(const PronModelSourceConfig(baseUrl: '').isConfigured, isFalse);
      expect(
        const PronModelSourceConfig(baseUrl: 'https://models.example/lifeos/pron')
            .isConfigured,
        isTrue,
      );
    });

    test('it names the exact files that were measured', () {
      const config = PronModelSourceConfig();

      expect(config.model.bytes, 70677672);
      expect(config.model.sha256,
          'd0e28b68164e8b1fbd6105100c01798828aa0855000ce9bbbd1a2cec233adf13');
      expect(config.tokens.bytes, 769);
      expect(config.files, [config.model, config.tokens]);
    });
  });

  group('verifyModelFile', () {
    PronModelFile expecting(String content) => PronModelFile(
          name: 'f.txt',
          bytes: content.length,
          sha256: sha256.convert(content.codeUnits).toString(),
        );

    test('the right bytes pass', () async {
      final file = File('${dir.path}/f.txt')..writeAsStringSync('tokens');
      expect(await verifyModelFile(file, expecting('tokens')), isTrue);
    });

    test('same size, other bytes: refused', () async {
      final file = File('${dir.path}/f.txt')..writeAsStringSync('tokenZ');
      expect(await verifyModelFile(file, expecting('tokens')), isFalse);
    });

    test('a missing file is refused, not an error', () async {
      expect(await verifyModelFile(File('${dir.path}/none'), expecting('x')),
          isFalse);
    });
  });

  group('installedModel', () {
    const config = PronModelSourceConfig(
      model: PronModelFile(name: 'm.onnx', bytes: 3, sha256: 'unused'),
      tokens: PronModelFile(name: 't.txt', bytes: 2, sha256: 'unused'),
    );

    BackgroundDownloaderPronModelGateway gateway() =>
        BackgroundDownloaderPronModelGateway(
          config: config,
          directory: () async => dir,
        );

    test('both files at their size: the paths', () async {
      File('${dir.path}/m.onnx').writeAsStringSync('abc');
      File('${dir.path}/t.txt').writeAsStringSync('ab');

      final paths = await gateway().installedModel();
      expect(paths?.model, '${dir.path}/m.onnx');
      expect(paths?.tokens, '${dir.path}/t.txt');
    });

    test('a file missing or cut short: not installed', () async {
      File('${dir.path}/m.onnx').writeAsStringSync('ab');
      File('${dir.path}/t.txt').writeAsStringSync('ab');
      expect(await gateway().installedModel(), isNull);

      File('${dir.path}/m.onnx').deleteSync();
      expect(await gateway().installedModel(), isNull);
    });
  });
}
