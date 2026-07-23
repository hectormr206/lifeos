// Proves the chat's deterministic reminder intent (roadmap slice C2):
// a "recuérdame…"/"remind me…" message with a parseable time creates a LOCAL
// reminder + schedules it and Axi confirms DETERMINISTICALLY — the model
// repository is NEVER called. Normal messages, reminder intents WITHOUT a
// time, and an unavailable local store all take the ordinary model path.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/reminders/data/local_reminders_repository.dart';
import 'package:lifeos/features/reminders/data/local_reminders_service.dart';
import 'package:lifeos/features/reminders/domain/local_reminder.dart';
import 'package:lifeos/features/reminders/domain/reminder_scheduler.dart';
import 'package:lifeos/features/reminders/presentation/local_reminders_providers.dart';
import 'package:lifeos/l10n/locale_providers.dart';
import 'dart:typed_data';

class _FixedClock implements Clock {
  _FixedClock(this.value);
  final DateTime value;

  @override
  DateTime now() => value;
}

/// Minimal in-memory [LocalGraphStore] covering exactly what the reminders
/// repository uses. IN-MEMORY (not the ffi sqlite backend the repository's
/// own suite uses) because these are `testWidgets` bodies: sqflite-ffi
/// answers over a real isolate port, which never resolves inside the fake
/// async test zone. Unused members throw via [noSuchMethod].
class _InMemoryGraphStore implements LocalGraphStore {
  final Map<String, GraphNodeRecord> nodes = {};
  int _seq = 0;

  @override
  Future<GraphNodeRecord> createNode({
    required String kind,
    required String label,
    Map<String, Object?> data = const <String, Object?>{},
    String? domain,
    DateTime? occurredAt,
    String? createdTz,
    String? originNode,
  }) async {
    final now = DateTime.now();
    final node = GraphNodeRecord(
      uuid: 'node-${++_seq}',
      kind: kind,
      label: label,
      data: data,
      domain: domain,
      occurredAt: occurredAt,
      createdAt: now,
      updatedAt: now,
      localId: _seq,
    );
    nodes[node.uuid] = node;
    return node;
  }

  @override
  Future<GraphNodeRecord?> getNodeByUuid(String uuid, {bool includeDeleted = false}) async =>
      nodes[uuid];

  @override
  Future<GraphNodeRecord> upsertNode(GraphNodeRecord node) async {
    nodes[node.uuid] = node;
    return node;
  }

  @override
  Future<List<GraphNodeRecord>> listNodesByKind(String kind,
          {int? limit, bool includeDeleted = false}) async =>
      nodes.values.where((n) => n.kind == kind).toList();

  @override
  Future<bool> softDeleteNode(String uuid) async => nodes.remove(uuid) != null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingScheduler implements ReminderScheduler {
  final List<LocalReminder> scheduled = [];

  @override
  Future<void> schedule(LocalReminder reminder) async => scheduled.add(reminder);

  @override
  Future<void> cancel(LocalReminder reminder) async {}
}

class _CountingChatRepository implements ChatRepository {
  int sendCalls = 0;

  @override
  Future<List<ChatMessage>> loadHistory() async => const [];

  @override
  Future<ChatMessage> sendMessage(String text) async {
    sendCalls++;
    return ChatMessage(
        id: 'axi-1', role: ChatRole.axi, text: 'modelo', timestamp: DateTime.now());
  }

  @override
  Future<ChatMessage> sendImages(String text, List<Uint8List> images) =>
      throw UnimplementedError();
}

void main() {
  // Wednesday 2026-07-22 10:00.
  final now = DateTime(2026, 7, 22, 10);
  late _RecordingScheduler scheduler;
  late LocalRemindersService service;
  late _CountingChatRepository chatRepo;

  setUp(() {
    scheduler = _RecordingScheduler();
    service = LocalRemindersService(
      LocalRemindersRepository(_InMemoryGraphStore()),
      scheduler,
    );
    chatRepo = _CountingChatRepository();
  });

  ProviderContainer buildContainer({bool storeAvailable = true}) {
    final container = ProviderContainer(overrides: [
      chatRepositoryProvider.overrideWithValue(chatRepo),
      clockProvider.overrideWithValue(_FixedClock(now)),
      // The host test locale resolves to English; the confirmations under
      // test are the neutral-Spanish ones.
      appLanguageCodeProvider.overrideWithValue('es'),
      storeAvailable
          ? localRemindersServiceProvider.overrideWith((ref) async => service)
          : localRemindersServiceProvider
              .overrideWith((ref) async => throw StateError('no store')),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  testWidgets('a reminder intent creates + schedules locally and confirms '
      'deterministically without calling the model', (tester) async {
    final container = buildContainer();
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;

    final send =
        notifier.sendMessage('recuérdame llamar al doctor mañana a las 8');
    await tester.pump();
    await tester.pump();
    await send;

    // Created + scheduled at the parsed instant.
    final reminders = await service.list(now: now);
    expect(reminders.single.text, 'llamar al doctor');
    expect(reminders.single.dueAt, DateTime(2026, 7, 23, 8));
    expect(scheduler.scheduled.single.dueAt, DateTime(2026, 7, 23, 8));

    // Deterministic confirmation — the LLM was never invoked.
    expect(chatRepo.sendCalls, 0);
    final state = container.read(chatNotifierProvider);
    expect(state.sending, isFalse);
    expect(state.messages.last.role, ChatRole.axi);
    expect(
      state.messages.last.text,
      'Listo, te recuerdo "llamar al doctor" el 23/07/2026 a las 08:00. ⏰',
    );
    // The user bubble got its double-check (delivered).
    expect(state.messages.first.status, ChatMessageStatus.delivered);
  });

  testWidgets('a daily reminder intent confirms with the recurrence phrasing',
      (tester) async {
    final container = buildContainer();
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;

    final send = notifier
        .sendMessage('recuérdame tomar la medicina todos los días a las 7');
    await tester.pump();
    await tester.pump();
    await send;

    expect(chatRepo.sendCalls, 0);
    expect(scheduler.scheduled.single.recurrence, ReminderRecurrence.daily);
    expect(
      container.read(chatNotifierProvider).messages.last.text,
      'Listo, te recuerdo "tomar la medicina" todos los días a las 07:00. ⏰',
    );
  });

  testWidgets('a normal message goes to the model untouched', (tester) async {
    final container = buildContainer();
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;

    final send = notifier.sendMessage('hola, ¿cómo estás?');
    await tester.pump();
    await tester.pump();
    await send;

    expect(chatRepo.sendCalls, 1);
    expect(scheduler.scheduled, isEmpty);
  });

  testWidgets('a reminder intent WITHOUT a parseable time falls through to '
      'the model (it can ask for one)', (tester) async {
    final container = buildContainer();
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;

    final send = notifier.sendMessage('recuérdame llamar a Ana');
    await tester.pump();
    await tester.pump();
    await send;

    expect(chatRepo.sendCalls, 1);
    expect(scheduler.scheduled, isEmpty);
  });

  testWidgets('an unavailable local store degrades to the normal model flow',
      (tester) async {
    final container = buildContainer(storeAvailable: false);
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;

    final send =
        notifier.sendMessage('recuérdame llamar al doctor mañana a las 8');
    await tester.pump();
    await tester.pump();
    await send;

    // The message is never lost: the model answered it instead.
    expect(chatRepo.sendCalls, 1);
    final state = container.read(chatNotifierProvider);
    expect(state.messages.last.text, 'modelo');
  });
}
