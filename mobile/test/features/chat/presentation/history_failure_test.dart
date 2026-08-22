// Cuando no se puede recuperar la conversación, hay que decirlo.
//
// Antes, tras agotar los reintentos, el chat se rendía en silencio y quedaba
// VACÍO — idéntico a un chat nuevo. El usuario lo describió exacto: "el letrero
// desaparece rápido y no pasa nada". Un fallo que se disfraza de normalidad es
// peor que un error: nadie puede reintentar lo que no sabe que falló.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_history_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';

class _BrokenHistory implements ChatHistoryRepository {
  int attempts = 0;

  /// Deja de fallar cuando el que llama lo permite: así se prueba que
  /// reintentar sirve de algo.
  bool healed = false;

  @override
  Future<List<ChatMessage>> loadMessages() async {
    attempts++;
    if (!healed) throw StateError('la base no abre');
    return [
      ChatMessage(
        id: 'm1',
        role: ChatRole.user,
        text: 'lo que dije ayer',
        timestamp: DateTime(2026, 8, 21),
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

ProviderContainer _container(ChatHistoryRepository history) {
  final container = ProviderContainer(overrides: [
    chatHistoryRepositoryProvider.overrideWith((ref) async => history),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('si no se pudo recuperar, el chat lo dice en vez de fingir vacío',
      () async {
    final history = _BrokenHistory();
    final container = _container(history);
    final notifier = container.read(chatNotifierProvider.notifier);
    // ready PRIMERO: la hidratación se lanza dentro del arranque, así que
    // antes de eso `hydrationSettled` todavía no espera a nada.
    await notifier.ready;
    await notifier.hydrationSettled;

    final state = container.read(chatNotifierProvider);
    expect(state.hydrating, isFalse, reason: 'ya no está intentándolo');
    expect(
      state.historyUnavailable,
      isTrue,
      reason: 'un chat vacío y un chat que no se pudo leer no son lo mismo',
    );
  });

  test('reintentar de verdad vuelve a intentarlo', () async {
    final history = _BrokenHistory();
    final container = _container(history);
    final notifier = container.read(chatNotifierProvider.notifier);
    // ready PRIMERO: la hidratación se lanza dentro del arranque, así que
    // antes de eso `hydrationSettled` todavía no espera a nada.
    await notifier.ready;
    await notifier.hydrationSettled;
    final intentosIniciales = history.attempts;

    history.healed = true;
    await notifier.retryHistory();

    expect(history.attempts, greaterThan(intentosIniciales));
    final state = container.read(chatNotifierProvider);
    expect(state.historyUnavailable, isFalse);
    expect(state.messages.map((m) => m.text), ['lo que dije ayer']);
  });

  test('un chat genuinamente nuevo NO se marca como fallo', () async {
    // Si no, todo el mundo vería un error el primer día.
    final history = _BrokenHistory()..healed = true;
    final container = _container(history);
    final n = container.read(chatNotifierProvider.notifier);
    await n.ready;
    await n.hydrationSettled;

    expect(container.read(chatNotifierProvider).historyUnavailable, isFalse);
  });
}
