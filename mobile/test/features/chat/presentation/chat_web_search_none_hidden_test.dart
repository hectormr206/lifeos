// Proves that when the user picks "Ninguna" (WebSearchProvider.none) in the
// web-search settings, the chat globe toggle is HIDDEN and the enabled flag is
// forced off — web search is fully disabled, zero outbound requests possible.
// No live engine/network: the repository + preferences are faked.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';
import 'package:lifeos/features/chat/presentation/chat_screen.dart';
import '../support/chat_test_harness.dart';
import 'package:lifeos/features/web_search/domain/web_search_settings.dart';
import 'package:lifeos/features/web_search/presentation/web_search_providers.dart';

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

class _FakePrefs implements WebSearchPreferences {
  _FakePrefs(this.settings);
  WebSearchSettings settings;
  @override
  Future<WebSearchSettings> load() async => settings;
  @override
  Future<void> save(WebSearchSettings s) async => settings = s;
}

void main() {
  testWidgets('the globe toggle is hidden when the provider is "none"', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(_FakeChatRepository()),
          webSearchPreferencesProvider
              .overrideWithValue(_FakePrefs(const WebSearchSettings(provider: WebSearchProvider.none))),
        ],
        child: chatApp,
      ),
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    await container.read(webSearchSettingsProvider.notifier).ready;
    await tester.pump();
    await tester.pump();

    // No globe → web search is not reachable from chat.
    expect(find.byIcon(Icons.public), findsNothing);
    // And the enabled flag stays false (forced off for "none").
    expect(container.read(webSearchEnabledProvider), isFalse);
  });

  testWidgets('the globe toggle is shown for the default DuckDuckGo provider', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(_FakeChatRepository()),
          webSearchPreferencesProvider.overrideWithValue(_FakePrefs(const WebSearchSettings())),
        ],
        child: chatApp,
      ),
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    await container.read(webSearchSettingsProvider.notifier).ready;
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.public), findsOneWidget);
  });
}
