// Saber DE QUÉ DÍA es cada mensaje, sin salir del chat.
//
// Los globos ya traían la hora, pero al subir por la conversación la hora sola
// miente: "9:05" puede ser de hoy o de hace tres semanas. WhatsApp resuelve
// esto con un separador de día entre los mensajes; esto prueba que el nuestro
// aparece, que nombra bien cada día y que no se repite dentro del mismo día.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_history_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';

import '../support/chat_test_harness.dart';

class _SeededHistory implements ChatHistoryRepository {
  _SeededHistory(this.messages);

  final List<ChatMessage> messages;

  @override
  Future<List<ChatMessage>> loadMessages() async => messages;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

ChatMessage _msg(String id, DateTime at) => ChatMessage(
      id: id,
      role: ChatRole.user,
      text: id,
      timestamp: at,
    );

Future<void> _pump(WidgetTester tester, List<ChatMessage> seed) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        chatHistoryRepositoryProvider
            .overrideWith((ref) async => _SeededHistory(seed)),
      ],
      child: chatApp,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('nombra hoy y ayer, uno por día', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 10);
    final yesterday = today.subtract(const Duration(days: 1));

    await _pump(tester, [
      _msg('de ayer', yesterday),
      _msg('de ayer también', yesterday.add(const Duration(hours: 2))),
      _msg('de hoy', today),
    ]);

    expect(find.text('Ayer'), findsOneWidget);
    expect(find.text('Hoy'), findsOneWidget);
  });

  testWidgets('un día viejo se anuncia con su fecha exacta', (tester) async {
    await _pump(tester, [_msg('viejo', DateTime(2025, 12, 31, 9))]);

    // La fecha se formatea con la localización del sistema, así que en vez de
    // fijar el formato exacto se comprueba que el año está escrito.
    expect(
      find.textContaining('2025'),
      findsWidgets,
      reason: 'un mensaje de otro año tiene que decir de qué año es',
    );
  });

  testWidgets('una conversación de un solo día lleva un solo separador',
      (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 8);

    await _pump(tester, [
      _msg('uno', today),
      _msg('dos', today.add(const Duration(minutes: 5))),
      _msg('tres', today.add(const Duration(minutes: 9))),
    ]);

    expect(find.text('Hoy'), findsOneWidget);
  });

  testWidgets('el globo anuncia la fecha completa, no solo la hora',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, [_msg('viejo', DateTime(2025, 12, 31, 9, 5))]);

    // Visualmente el globo sigue llevando la hora sola; quien lo escucha
    // recibe además el día, porque "9:05" a secas no dice nada.
    expect(find.text('09:05'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'2025.*09:05')),
      findsOneWidget,
    );

    handle.dispose();
  });
}
