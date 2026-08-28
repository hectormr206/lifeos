// Lo que reportó el usuario el 2026-08-28: al abrir el chat, "No pude abrir tu
// conversación guardada"; y el cerebro 3D, "no se pudo abrir la memoria local".
// Tuvo que CERRAR la aplicación y volver a entrar para que le dejara ver.
//
// La causa no era mala suerte. `graphDatabaseHandleProvider` es un
// FutureProvider, y Riverpod cachea también los errores: si la primera apertura
// de la base falla, ese fallo queda cacheado durante toda la vida del proceso y
// TODOS los consumidores reciben el mismo error para siempre. Los cuatro
// reintentos con pausas crecientes releían el mismo futuro fallido: eran
// decorativos. Por eso cerrar la app era el único remedio.
//
// La distinción que fija esta prueba: si lo que falló fue ABRIR la base, hay
// que reabrirla de verdad. Si la base está abierta y falló la LECTURA, no se
// toca — cerrar una base sana bajo los pies de las demás pantallas sería peor
// que el fallo original.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_providers.dart';
import 'package:lifeos/features/chat/data/chat_history_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';

/// Cuenta cuántas veces se ha intentado ABRIR la base, y falla hasta que se
/// la "cura" — como un llavero que estaba bloqueado al arrancar la sesión y
/// después ya no lo está.
class _FlakyOpen {
  int opens = 0;
  bool healed = false;
}

class _History implements ChatHistoryRepository {
  @override
  Future<List<ChatMessage>> loadMessages() async => [
        ChatMessage(
          id: 'm1',
          role: ChatRole.user,
          text: 'lo que dije ayer',
          timestamp: DateTime(2026, 8, 27),
        ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

ProviderContainer _container(_FlakyOpen db) {
  final container = ProviderContainer(overrides: [
    // El fallo REAL: la base no abre. No que abra y la lectura falle.
    graphDatabaseHandleProvider.overrideWith((ref) async {
      db.opens++;
      if (!db.healed) throw StateError('el llavero no estaba disponible');
      throw UnimplementedError('no se usa el handle en esta prueba');
    }),
    chatHistoryRepositoryProvider.overrideWith((ref) async {
      // Igual que en producción: depende del handle, así que invalidar el
      // handle lo reconstruye.
      try {
        await ref.watch(graphDatabaseHandleProvider.future);
      } on UnimplementedError {
        return _History(); // abrió bien
      }
      throw StateError('inalcanzable');
    }),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('reintentar REABRE la base, no relee el fallo cacheado', () async {
    final db = _FlakyOpen();
    final container = _container(db);
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;
    await notifier.hydrationSettled;

    expect(
      container.read(chatNotifierProvider).historyUnavailable,
      isTrue,
      reason: 'la base no abrió, y eso se dice',
    );
    final trasElArranque = db.opens;
    expect(
      trasElArranque,
      greaterThan(1),
      reason: 'los reintentos del arranque tienen que reabrir de verdad, '
          'no releer el mismo futuro fallido',
    );

    // El llavero ya está disponible, como cuando el usuario reabre la app.
    db.healed = true;
    await notifier.retryHistory();

    expect(db.opens, greaterThan(trasElArranque), reason: 'reintentar reabrió');
    final state = container.read(chatNotifierProvider);
    expect(state.historyUnavailable, isFalse);
    expect(state.messages.single.text, 'lo que dije ayer');
  });
}
