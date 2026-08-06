// "Iniciar reunión": when it exists, and that it never records on its own.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/api/capabilities.dart';
import 'package:lifeos/features/home/presentation/home_providers.dart';
import 'package:lifeos/features/meetings/data/meeting_recorder_repository.dart';
import 'package:lifeos/features/meetings/presentation/meeting_recorder_providers.dart';
import 'package:lifeos/features/meetings/presentation/meeting_recorder_tile.dart';

class _FakeRepo implements MeetingRecorderRepository {
  _FakeRepo({this.state = const MeetingRecordingState(active: false), this.failWith});

  MeetingRecordingState state;
  final MeetingRecorderException? failWith;
  final List<bool> setCalls = [];

  @override
  Future<MeetingRecordingState> status() async => state;

  @override
  Future<MeetingRecordingState> setActive(bool active) async {
    setCalls.add(active);
    if (failWith != null) throw failWith!;
    state = MeetingRecordingState(active: active, meetingId: 8, detail: 'Reunión #8');
    return state;
  }
}

Capabilities _caps({required bool available}) => Capabilities.fromJson({
      'api_version': '1',
      'engine_version': '0.9.19',
      'capabilities': {
        'meetingRecorder': {'v': 1, 'available': available, 'reason': ''},
      },
    });

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required bool available,
  _FakeRepo? repo,
}) async {
  final container = ProviderContainer(overrides: [
    engineCapabilitiesProvider
        .overrideWith((ref) async => _caps(available: available)),
    meetingRecorderRepositoryProvider.overrideWithValue(repo ?? _FakeRepo()),
  ]);
  addTearDown(container.dispose);
  await container.read(engineCapabilitiesProvider.future);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: Scaffold(body: MeetingRecorderTile())),
  ));
  await container.read(meetingRecorderProvider.notifier).ready;
  await tester.pump();
  return container;
}

void main() {
  testWidgets('with a recorder, the control is offered', (tester) async {
    await _pump(tester, available: true);

    expect(find.text('Iniciar reunión'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Iniciar'), findsOneWidget);
    expect(find.textContaining('audio del sistema'), findsOneWidget);
  });

  testWidgets('without a recorder the control is ABSENT', (tester) async {
    // A phone paired to a laptop that is not in the room must not offer a
    // button that would record the wrong place.
    await _pump(tester, available: false);

    expect(find.text('Iniciar reunión'), findsNothing);
  });

  testWidgets('it never starts a meeting by itself', (tester) async {
    final repo = _FakeRepo();
    await _pump(tester, available: true, repo: repo);

    expect(repo.setCalls, isEmpty);
  });

  testWidgets('a meeting started from the tray shows as in progress',
      (tester) async {
    // The laptop's tray can start one. Showing "Iniciar" then would stop the
    // recording on the first tap.
    final repo = _FakeRepo(
      state: const MeetingRecordingState(
          active: true, meetingId: 7, detail: 'Reunión #7 · 00:12:31 · grabando'),
    );
    await _pump(tester, available: true, repo: repo);

    expect(find.text('Reunión en curso'), findsOneWidget);
    expect(find.textContaining('00:12:31'), findsOneWidget);
    expect(find.text('Detener'), findsOneWidget);
  });

  testWidgets('tapping asks the engine to start', (tester) async {
    final repo = _FakeRepo();
    await _pump(tester, available: true, repo: repo);

    await tester.tap(find.text('Iniciar'));
    await tester.pump();

    expect(repo.setCalls, [true]);
  });

  testWidgets('a refused start shows why and does NOT claim to be recording',
      (tester) async {
    // A full disk is a refusal meeting.py makes on purpose. Showing "grabando"
    // anyway is the one failure that loses a whole conversation.
    final repo = _FakeRepo(
      failWith: const MeetingRecorderException(
          'ERROR: espacio en disco insuficiente (2.1 GB libres)'),
    );
    await _pump(tester, available: true, repo: repo);

    await tester.tap(find.text('Iniciar'));
    await tester.pump();

    expect(find.textContaining('disco'), findsOneWidget);
    expect(find.text('Reunión en curso'), findsNothing);
  });
}
