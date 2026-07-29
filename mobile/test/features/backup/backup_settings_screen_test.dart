// Proves the screen a user sets up backups on: the irreversible warning is
// visible BEFORE the fields, and a failed check names the thing to fix rather
// than saying "error".
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/backup/data/backup_host_client.dart';
import 'package:lifeos/features/backup/data/backup_host_config_store.dart';
import 'package:lifeos/features/backup/presentation/backup_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Future<void> _pump(
  WidgetTester tester, {
  required ResponseBody Function(RequestOptions) respond,
}) async {
  SharedPreferences.setMockInitialValues({});
  // The package's own in-memory mock, as the rest of the suite uses.
  FlutterSecureStorage.setMockInitialValues({});
  final store = BackupHostConfigStore(
    prefs: await SharedPreferences.getInstance(),
  );
  final dio = Dio()..httpClientAdapter = _FakeAdapter(respond);

  await tester.pumpWidget(MaterialApp(
    home: BackupSettingsScreen(
      store: store,
      client: BackupHostClient(dio: dio),
    ),
  ));
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
}
