// Proves DomainListScreen (design D2's generic "data-table widget") renders
// entries, the subject badge when present (family attribution), the
// empty/error states, and that the NL quick-capture bar reuses the chat
// endpoint and triggers a refresh. No live engine — both repositories faked.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/domains/data/domain_repository.dart';
import 'package:lifeos/features/domains/domain/domain_descriptor.dart';
import 'package:lifeos/features/domains/domain/domain_entry.dart';
import 'package:lifeos/features/domains/presentation/domain_list_screen.dart';
import 'package:lifeos/features/domains/presentation/domain_notifier.dart';

class _FixedConnectivityNotifier extends ConnectivityNotifier {
  _FixedConnectivityNotifier(this._fixed);

  final ConnectivityStatus _fixed;

  @override
  ConnectivityStatus build() => _fixed;
}

class _FakeDomainRepository implements DomainRepository {
  _FakeDomainRepository({this.entries = const [], this.error});

  final List<DomainEntry> entries;
  final DomainException? error;
  int listCalls = 0;
  int createCalls = 0;
  Map<String, Object?>? lastCreateBody;

  @override
  Future<List<DomainEntry>> list(DomainDescriptor descriptor) async {
    listCalls++;
    if (error != null) throw error!;
    return entries;
  }

  @override
  Future<DomainEntry> createEntry(DomainDescriptor descriptor, Map<String, Object?> body) async {
    createCalls++;
    lastCreateBody = body;
    return DomainEntry(id: 'created1', title: body['title'] as String? ?? '', timestamp: DateTime.now());
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
  final descriptor = domainDescriptors.firstWhere((d) => d.key == 'health');

  testWidgets('renders entries with title and no badge when subject is null', (tester) async {
    final entry = DomainEntry(id: '1', title: 'Presión', timestamp: DateTime.utc(2026, 1, 1, 10, 30));
    final repo = _FakeDomainRepository(entries: [entry]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [domainRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(home: DomainListScreen(descriptor: descriptor)),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Presión'), findsOneWidget);
    expect(find.byType(Chip), findsNothing);
  });

  testWidgets('shows the subject badge when present (family attribution)', (tester) async {
    final entry = DomainEntry(id: '1', title: 'Pulso', timestamp: DateTime.now(), subject: 'esposa');
    final repo = _FakeDomainRepository(entries: [entry]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [domainRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(home: DomainListScreen(descriptor: descriptor)),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.widgetWithText(Chip, 'esposa'), findsOneWidget);
  });

  testWidgets('shows an empty state when there are no entries', (tester) async {
    final repo = _FakeDomainRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [domainRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(home: DomainListScreen(descriptor: descriptor)),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Aún no hay registros.'), findsOneWidget);
  });

  testWidgets('shows an error state with a retry button on failure', (tester) async {
    final repo = _FakeDomainRepository(error: DomainException('boom'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [domainRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(home: DomainListScreen(descriptor: descriptor)),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('boom'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('renders a new (M2 slice 2) domain the same way — calendar, "events" wrapper key', (tester) async {
    final calendar = domainDescriptors.firstWhere((d) => d.key == 'calendar');
    final entry = DomainEntry(id: 'ev1', title: 'Cita con el doctor', timestamp: DateTime.utc(2026, 2, 1, 18));
    final repo = _FakeDomainRepository(entries: [entry]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [domainRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(home: DomainListScreen(descriptor: calendar)),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Calendario'), findsOneWidget);
    expect(find.text('Cita con el doctor'), findsOneWidget);
  });

  testWidgets('the capture bar sends text through the chat endpoint and refreshes the list', (tester) async {
    final repo = _FakeDomainRepository();
    final chat = _FakeChatRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          domainRepositoryProvider.overrideWithValue(repo),
          chatRepositoryProvider.overrideWithValue(chat),
        ],
        child: MaterialApp(home: DomainListScreen(descriptor: descriptor)),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(repo.listCalls, 1);

    await tester.enterText(find.byType(TextField), 'presión 120/80');
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    await tester.pump();

    expect(chat.sendCalls, 1);
    expect(chat.lastText, 'presión 120/80');
    expect(repo.listCalls, 2);
  });

  testWidgets('tapping the structured-add affordance opens the form and submitting POSTs the built body',
      (tester) async {
    final finance = domainDescriptors.firstWhere((d) => d.key == 'finance');
    final repo = _FakeDomainRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [domainRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(home: DomainListScreen(descriptor: finance)),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.post_add));
    await tester.pumpAndSettle();

    expect(find.text('Título'), findsOneWidget);
    expect(find.text('Monto'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Título'), 'Súper');
    await tester.enterText(find.widgetWithText(TextFormField, 'Monto'), '500');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Guardar'));
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await tester.pumpAndSettle();

    expect(repo.createCalls, 1);
    expect(repo.lastCreateBody!['kind'], 'expense');
    expect(repo.lastCreateBody!['title'], 'Súper');
    expect(repo.lastCreateBody!['amount'], 500.0);
    // The form closes and the new entry appears in the list.
    expect(find.text('Súper'), findsOneWidget);
  });

  testWidgets('shows the offline banner when connectivity is offlineWithCache (M3 slice 1)', (tester) async {
    final entry = DomainEntry(id: '1', title: 'Presión', timestamp: DateTime.utc(2026, 1, 1, 10, 30));
    final repo = _FakeDomainRepository(entries: [entry]);
    final fixed = ConnectivityStatus(state: ConnectivityState.offlineWithCache, lastSyncAt: DateTime.now());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          domainRepositoryProvider.overrideWithValue(repo),
          connectivityStatusProvider.overrideWith(() => _FixedConnectivityNotifier(fixed)),
        ],
        child: MaterialApp(home: DomainListScreen(descriptor: descriptor)),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    expect(find.textContaining('Sin conexión'), findsOneWidget);
  });
}
