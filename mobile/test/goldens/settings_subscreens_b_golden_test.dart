// Settings sub-screens, batch B (sync, recovery phrase, backups, backup server,
// danger zone, memory graph). Every screen is pumped against fakes: no network,
// no keystore, no database.
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/core/graph/graph_providers.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/core/widgets/widgets.dart';
import 'package:lifeos/features/backup/data/backup_host_client.dart';
import 'package:lifeos/features/backup/data/backup_host_config_store.dart';
import 'package:lifeos/features/backup/presentation/backup_settings_screen.dart';
import 'package:lifeos/features/backups/data/automatic_backup_passphrase_store.dart';
import 'package:lifeos/features/backups/data/automatic_backup_settings_store.dart';
import 'package:lifeos/features/backups/data/automatic_backup_status_store.dart';
import 'package:lifeos/features/backups/data/workmanager_automatic_backup_work.dart';
import 'package:lifeos/features/data_control/domain/backup_info.dart';
import 'package:lifeos/features/data_control/presentation/backups_screen.dart';
import 'package:lifeos/features/data_control/presentation/danger_zone_menu_screen.dart';
import 'package:lifeos/features/data_control/presentation/danger_zone_screen.dart';
import 'package:lifeos/features/data_control/presentation/data_control_providers.dart';
import 'package:lifeos/features/graph/presentation/local_graph_browser_screen.dart';
import 'package:lifeos/features/graph/presentation/local_graph_node_screen.dart';
import 'package:lifeos/features/sync/data/sync_status_store.dart';
import 'package:lifeos/features/sync/domain/phrase_ceremony.dart';
import 'package:lifeos/features/sync/domain/sync_connectivity.dart';
import 'package:lifeos/features/sync/presentation/phrase_ceremony_screen.dart';
import 'package:lifeos/features/sync/presentation/sync_settings_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/theme/lifeos_tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'support/golden_harness.dart';

