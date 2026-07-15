// Proves BodyScreen (Axi's body — the "visible soul" slice) renders each
// organ with a state-colored indicator (ok=green, degraded/planned=amber,
// down=red, off/unknown=muted grey), and that tapping an organ expands it
// to show its longer description. No live engine — repository faked.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/body/data/organs_repository.dart';
import 'package:lifeos/features/body/domain/organ.dart';
import 'package:lifeos/features/body/presentation/body_screen.dart';
import 'package:lifeos/features/body/presentation/organs_notifier.dart';

class _FakeOrgansRepository implements OrgansRepository {
  _FakeOrgansRepository({this.organs = const [], this.error});

  final List<OrganState> organs;
  final OrgansException? error;
  int listCalls = 0;

  @override
  Future<List<OrganState>> list() async {
    listCalls++;
    if (error != null) throw error!;
    return organs;
  }
}

Color? _iconColorFor(WidgetTester tester, String detail) {
  final tileFinder = find.ancestor(of: find.text(detail), matching: find.byType(ListTile));
  final iconFinder = find.descendant(
    of: tileFinder,
    matching: find.byWidgetPredicate((widget) => widget is Icon && widget.icon == Icons.circle),
  );
  final icon = tester.widget<Icon>(iconFinder);
  return icon.color;
}

void main() {
  const heart = OrganState(key: 'heart', name: 'corazón', state: 'ok', detail: 'latido activo', description: 'desc-heart');
  const lungs =
      OrganState(key: 'lungs', name: 'pulmones', state: 'degraded', detail: 'VRAM alta', description: 'desc-lungs');
  const hands = OrganState(key: 'hands', name: 'manos', state: 'down', detail: 'ydotoold inactivo', description: 'desc-hands');
  const mouth = OrganState(key: 'mouth', name: 'boca', state: 'off', detail: 'voz desactivada', description: 'desc-mouth');
  const memory =
      OrganState(key: 'memory', name: 'memoria', state: 'unknown', detail: 'no pude leer este órgano', description: 'desc-memory');
  const immune = OrganState(key: 'immune', name: 'sistema inmune', state: 'planned', detail: 'en desarrollo', description: 'desc-immune');

  Future<void> pumpBody(WidgetTester tester, _FakeOrgansRepository repo) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [organsRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: BodyScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('renders every organ with its name and detail', (tester) async {
    final repo = _FakeOrgansRepository(organs: const [heart, lungs]);
    await pumpBody(tester, repo);

    expect(find.text('corazón'), findsOneWidget);
    expect(find.text('latido activo'), findsOneWidget);
    expect(find.text('pulmones'), findsOneWidget);
    expect(find.text('VRAM alta'), findsOneWidget);
  });

  testWidgets('ok state renders a green indicator', (tester) async {
    final repo = _FakeOrgansRepository(organs: const [heart]);
    await pumpBody(tester, repo);

    expect(_iconColorFor(tester, 'latido activo'), Colors.green);
  });

  testWidgets('degraded and planned states render an amber indicator', (tester) async {
    final repo = _FakeOrgansRepository(organs: const [lungs, immune]);
    await pumpBody(tester, repo);

    expect(_iconColorFor(tester, 'VRAM alta'), Colors.amber);
    expect(_iconColorFor(tester, 'en desarrollo'), Colors.amber);
  });

  testWidgets('down state renders a red indicator', (tester) async {
    final repo = _FakeOrgansRepository(organs: const [hands]);
    await pumpBody(tester, repo);

    expect(_iconColorFor(tester, 'ydotoold inactivo'), Colors.red);
  });

  testWidgets('off and unknown states render a muted grey indicator', (tester) async {
    final repo = _FakeOrgansRepository(organs: const [mouth, memory]);
    await pumpBody(tester, repo);

    expect(_iconColorFor(tester, 'voz desactivada'), Colors.grey);
    expect(_iconColorFor(tester, 'no pude leer este órgano'), Colors.grey);
  });

  testWidgets('tapping an organ expands it to show the longer description', (tester) async {
    final repo = _FakeOrgansRepository(organs: const [heart]);
    await pumpBody(tester, repo);

    expect(find.text('desc-heart'), findsNothing);

    await tester.tap(find.text('corazón'));
    await tester.pumpAndSettle();

    expect(find.text('desc-heart'), findsOneWidget);
  });

  testWidgets('shows an error state with a retry button on failure', (tester) async {
    final repo = _FakeOrgansRepository(error: OrgansException('boom'));
    await pumpBody(tester, repo);

    expect(find.text('boom'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
  });
}
