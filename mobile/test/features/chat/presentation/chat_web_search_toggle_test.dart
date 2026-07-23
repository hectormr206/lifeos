// Proves the "buscar en internet" globe toggle in the chat input bar flips
// webSearchEnabledProvider (off by default), driving whether chat turns are
// web-augmented. No live engine/network — the repository is faked.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';
import 'package:lifeos/features/chat/presentation/chat_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

const _chatApp = MaterialApp(
  home: ChatScreen(),
  locale: Locale('es'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
);

class _FakeChatRepository implements ChatRepository {
  @override
  Future<List<ChatMessage>> loadHistory() async => const [];

  @override
  Future<ChatMessage> sendMessage(String text) async =>
      ChatMessage(id: 'r', role: ChatRole.axi, text: 'ok', timestamp: DateTime(2026));

  @override
  Future<ChatMessage> sendImages(String text, List<Uint8List> images) async =>
      ChatMessage(id: 'ri', role: ChatRole.axi, text: 'ok', timestamp: DateTime(2026));
}

void main() {
  testWidgets('tapping the globe flips webSearchEnabledProvider', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(_FakeChatRepository())],
        child: _chatApp,
      ),
    );
    await tester.pump();
    await tester.pump();

    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));

    // Off by default.
    expect(container.read(webSearchEnabledProvider), isFalse);

    final globe = find.byIcon(Icons.public);
    expect(globe, findsOneWidget);

    await tester.tap(globe);
    await tester.pump();
    expect(container.read(webSearchEnabledProvider), isTrue);

    // Tapping again turns it back off (mode toggle).
    await tester.tap(globe);
    await tester.pump();
    expect(container.read(webSearchEnabledProvider), isFalse);
  });
}
