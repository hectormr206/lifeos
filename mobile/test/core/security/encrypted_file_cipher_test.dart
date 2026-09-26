import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/outbox/outbox.dart';
import 'package:lifeos/core/security/encrypted_file_cipher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final originalKey = List.filled(32, '07').join();
  late String? stored;
  late bool unavailable;
  late int writes;

  setUp(() {
    stored = originalKey;
    unavailable = false;
    writes = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'read') {
        expect(
          (call.arguments as Map)['key'],
          'lifeos.auxiliary_files.aes256gcm_key',
        );
        if (unavailable) throw PlatformException(code: 'locked');
        return stored;
      }
      if (call.method == 'write') {
        writes++;
        stored = (call.arguments as Map)['value'] as String?;
        return null;
      }
      throw StateError('Unexpected secure storage method: ${call.method}');
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final keyState in ['missing', 'short', 'nonhex', 'unavailable']) {
    void loseKey() {
      stored = switch (keyState) {
        'missing' => null,
        'short' => '07',
        'nonhex' => List.filled(64, 'z').join(),
        _ => originalKey,
      };
      unavailable = keyState == 'unavailable';
    }

    test(
      'encrypted read with $keyState key never writes a replacement',
      () async {
        final cipher = EncryptedFileCipher();
        final envelope = await cipher.seal([1, 2, 3]);
        loseKey();
        // The existing nullable API may retain null for failed decryption.
        expect(await cipher.openOrLegacy(envelope), isNull);
        expect(writes, 0);
        unavailable = false;
        stored = originalKey;
        expect(await cipher.openOrLegacy(envelope), [1, 2, 3]);
      },
    );

    for (final operation in ['list', 'enqueue', 'remove']) {
      test(
        '$operation with $keyState key preserves recoverable queue',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'outbox_key_test_',
          );
          addTearDown(() => directory.delete(recursive: true));
          final outbox = FileOutbox(directoryProvider: () async => directory);
          final entry = await outbox.enqueue(
            httpMethod: 'POST',
            path: '/original',
          );
          final file = File('${directory.path}/outbox/outbox.json');
          final original = await file.readAsBytes();
          loseKey();
          final Future<Object?> result = switch (operation) {
            'list' => outbox.list(),
            'enqueue' => outbox.enqueue(httpMethod: 'POST', path: '/new'),
            _ => outbox.remove(entry.id),
          };
          await expectLater(result, throwsA(isA<OutboxStorageException>()));
          expect(await file.readAsBytes(), original);
          expect(writes, 0);
          unavailable = false;
          stored = originalKey;
          expect(await outbox.list(), [entry]);
          expect(await file.readAsBytes(), original);
        },
      );
    }
  }
}
