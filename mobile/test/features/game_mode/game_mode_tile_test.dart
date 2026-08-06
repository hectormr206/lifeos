// The Modo juego switch: when it exists, and that it never moves on its own.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/api/capabilities.dart';
import 'package:lifeos/features/game_mode/data/game_mode_repository.dart';
import 'package:lifeos/features/game_mode/presentation/game_mode_providers.dart';
import 'package:lifeos/features/game_mode/presentation/game_mode_tile.dart';

class _FakeRepo implements GameModeRepository {
  _FakeRepo({this.active = false, this.failWith});

  bool active;
  final GameModeException? failWith;
  final List<bool> setCalls = [];

  @override
  Future<bool> isActive() async => active;

  @override
  Future<bool> setActive(bool value) async {
    setCalls.add(value);
    if (failWith != null) throw failWith!;
    active = value;
    return value;
  }
}

Capabilities _caps({required bool available}) => Capabilities.fromJson({
      'api_version': '1',
      'engine_version': '0.9.19',
      'capabilities': {
        'gameMode': {
          'v': 1,
          'available': available,
          'gpu': available
              ? {'name': 'NVIDIA GeForce RTX 5070 Ti', 'total_mb': 12282}
              : null,
          'reason': available ? '' : 'No hay GPU con VRAM en esta máquina.',
        },
      },
    });

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required bool available,
  _FakeRepo? repo,
}) async {
  final container = ProviderContainer(overrides: [
    gameModeCapabilitiesProvider.overrideWithValue(_caps(available: available)),
    gameModeRepositoryProvider.overrideWithValue(repo ?? _FakeRepo()),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: Scaffold(body: GameModeTile())),
  ));
  await container.read(gameModeProvider.notifier).ready;
  await tester.pump();
  return container;
}

void main() {
  testWidgets('with a GPU, the switch is there and names the card',
      (tester) async {
    await _pump(tester, available: true);

    expect(find.text('Modo juego'), findsOneWidget);
    expect(find.textContaining('RTX 5070 Ti'), findsOneWidget);
    expect(find.textContaining('12 GB'), findsOneWidget);
  });

  testWidgets('with no GPU the switch is ABSENT, not disabled', (tester) async {
    // "Si todo está en CPU y RAM entonces no nos sirve y lo ocultamos."
    await _pump(tester, available: false);

    expect(find.text('Modo juego'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('it never turns itself on', (tester) async {
    // The user's rule: he activates it. Building the screen, reading the state,
    // and rendering must not ask the engine to change anything.
    final repo = _FakeRepo(active: false);
    await _pump(tester, available: true, repo: repo);

    expect(repo.setCalls, isEmpty);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse);
  });

  testWidgets('it reflects game mode already being on', (tester) async {
    // The laptop's tray can turn it on. Opening the app must show the truth,
    // not a switch stuck at off that would turn it OFF on the first tap.
    final repo = _FakeRepo(active: true);
    await _pump(tester, available: true, repo: repo);

    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue);
  });

  testWidgets('tapping asks the engine for the target state', (tester) async {
    final repo = _FakeRepo(active: false);
    await _pump(tester, available: true, repo: repo);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();

    expect(repo.setCalls, [true]);
  });

  testWidgets('a failed relocation shows the reason and does NOT claim success',
      (tester) async {
    // Half-applied is the dangerous state: some units on the GPU, some on the
    // CPU. Flipping the switch anyway would hide exactly that.
    final repo = _FakeRepo(
      active: false,
      failWith: const GameModeException('axi-game-on falló: no pude parar llama-server'),
    );
    await _pump(tester, available: true, repo: repo);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();

    expect(find.textContaining('llama-server'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse, reason: 'nothing moved, so the switch must not say it did');
  });
}
