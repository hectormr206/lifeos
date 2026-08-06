// Proves the screen a user sets up backups on: the irreversible warning is
// visible BEFORE the fields, and a failed check names the thing to fix rather
// than saying "error".
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/backup/data/backup_host_client.dart';
import 'package:lifeos/features/backup/data/backup_host_config_store.dart';
import 'package:lifeos/features/backup/presentation/backup_settings_screen.dart';
import 'package:lifeos/features/backup/presentation/passphrase_dialog.dart';
import 'package:lifeos/features/backups/data/automatic_backup_passphrase_store.dart';
import 'package:lifeos/features/backups/data/automatic_backup_settings_store.dart';
import 'package:lifeos/features/backups/data/automatic_backup_status_store.dart';
import 'package:lifeos/features/backups/domain/automatic_backup_outcome.dart';
import 'package:lifeos/features/backups/domain/automatic_backup_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Simulates a Linux box with no gnome-keyring/kwallet running — every write
/// throws, exactly like the real Linux Secret Service backend does when no
/// provider is available (see `tools/install-linux.sh`'s warning).
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
        message: 'no Secret Service provider is running',
      );
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions) handler;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<dynamic>? stream,
          Future<void>? cancelFuture) async =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

Future<
    ({
      AutomaticBackupSettingsStore settings,
      AutomaticBackupStatusStore status,
      AutomaticBackupPassphraseStore passphrase,
    })> _pump(
  WidgetTester tester, {
  required ResponseBody Function(RequestOptions) respond,
  AutomaticBackupStatus? automaticStatus,
  bool automaticEnabled = false,
  FlutterSecureStorage? passphraseStorage,
}) async {
  SharedPreferences.setMockInitialValues({});
  // The package's own in-memory mock, as the rest of the suite uses.
  FlutterSecureStorage.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = BackupHostConfigStore(prefs: prefs);
  final dio = Dio()..httpClientAdapter = _FakeAdapter(respond);
  final automaticSettings = AutomaticBackupSettingsStore(prefs: prefs);
  final automaticStatusStore = AutomaticBackupStatusStore(prefs: prefs);
  final automaticPassphraseStore = AutomaticBackupPassphraseStore(
    storage: passphraseStorage ?? const FlutterSecureStorage(),
  );
  if (automaticStatus != null) {
    await automaticStatusStore.record(automaticStatus);
  }
  await automaticSettings.setEnabled(automaticEnabled);

  await tester.pumpWidget(MaterialApp(
    home: BackupSettingsScreen(
      store: store,
      client: BackupHostClient(dio: dio),
      automaticSettingsStore: automaticSettings,
      automaticStatusStore: automaticStatusStore,
      automaticPassphraseStore: automaticPassphraseStore,
    ),
  ));
  await tester.pumpAndSettle();
  return (
    settings: automaticSettings,
    status: automaticStatusStore,
    passphrase: automaticPassphraseStore,
  );
}

