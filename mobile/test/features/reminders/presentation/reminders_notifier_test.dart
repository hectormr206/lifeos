// Proves RemindersNotifier's lifecycle: loading -> data on init, error
// surfacing, refresh, "mark done" (DELETE via cancel()), and NL create
// reusing chatRepositoryProvider (same documented decision as
// DomainNotifier.capture — the engine's bilingual reminder parser handles
// "recuérdame llamar al doctor mañana a las 3" through
// POST /api/v1/chat/ask). No live engine — both repositories faked.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'dart:typed_data';

import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/reminders/data/reminders_repository.dart';
import 'package:lifeos/features/reminders/domain/reminder.dart';
import 'package:lifeos/features/reminders/presentation/reminders_notifier.dart';

class _FakeRemindersRepository implements RemindersRepository {
  _FakeRemindersRepository({this.reminders = const [], this.listError, this.cancelError});

  final List<ReminderModel> reminders;
  final RemindersException? listError;
  final RemindersException? cancelError;
  int listCalls = 0;
  String? lastCancelledId;

  @override
  Future<List<ReminderModel>> list({String status = 'pending'}) async {
    listCalls++;
    if (listError != null) throw listError!;
    return reminders;
  }

  @override
  Future<void> cancel(String id) async {
    if (cancelError != null) throw cancelError!;
    lastCancelledId = id;
  }
}

class _FakeChatRepository implements ChatRepository {
  _FakeChatRepository({this.sendResult});

  final Object? sendResult;
  int sendCalls = 0;
  String? lastText;

  @override
  Future<List<ChatMessage>> loadHistory() async => const [];

  @override
  Future<ChatMessage> sendImageMessage(String text, Uint8List imageBytes) =>
      throw UnimplementedError();

  @override
  Future<ChatMessage> sendMessage(String text) async {
    sendCalls++;
    lastText = text;
    final result = sendResult;
    if (result is Exception) throw result;
    return result! as ChatMessage;
  }
}

void main() {
  group('RemindersNotifier', () {
    test('loads pending reminders on init', () async {
      final reminder = ReminderModel(id: 'r1', whenTs: DateTime.utc(2026, 7, 15, 15), message: 'Llamar al doctor', status: 'pending');
      final repo = _FakeRemindersRepository(reminders: [reminder]);
      final container = ProviderContainer(overrides: [remindersRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(remindersNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(remindersNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.reminders, [reminder]);
      expect(state.error, isNull);
    });

    test('error path surfaces the error message and keeps reminders empty', () async {
      final repo = _FakeRemindersRepository(listError: RemindersException('boom'));
      final container = ProviderContainer(overrides: [remindersRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(remindersNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(remindersNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.reminders, isEmpty);
      expect(state.error, 'boom');
    });

    test('refresh reloads reminders from the repository', () async {
      final repo = _FakeRemindersRepository();
      final container = ProviderContainer(overrides: [remindersRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(remindersNotifierProvider.notifier);
      await notifier.ready;
      expect(repo.listCalls, 1);

      await notifier.refresh();

      expect(repo.listCalls, 2);
    });

    test('markDone cancels the reminder then refreshes the list', () async {
      final reminder = ReminderModel(id: 'r1', whenTs: DateTime.now(), message: 'Llamar al doctor', status: 'pending');
      final repo = _FakeRemindersRepository(reminders: [reminder]);
      final container = ProviderContainer(overrides: [remindersRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(remindersNotifierProvider.notifier);
      await notifier.ready;

      await notifier.markDone('r1');

      expect(repo.lastCancelledId, 'r1');
      expect(repo.listCalls, 2);
    });

    test('markDone surfaces the error and does not refresh on cancel failure', () async {
      final reminder = ReminderModel(id: 'r1', whenTs: DateTime.now(), message: 'Llamar al doctor', status: 'pending');
      final repo = _FakeRemindersRepository(reminders: [reminder], cancelError: RemindersException('no se pudo'));
      final container = ProviderContainer(overrides: [remindersRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(remindersNotifierProvider.notifier);
      await notifier.ready;
      expect(repo.listCalls, 1);

      await notifier.markDone('r1');

      expect(repo.listCalls, 1);
      final state = container.read(remindersNotifierProvider);
      expect(state.error, 'no se pudo');
    });

    test('capture sends text through chatRepositoryProvider then refreshes the list', () async {
      final remindersRepo = _FakeRemindersRepository();
      final chatRepo = _FakeChatRepository(
        sendResult: ChatMessage(id: 'a', role: ChatRole.axi, text: 'listo', timestamp: DateTime.now()),
      );
      final container = ProviderContainer(overrides: [
        remindersRepositoryProvider.overrideWithValue(remindersRepo),
        chatRepositoryProvider.overrideWithValue(chatRepo),
      ]);
      addTearDown(container.dispose);
      final notifier = container.read(remindersNotifierProvider.notifier);
      await notifier.ready;
      expect(remindersRepo.listCalls, 1);

      await notifier.capture('recuérdame llamar al doctor mañana a las 3');

      expect(chatRepo.sendCalls, 1);
      expect(chatRepo.lastText, 'recuérdame llamar al doctor mañana a las 3');
      expect(remindersRepo.listCalls, 2);
      final state = container.read(remindersNotifierProvider);
      expect(state.capturing, isFalse);
      expect(state.captureError, isNull);
    });

    test('capture failure sets captureError and does not refresh', () async {
      final remindersRepo = _FakeRemindersRepository();
      final chatRepo = _FakeChatRepository(sendResult: ChatException('no se pudo'));
      final container = ProviderContainer(overrides: [
        remindersRepositoryProvider.overrideWithValue(remindersRepo),
        chatRepositoryProvider.overrideWithValue(chatRepo),
      ]);
      addTearDown(container.dispose);
      final notifier = container.read(remindersNotifierProvider.notifier);
      await notifier.ready;

      await notifier.capture('algo');

      expect(remindersRepo.listCalls, 1);
      final state = container.read(remindersNotifierProvider);
      expect(state.capturing, isFalse);
      expect(state.captureError, isNotNull);
    });

    test('capture ignores blank input', () async {
      final remindersRepo = _FakeRemindersRepository();
      final chatRepo = _FakeChatRepository();
      final container = ProviderContainer(overrides: [
        remindersRepositoryProvider.overrideWithValue(remindersRepo),
        chatRepositoryProvider.overrideWithValue(chatRepo),
      ]);
      addTearDown(container.dispose);
      final notifier = container.read(remindersNotifierProvider.notifier);
      await notifier.ready;

      await notifier.capture('   ');

      expect(chatRepo.sendCalls, 0);
      expect(remindersRepo.listCalls, 1);
    });
  });
}