class _Adapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<dynamic>? stream,
      Future<void>? cancelFuture) async {
    final body = options.path.endsWith('/v1/health')
        ? '{"service":"lifeos-backup-host","version":1}'
        : '{"writable":true,"backups":2,"freeBytes":214748364800,'
            '"maxUploadBytes":1024}';
    return ResponseBody.fromString(body, 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

class _Workmanager implements Workmanager {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

GraphNodeRecord _node(String uuid, String kind, String label,
    {String? domain, Map<String, Object?> data = const {}, int day = 1}) {
  final at = DateTime.utc(2026, 7, day);
  return GraphNodeRecord(
    uuid: uuid,
    kind: kind,
    label: label,
    domain: domain,
    data: data,
    createdAt: at,
    updatedAt: at,
  );
}

final _nodes = [
  _node('n1', 'fact', 'Prefiere el café sin azúcar', domain: 'health', day: 20),
  _node('n2', 'person', 'Marta Ríos', domain: 'relationships', day: 18),
  _node('n3', 'event', 'Cita con el dentista', domain: 'health', day: 12),
  _node('n4', 'conversation', 'Plan de la semana', day: 9),
];

class _Store implements LocalGraphStore {
  @override
  Future<List<GraphNodeRecord>> listNodesByKind(String kind,
          {int? limit, bool includeDeleted = false}) async =>
      _nodes.where((n) => n.kind == kind).toList();

  @override
  Future<GraphNodeRecord?> getNodeByUuid(String uuid,
      {bool includeDeleted = false}) async {
    if (uuid == 'n1') {
      return _node('n1', 'fact', 'Prefiere el café sin azúcar',
          domain: 'health',
          day: 20,
          data: const {'text': 'Toma el café sin azúcar', 'source': 'chat'});
    }
    for (final n in _nodes) {
      if (n.uuid == uuid) return n;
    }
    return null;
  }

  @override
  Future<List<GraphEdgeRecord>> edgesForNode(String nodeUuid,
      {EdgeDirection direction = EdgeDirection.both,
      String? relation,
      bool includeDeleted = false}) async {
    if (nodeUuid != 'n1') return const [];
    final at = DateTime.utc(2026, 7, 20);
    return [
      GraphEdgeRecord(
        uuid: 'e1',
        srcUuid: 'n1',
        dstUuid: 'n2',
        relation: 'mentions',
        createdAt: at,
        updatedAt: at,
      ),
    ];
  }

  @override
  Future<List<GraphNodeRecord>> searchNodes(String query,
          {int limit = 20, bool includeDeleted = false}) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Widget _app(Widget screen, [List<Override> overrides = const []]) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: goldenTheme(),
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child ?? const SizedBox.shrink(),
        ),
        routerConfig: GoRouter(routes: [
          GoRoute(path: '/', builder: (context, state) => screen),
          GoRoute(
              path: '/settings/graph/:uuid',
              builder: (context, state) => const SizedBox()),
        ]),
      ),
    );

final _backups = <BackupInfo>[
  BackupInfo(
    path: '/b/auto-1.db',
    kind: BackupKind.auto,
    createdAt: DateTime(2026, 7, 21, 8, 30),
    sizeBytes: 3 * 1024 * 1024,
  ),
  BackupInfo(
    path: '/b/manual-1.db',
    kind: BackupKind.manual,
    createdAt: DateTime(2026, 7, 19, 21, 5),
    sizeBytes: 2 * 1024 * 1024 + 300 * 1024,
  ),
  BackupInfo(
    path: '/b/pre-1.db',
    kind: BackupKind.preRestore,
    createdAt: DateTime(2026, 7, 10, 9, 0),
    sizeBytes: 900 * 1024,
  ),
];

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    List<Override> overrides = const [],
    bool wide = false,
    double? tall,
  }) async {
    useGoldenSurface(tester);
    if (wide) tester.view.physicalSize = const Size(1280, 2000) * kGoldenDpr;
    if (tall != null) tester.view.physicalSize = Size(390, tall) * kGoldenDpr;
    await tester.pumpWidget(_app(screen, overrides));
    await _settle(tester);
  }

  double firstGroupWidth(WidgetTester tester) =>
      tester
          .getSize(find.byWidgetPredicate(
              (w) => w is GroupedList || w is GroupedListView).first)
          .width;

  Widget syncScreen({SyncConnectivity connectivity = SyncConnectivity.reachable}) =>
      SyncSettingsScreen(
        connectivity: connectivity,
        deviceNickname: 'Pixel de Héctor',
        lastSyncLine: 'Hace 2 h · 3 recibidos, 1 enviado',
        thisDeviceId: 'a1b2',
        peerDeviceId: 'c3d4',
        lastStatus: SyncStatus(
          ok: true,
          // Relative to the real clock: the indicator renders "hace …" from
          // DateTime.now(), so a fixed date made this golden drift daily.
          at: DateTime.now().subtract(const Duration(hours: 2)),
          applied: 3,
          sent: 1,
          message: null,
        ),
        onEnable: () {},
        onDisable: () {},
        onSyncNow: () {},
        onOpenConflicts: () {},
      );

  final ceremony = PhraseCeremony.generate(random: Random(7));
  Widget phraseScreen() => PhraseCeremonyScreen(
        ceremony: ceremony,
        onConfirmed: (_) {},
        onCancel: () {},
      );

  final backupOverrides = <Override>[
    backupsListProvider.overrideWith((ref) async => _backups),
  ];
  final graphOverrides = <Override>[
    localGraphStoreProvider.overrideWith((ref) async => _Store()),
  ];

  Future<void> shot(WidgetTester tester, String name) => expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('images/settings_b_$name.png'),
      );

  testWidgets('sync: status, actions and disclosure sit in groups within the column',
      (tester) async {
    await pump(tester, syncScreen(), wide: true);
    expect(find.byType(GroupedList), findsWidgets);
    expect(find.widgetWithText(SectionHeader, 'Qué puede ver el servidor'), findsOneWidget);
    expect(find.widgetWithText(SectionHeader, 'Qué NO puede ver'), findsOneWidget);
    expect(
        find.ancestor(
            of: find.text('Historial de conflictos'), matching: find.byType(GroupedList)),
        findsOneWidget);
    expect(firstGroupWidth(tester), lessThanOrEqualTo(kContentMaxWidth));
  });

  testWidgets('sync golden', (tester) async {
    await pump(tester, syncScreen(), tall: 1900);
    await shot(tester, 'sync');
  });

  testWidgets('phrase ceremony: the twelve words fill a numbered grid inside a Card',
      (tester) async {
    await pump(tester, phraseScreen(), wide: true);
    expect(find.byType(ListTile), findsNothing);
    final first = ceremony.words.first;
    expect(find.ancestor(of: find.text(first), matching: find.byType(Card)),
        findsOneWidget);
    for (var i = 1; i <= 12; i++) {
      expect(find.text('$i.'), findsOneWidget);
    }
    final numberStyle = tester.widget<Text>(find.text('1.')).style;
    expect(numberStyle?.fontFeatures, contains(const FontFeature.tabularFigures()));
    final card = tester.getSize(find.ancestor(of: find.text(first), matching: find.byType(Card)));
    expect(card.width, lessThanOrEqualTo(kContentMaxWidth));
  });

  testWidgets('phrase ceremony golden', (tester) async {
    await pump(tester, phraseScreen(), tall: 900);
    await shot(tester, 'phrase_ceremony');
  });

  testWidgets('backups: sections use headers and grouped rows', (tester) async {
    await pump(tester, const BackupsScreen(), overrides: backupOverrides, wide: true);
    expect(find.widgetWithText(SectionHeader, 'Automáticas'), findsOneWidget);
    expect(find.widgetWithText(SectionHeader, 'Manuales'), findsOneWidget);
    expect(find.text('21/07/2026 08:30'), findsOneWidget);
    expect(find.ancestor(of: find.text('21/07/2026 08:30'), matching: find.byType(GroupedList)),
        findsOneWidget);
    expect(find.ancestor(of: find.text('Guardar en mi servidor'), matching: find.byType(GroupedList)),
        findsOneWidget);
    expect(firstGroupWidth(tester), lessThanOrEqualTo(kContentMaxWidth));
  });

  testWidgets('backups golden', (tester) async {
    await pump(tester, const BackupsScreen(), overrides: backupOverrides);
    await shot(tester, 'backups');
  });

  Widget serverScreen(SharedPreferences prefs) => BackupSettingsScreen(
        store: BackupHostConfigStore(prefs: prefs),
        client: BackupHostClient(dio: Dio()..httpClientAdapter = _Adapter()),
        automaticSettingsStore: AutomaticBackupSettingsStore(prefs: prefs),
        automaticStatusStore: AutomaticBackupStatusStore(prefs: prefs),
        automaticPassphraseStore: AutomaticBackupPassphraseStore(
            storage: const FlutterSecureStorage()),
        automaticBackupWork:
            WorkmanagerAutomaticBackupWork(workmanager: _Workmanager()),
      );

  testWidgets('backup server: banners, fields and actions live in the column',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await pump(tester, serverScreen(prefs), wide: true);
    expect(find.byType(StatusBanner), findsWidgets);
    expect(find.byType(Card), findsNothing);
    expect(find.widgetWithText(SectionHeader, 'Servidor'), findsOneWidget);
    expect(find.widgetWithText(SectionHeader, 'Respaldo automático'), findsOneWidget);
    expect(
        find.ancestor(
            of: find.byType(SwitchListTile), matching: find.byType(GroupedList)),
        findsOneWidget);
    expect(firstGroupWidth(tester), lessThanOrEqualTo(kContentMaxWidth));

  });

  testWidgets('backup server golden', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await pump(tester, serverScreen(prefs), tall: 1000);
    await tester.enterText(find.byType(TextField).first, 'http://10.66.66.1:8099');
    await tester.enterText(find.byType(TextField).last, 'k' * 32);
    await tester.tap(find.text('Comprobar conexión'));
    await _settle(tester);
    await shot(tester, 'backup_server');
  });

  testWidgets('danger zone: destructive button uses the error color, notices are banners',
      (tester) async {
    await pump(tester, const DangerZoneScreen(), wide: true);
    final scheme = Theme.of(tester.element(find.byType(DangerZoneScreen))).colorScheme;
    expect(find.byType(StatusBanner), findsNWidgets(2));
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.style?.backgroundColor?.resolve({}), scheme.error);
    expect(button.style?.foregroundColor?.resolve({}), scheme.onError);
    expect(button.onPressed, isNull);
    expect(tester.getSize(find.byType(StatusBanner).first).width,
        lessThanOrEqualTo(kContentMaxWidth));
  });

  testWidgets('danger zone golden', (tester) async {
    await pump(tester, const DangerZoneScreen());
    await shot(tester, 'danger_zone');
  });

  testWidgets('danger zone menu: the wipe entry is a grouped row', (tester) async {
    await pump(tester, const DangerZoneMenuScreen(), wide: true);
    expect(find.byType(GroupedList), findsOneWidget);
    expect(firstGroupWidth(tester), lessThanOrEqualTo(kContentMaxWidth));
  });

  testWidgets('graph browser: nodes list inside a group, column-limited', (tester) async {
    await pump(tester, const LocalGraphBrowserScreen(),
        overrides: graphOverrides, wide: true);
    expect(find.text('Marta Ríos'), findsOneWidget);
    expect(find.ancestor(of: find.text('Marta Ríos'), matching: find.byType(GroupedListView)),
        findsOneWidget);
    expect(firstGroupWidth(tester), lessThanOrEqualTo(kContentMaxWidth));
  });

  testWidgets('graph browser golden', (tester) async {
    await pump(tester, const LocalGraphBrowserScreen(), overrides: graphOverrides);
    await shot(tester, 'graph_browser');
  });

  testWidgets('graph node: details and relations are grouped rows', (tester) async {
    await pump(tester, const LocalGraphNodeScreen(nodeUuid: 'n1'),
        overrides: graphOverrides, wide: true);
    expect(find.widgetWithText(SectionHeader, 'Detalles'), findsOneWidget);
    expect(find.widgetWithText(SectionHeader, 'Relaciones'), findsOneWidget);
    expect(find.ancestor(of: find.text('text'), matching: find.byType(GroupedList)),
        findsOneWidget);
    expect(firstGroupWidth(tester), lessThanOrEqualTo(kContentMaxWidth));
  });

  testWidgets('graph node golden', (tester) async {
    await pump(tester, const LocalGraphNodeScreen(nodeUuid: 'n1'),
        overrides: graphOverrides);
    await shot(tester, 'graph_node');
  });
}
