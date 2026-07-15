// Proves RemindersScreen renders the upcoming/pending list, the NL
// quick-create bar (reusing the chat endpoint), and a "mark done" action
// per reminder that calls the repository's cancel(). No live engine — both
// repositories faked.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/reminders/data/reminders_repository.dart';
import 'package:lifeos/features/reminders/domain/reminder.dart';
import 'package:lifeos/features/reminders/presentation/reminders_notifier.dart';
import 'package:lifeos/features/reminders/presentation/reminders_screen.dart';

class _FakeRemindersRepository implements RemindersRepository {
  _FakeRemindersRepository({this.reminders = const [], this.listError});

  final List<ReminderModel> reminders;
  final RemindersException? listError;
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
    lastCancelledId = id;
  }
}

class _FakeChatRepository implements ChatRepository {
  int sendCalls = 0;
  String? lastText;

  @override
  Future<List<ChatMessage>> loadHistory() async => const [];

  @override
  Future<ChatMessage> sendMessage(String text) async {
    sendCalls++;
    lastText = text;
    return ChatMessage(id: 'a', role: ChatRole.axi, text: 'listo', timestamp: DateTime.now());
  }
}

void main() {
  testWidgets('renders pending reminders with their message', (tester) async {
    final reminder =
        ReminderModel(id: 'r1', whenTs: DateTime.utc(2026, 7, 15, 15), message: 'Llamar al doctor', status: 'pending');
    final repo = _FakeRemindersRepository(reminders: [reminder]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [remindersRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: RemindersScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Llamar al doctor'), findsOneWidget);
  });

  testWidgets('shows an empty state when there are no reminders', (tester) async {
    final repo = _FakeRemindersRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [remindersRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: RemindersScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('No tienes recordatorios pendientes.'), findsOneWidget);
  });

  testWidgets('shows an error state with a retry button on failure', (tester) async {
    final repo = _FakeRemindersRepository(listError: RemindersException('boom'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [remindersRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: RemindersScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('boom'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('the create bar sends text through the chat endpoint and refreshes the list', (tester) async {
    final repo = _FakeRemindersRepository();
    final chat = _FakeChatRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          remindersRepositoryProvider.overrideWithValue(repo),
          chatRepositoryProvider.overrideWithValue(chat),
        ],
        child: const MaterialApp(home: RemindersScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(repo.listCalls, 1);

    await tester.enterText(find.byType(TextField), 'recuérdame llamar al doctor mañana a las 3');
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    await tester.pump();

    expect(chat.sendCalls, 1);
    expect(chat.lastText, 'recuérdame llamar al doctor mañana a las 3');
    expect(repo.listCalls, 2);
  });

  testWidgets('tapping the done action marks the reminder done and refreshes the list', (tester) async {
    final reminder =
        ReminderModel(id: 'r1', whenTs: DateTime.utc(2026, 7, 15, 15), message: 'Llamar al doctor', status: 'pending');
    final repo = _FakeRemindersRepository(reminders: [reminder]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [remindersRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: RemindersScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(repo.listCalls, 1);

    await tester.tap(find.byIcon(Icons.check_circle_outline));
    await tester.pump();
    await tester.pump();

    expect(repo.lastCancelledId, 'r1');
    expect(repo.listCalls, 2);
  });
}
