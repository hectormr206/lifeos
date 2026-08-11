// Proves the FIFO serialization the on-device model needs: the phone has ONE
// native inference session, so two overlapping generations corrupt each other
// (the user's report: tap a second summary and the first "se queda mocho").
// The queue's contract is that a second request WAITS — it is never dropped,
// never interleaved, and its turn is observable so the UI can say "en cola".
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/llm_request_queue.dart';

void main() {
  test('runs tasks one at a time, in submission order', () async {
    final queue = LlmRequestQueue();
    final gates = [Completer<void>(), Completer<void>(), Completer<void>()];
    final started = <int>[];
    final finished = <int>[];

    final futures = [
      for (var i = 0; i < 3; i++)
        queue.add(() async {
          started.add(i);
          await gates[i].future;
          finished.add(i);
          return i;
        }),
    ];

    await pumpEventQueue();
    expect(started, [0], reason: 'only the first job may run; the rest wait');

    gates[0].complete();
    await pumpEventQueue();
    expect(started, [0, 1], reason: 'the next job starts only after the previous finished');

    gates[1].complete();
    gates[2].complete();
    expect(await Future.wait(futures), [0, 1, 2]);
    expect(finished, [0, 1, 2], reason: 'every submitted job completes, in order');
  });

  test('a failing job never swallows the ones queued behind it', () async {
    final queue = LlmRequestQueue();

    final failing = queue.add<int>(() async => throw StateError('boom'));
    final next = queue.add<int>(() async => 7);

    await expectLater(failing, throwsStateError);
    expect(await next, 7, reason: 'the queue keeps draining after a failure');
  });

  test('reports which job is running and how many are still waiting', () async {
    final queue = LlmRequestQueue();
    final gate = Completer<void>();
    final startedLabels = <String>[];

    final first = queue.add(
      () => gate.future,
      label: 'a',
      onStart: () => startedLabels.add('a'),
    );
    final second = queue.add(
      () async {},
      label: 'b',
      onStart: () => startedLabels.add('b'),
    );

    await pumpEventQueue();
    expect(queue.runningLabel, 'a');
    expect(queue.queuedLabels, ['b'], reason: 'b is waiting, not running');
    expect(startedLabels, ['a'], reason: 'onStart fires when the job truly begins');

    gate.complete();
    await Future.wait([first, second]);
    expect(startedLabels, ['a', 'b']);
    expect(queue.runningLabel, isNull);
    expect(queue.queuedLabels, isEmpty);
  });

  test('a nested submission runs inline instead of deadlocking on its own slot', () async {
    final queue = LlmRequestQueue();

    final result = await queue.add(() async {
      // A queued job that itself calls through a queued engine must not wait
      // for a slot it is already holding.
      final inner = await queue.add(() async => 'inner');
      return 'outer+$inner';
    }).timeout(const Duration(seconds: 2));

    expect(result, 'outer+inner');
  });
}
