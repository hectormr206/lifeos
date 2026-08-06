// Proves the ONE thing that matters about this store: an ordinary
// read/write/delete round-trips, and — the highest-value case per the
// owner's decision — a secure-storage backend that cannot actually store
// anything (e.g. Linux with no Secret Service daemon running; see
// tools/install-linux.sh's warning) makes [save] THROW rather than silently
// swallow, because a caller that ate this exception would leave the toggle
// looking "on" while nothing is stored to back up with.
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/backups/data/automatic_backup_passphrase_store.dart';

/// Simulates a Linux box with no gnome-keyring/kwallet running: every write
/// throws, exactly like the real `flutter_secure_storage` Linux backend does
/// against an unavailable Secret Service.
class _NoKeyringStorage extends FlutterSecureStorage {
  const _NoKeyringStorage();

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) =>
      throw PlatformException(
        code: 'Unexpected security exception',
        message: 'org.freedesktop.DBus.Error.ServiceUnknown: no Secret '
            'Service provider is running',
      );
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('round-trips a passphrase through secure storage', () async {
    final store = AutomaticBackupPassphraseStore(
      storage: const FlutterSecureStorage(),
    );

    await store.save('correct horse battery staple');

    expect(await store.load(), 'correct horse battery staple');
  });

  test('deleting removes it — nothing is left "sitting there"', () async {
    final store = AutomaticBackupPassphraseStore(
      storage: const FlutterSecureStorage(),
    );
    await store.save('correct horse battery staple');

    await store.delete();

    expect(await store.load(), isNull);
  });

  test('nothing saved yet → null, not an error', () async {
    final store = AutomaticBackupPassphraseStore(
      storage: const FlutterSecureStorage(),
    );
    expect(await store.load(), isNull);
  });

  test('a backend with no keyring makes save() THROW, never swallow',
      () async {
    final store =
        AutomaticBackupPassphraseStore(storage: const _NoKeyringStorage());

    await expectLater(
      () => store.save('correct horse battery staple'),
      throwsA(isA<PlatformException>()),
    );
  });
}
