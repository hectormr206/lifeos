// Proves ChatScreen renders messages + input (spec mobile-chat, M1 slice 2)
// and that tapping send calls the repository and shows the reply. No live
// engine — chatRepositoryProvider is overridden with a fake.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/chat/presentation/chat_screen.dart';

class _FakeChatRepository implements ChatRepository {
  _FakeChatRepository({this.history = const []});

  final List<ChatMessage> history;

  @override
  Future<List<ChatMessage>> loadHistory() async => history;

  @override
  Future<ChatMessage> sendMessage(String text) async =>
      ChatMessage(id: 'reply-1', role: ChatRole.axi, text: 'Respuesta de Axi', timestamp: DateTime.now());
}

void main() {
  testWidgets('renders loaded history messages and the text input', (tester) async {
    final ts = DateTime.now();
    final repo = _FakeChatRepository(
      history: [
        ChatMessage(id: '1-user', role: ChatRole.user, text: 'hola', timestamp: ts),
        ChatMessage(id: '1-axi', role: ChatRole.axi, text: 'hola, ¿qué tal?', timestamp: ts),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('hola'), findsOneWidget);
    expect(find.text('hola, ¿qué tal?'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('tapping send calls the repository and shows the reply', (tester) async {
    final repo = _FakeChatRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'hola axi');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump();

    expect(find.text('hola axi'), findsOneWidget);
    expect(find.text('Respuesta de Axi'), findsOneWidget);
  });
}