/// Reveals + taps the toggle (below the fold — see the earlier note on
/// `skipOffstage`), so every test that flips it starts from the same place.
Future<void> _tapToggle(WidgetTester tester) async {
  final toggle = find.byType(SwitchListTile, skipOffstage: false);
  await tester.ensureVisible(toggle);
  await tester.pumpAndSettle();
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('warns that a lost passphrase is unrecoverable, up front',
      (tester) async {
    await _pump(tester, respond: (_) => ResponseBody.fromString('{}', 200));

    expect(find.textContaining('se pierden para siempre'), findsOneWidget);
    // Above the fields: a warning read after the fact is not a warning.
    final warning = tester.getTopLeft(
      find.textContaining('se pierden para siempre'),
    );
    final address = tester.getTopLeft(find.byType(TextField).first);
    expect(warning.dy, lessThan(address.dy));
  });

  testWidgets('an unreachable host tells the user to check the VPN',
      (tester) async {
    await _pump(
      tester,
      respond: (options) => throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      ),
    );

    await tester.enterText(find.byType(TextField).first, 'http://10.66.66.1:8099');
    await tester.enterText(find.byType(TextField).last, 'k' * 32);
    await tester.tap(find.text('Comprobar conexión'));
    await tester.pumpAndSettle();

    // Specific to the diagnosis: the address field's helper also mentions the
    // VPN, so a bare 'VPN' would pass even with no diagnosis shown at all.
    expect(find.textContaining('esté conectado a la VPN'), findsOneWidget);
  });

  testWidgets('a rejected key blames the key, not the connection',
      (tester) async {
    await _pump(tester, respond: (options) {
      if (options.path.endsWith('/v1/health')) {
        return ResponseBody.fromString(
          '{"service":"lifeos-backup-host","version":1}',
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      return ResponseBody.fromString('{"error":"unauthorised"}', 401, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });
    });

    await tester.enterText(find.byType(TextField).first, 'http://10.66.66.1:8099');
    await tester.enterText(find.byType(TextField).last, 'mala');
    await tester.tap(find.text('Comprobar conexión'));
    await tester.pumpAndSettle();

    expect(find.textContaining('rechazó la clave'), findsOneWidget);
  });

  testWidgets('a healthy host shows it is ready, and the room left',
      (tester) async {
    await _pump(tester, respond: (options) {
      final body = options.path.endsWith('/v1/health')
          ? '{"service":"lifeos-backup-host","version":1}'
          : '{"writable":true,"backups":2,"freeBytes":214748364800,'
              '"maxUploadBytes":1024}';
      return ResponseBody.fromString(body, 200, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });
    });

    await tester.enterText(find.byType(TextField).first, 'http://10.66.66.1:8099');
    await tester.enterText(find.byType(TextField).last, 'k' * 32);
    await tester.tap(find.text('Comprobar conexión'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Listo para respaldar'), findsOneWidget);
    expect(find.textContaining('200.0 GB libres'), findsOneWidget);
    expect(find.textContaining('2 respaldos'), findsOneWidget);
  });

  testWidgets('automatic backups start OFF — nothing was ever captured to seal with',
      (tester) async {
    await _pump(tester, respond: (_) => ResponseBody.fromString('{}', 200));

    // The toggle sits below the fold of this long settings screen — still
    // built (ListView(children:) is eager, not lazy), just not painted.
    final toggle = find.byType(SwitchListTile, skipOffstage: false);
    expect(toggle, findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
  });

  testWidgets(
      'turning ON prompts for the passphrase, stores it, and ONLY THEN '
      'flips the switch', (tester) async {
    final stores = await _pump(
      tester,
      respond: (_) => ResponseBody.fromString('{}', 200),
    );

    await _tapToggle(tester);
    expect(find.byType(PassphraseDialog), findsOneWidget,
        reason: 'must ask for the phrase BEFORE the switch can turn on');

    final fields = find.descendant(
      of: find.byType(PassphraseDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.first, 'correct horse battery staple');
    await tester.enterText(fields.last, 'correct horse battery staple');
    await tester.tap(find.text('Activar'));
    await tester.pumpAndSettle();

    final toggle = find.byType(SwitchListTile, skipOffstage: false);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(await stores.settings.isEnabled(), isTrue);
    expect(await stores.passphrase.load(), 'correct horse battery staple');
  });

  testWidgets(
      'backing out of the passphrase prompt leaves the switch OFF',
      (tester) async {
    final stores = await _pump(
      tester,
      respond: (_) => ResponseBody.fromString('{}', 200),
    );

    await _tapToggle(tester);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    final toggle = find.byType(SwitchListTile, skipOffstage: false);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(await stores.settings.isEnabled(), isFalse);
    expect(await stores.passphrase.load(), isNull);
  });

  testWidgets(
      'no Secret Service / keyring on this device → turning ON fails '
      'LOUDLY naming the missing keyring, switch stays OFF',
      (tester) async {
    final stores = await _pump(
      tester,
      respond: (_) => ResponseBody.fromString('{}', 200),
      passphraseStorage: const _NoKeyringStorage(),
    );

    await _tapToggle(tester);
    final fields = find.descendant(
      of: find.byType(PassphraseDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.first, 'correct horse battery staple');
    await tester.enterText(fields.last, 'correct horse battery staple');
    await tester.tap(find.text('Activar'));
    await tester.pumpAndSettle();

    // Names the actual missing component — not a generic "algo salió mal".
    expect(find.textContaining('gestor de llaves'), findsOneWidget);
    // Never the secret itself, in any error path.
    expect(find.textContaining('correct horse battery staple'), findsNothing);

    final toggle = find.byType(SwitchListTile, skipOffstage: false);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse,
        reason: 'the switch must not appear enabled when the secret could '
            'not actually be stored');
    expect(await stores.settings.isEnabled(), isFalse);
  });

  testWidgets('turning OFF deletes the stored passphrase — "off" is not a lie',
      (tester) async {
    final stores = await _pump(
      tester,
      respond: (_) => ResponseBody.fromString('{}', 200),
      automaticEnabled: true,
    );
    await stores.passphrase.save('correct horse battery staple');

    await _tapToggle(tester);

    final toggle = find.byType(SwitchListTile, skipOffstage: false);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(await stores.settings.isEnabled(), isFalse);
    expect(await stores.passphrase.load(), isNull);
  });

  testWidgets(
      'a missing passphrase at run time is surfaced distinctly from an '
      'offline VPN or an ordinary failure', (tester) async {
    await _pump(
      tester,
      respond: (_) => ResponseBody.fromString('{}', 200),
      automaticStatus: AutomaticBackupStatus(
        outcome: AutomaticBackupOutcome.passphraseUnavailable,
        at: DateTime(2026, 7, 30, 9),
      ),
    );

    expect(
      find.textContaining('no se pudo leer la frase', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('an undetermined VPN check is surfaced loudly, not as a plain skip',
      (tester) async {
    await _pump(
      tester,
      respond: (_) => ResponseBody.fromString('{}', 200),
      automaticStatus: AutomaticBackupStatus(
        outcome: AutomaticBackupOutcome.skippedVpnUnknown,
        at: DateTime(2026, 7, 30, 9),
      ),
    );

    expect(find.textContaining('No se pudo determinar', skipOffstage: false),
        findsOneWidget);
  });

  testWidgets('a failed automatic backup surfaces the same as a manual failure',
      (tester) async {
    await _pump(
      tester,
      respond: (_) => ResponseBody.fromString('{}', 200),
      automaticStatus: AutomaticBackupStatus(
        outcome: AutomaticBackupOutcome.failed,
        at: DateTime(2026, 7, 30, 9),
        message: 'se cortó la conexión',
      ),
    );

    expect(find.textContaining('se cortó la conexión', skipOffstage: false),
        findsOneWidget);
  });
}
