// The conversation must not come up blank.
//
// Reported, and it had been happening for a long time: "cuando abro LifeOS en
// mi pixel y abro el chat, toda la conversación aparece en blanco, tengo que
// cerrar completamente y volver a abrir y ahora sí me aparece".
//
// Reading the code, the shape fits exactly. The persisted transcript is
// hydrated ONCE, from a store that has to be opened and decrypted first. If
// that open is slow or fails on a cold start — which is precisely when it is
// most likely — `_hydratePersisted` swallows the failure and never tries
// again. The chat then sits empty until the app is killed and relaunched,
// because relaunching is what retries it.
//
// Two things are wrong with that, and this pins both:
//   1. It gives up after one attempt at the moment it is most likely to fail.
//   2. An empty chat caused by a failure looks exactly like a chat with no
//      messages. The user cannot tell "still loading" from "nothing here", so
//      the only feedback is their own conversation appearing to be gone —
//      which is frightening in an app that holds your life.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_history_repository.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';

/// Fails the first N loads, then succeeds — a store that is still opening.
class _FlakyHistory implements ChatHistoryRepository {
  _FlakyHistory({required this.failures, required this.messages});

  int failures;
  final List<ChatMessage> messages;
  int loadCalls = 0;

  @override
  Future<List<ChatMessage>> loadMessages({String? conversationUuid}) async {
    loadCalls++;
    if (failures > 0) {
      failures--;
      throw StateError('store still opening');
    }
    return messages;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _EmptyChatRepository implements ChatRepository {
  @override
  Future<List<ChatMessage>> loadHistory() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  final saved = [
    ChatMessage(
      id: 'm1',
      role: ChatRole.user,
      text: 'lo que hablamos ayer',
      timestamp: DateTime(2026, 8, 19, 10),
    ),
  ];

  test('a store that opens late still fills the conversation', () async {
    // Without a retry this ends with an empty chat, and the only fix the user
    // has is force-closing the app.
    final history = _FlakyHistory(failures: 2, messages: saved);
    final container = ProviderContainer(overrides: [
      chatRepositoryProvider.overrideWithValue(_EmptyChatRepository()),
      chatHistoryRepositoryProvider.overrideWith((ref) async => history),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;
    await notifier.hydrationSettled;

    expect(container.read(chatNotifierProvider).messages, isNotEmpty,
        reason: 'the conversation came up blank');
    expect(history.loadCalls, greaterThan(1), reason: 'it never retried');
  });

  test('it does not retry for ever', () async {
    // A store that is genuinely gone must not turn into a loop that keeps a
    // phone awake.
    final history = _FlakyHistory(failures: 99, messages: saved);
    final container = ProviderContainer(overrides: [
      chatRepositoryProvider.overrideWithValue(_EmptyChatRepository()),
      chatHistoryRepositoryProvider.overrideWith((ref) async => history),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;
    await notifier.hydrationSettled;

    expect(history.loadCalls, lessThan(10));
  });

  test('while it is still loading, the screen knows', () async {
    // An empty chat caused by a failure must not look like a chat with no
    // messages: the user cannot tell those apart, and one of them is
    // frightening.
    final history = _FlakyHistory(failures: 1, messages: saved);
    final container = ProviderContainer(overrides: [
      chatRepositoryProvider.overrideWithValue(_EmptyChatRepository()),
      chatHistoryRepositoryProvider.overrideWith((ref) async => history),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(chatNotifierProvider.notifier);
    expect(container.read(chatNotifierProvider).hydrating, isTrue);

    await notifier.ready;
    await notifier.hydrationSettled;

    expect(container.read(chatNotifierProvider).hydrating, isFalse);
  });

  test('a genuinely empty conversation is not left saying "loading"',
      () async {
    // A new user has no history, and that must settle to "empty", not spin.
    final history = _FlakyHistory(failures: 0, messages: const []);
    final container = ProviderContainer(overrides: [
      chatRepositoryProvider.overrideWithValue(_EmptyChatRepository()),
      chatHistoryRepositoryProvider.overrideWith((ref) async => history),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;
    await notifier.hydrationSettled;

    expect(container.read(chatNotifierProvider).hydrating, isFalse);
  });
}
