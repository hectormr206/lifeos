// Proves DomainNotifier's lifecycle (spec mobile-domain-crud): loading ->
// data on init, error surfacing, refresh, and NL quick-capture reusing the
// SAME chatRepositoryProvider the chat feature already talks to (documented
// decision — see apply-progress). No live engine — both repositories faked.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'dart:typed_data';

import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/domains/data/domain_repository.dart';
import 'package:lifeos/features/domains/domain/domain_descriptor.dart';
import 'package:lifeos/features/domains/domain/domain_entry.dart';
import 'package:lifeos/features/domains/presentation/domain_notifier.dart';

class _FakeDomainRepository implements DomainRepository {
  _FakeDomainRepository({this.entries = const [], this.error, this.createError, this.createResult});

  final List<DomainEntry> entries;
  final DomainException? error;
  final DomainException? createError;
  final DomainEntry? createResult;
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
    if (createError != null) throw createError!;
    return createResult ?? DomainEntry(id: 'created1', title: body['title'] as String? ?? '', timestamp: DateTime.now());
  }
}

class _FakeChatRepository implements ChatRepository {
  _FakeChatRepository({this.sendResult});

  final Object? sendResult; // ChatMessage (success) or Exception (failure)
  int sendCalls = 0;
  String? lastText;

  @override
  Future<List<ChatMessage>> loadHistory() async => const [];

  @override
  Future<ChatMessage> sendImages(String text, List<Uint8List> images) =>
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
  final descriptor = domainDescriptors.firstWhere((d) => d.key == 'health');

  group('DomainNotifier', () {
    test('loads entries on init', () async {
      final entry = DomainEntry(id: '1', title: 'Presión', timestamp: DateTime.utc(2026, 1, 1));
      final repo = _FakeDomainRepository(entries: [entry]);
      final container = ProviderContainer(overrides: [domainRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(domainNotifierProvider(descriptor).notifier);
      await notifier.ready;

      final state = container.read(domainNotifierProvider(descriptor));
      expect(state.loading, isFalse);
      expect(state.entries, [entry]);
      expect(state.error, isNull);
    });

    test('error path surfaces the error message and keeps entries empty', () async {
      final repo = _FakeDomainRepository(error: DomainException('boom'));
      final container = ProviderContainer(overrides: [domainRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(domainNotifierProvider(descriptor).notifier);
      await notifier.ready;

      final state = container.read(domainNotifierProvider(descriptor));
      expect(state.loading, isFalse);
      expect(state.entries, isEmpty);
      expect(state.error, 'boom');
    });

    test('refresh reloads entries from the repository', () async {
      final repo = _FakeDomainRepository();
      final container = ProviderContainer(overrides: [domainRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(domainNotifierProvider(descriptor).notifier);
      await notifier.ready;
      expect(repo.listCalls, 1);

      await notifier.refresh();

      expect(repo.listCalls, 2);
    });

    test('capture sends text through chatRepositoryProvider then refreshes the list', () async {
      final domainRepo = _FakeDomainRepository();
      final chatRepo = _FakeChatRepository(
        sendResult: ChatMessage(id: 'a', role: ChatRole.axi, text: 'listo', timestamp: DateTime.now()),
      );
      final container = ProviderContainer(overrides: [
        domainRepositoryProvider.overrideWithValue(domainRepo),
        chatRepositoryProvider.overrideWithValue(chatRepo),
      ]);
      addTearDown(container.dispose);
      final notifier = container.read(domainNotifierProvider(descriptor).notifier);
      await notifier.ready;
      expect(domainRepo.listCalls, 1);

      await notifier.capture('presión 120/80');

      expect(chatRepo.sendCalls, 1);
      expect(chatRepo.lastText, 'presión 120/80');
      expect(domainRepo.listCalls, 2);
      final state = container.read(domainNotifierProvider(descriptor));
      expect(state.capturing, isFalse);
      expect(state.captureError, isNull);
    });

    test('capture failure sets captureError and does not refresh', () async {
      final domainRepo = _FakeDomainRepository();
      final chatRepo = _FakeChatRepository(sendResult: ChatException('no se pudo'));
      final container = ProviderContainer(overrides: [
        domainRepositoryProvider.overrideWithValue(domainRepo),
        chatRepositoryProvider.overrideWithValue(chatRepo),
      ]);
      addTearDown(container.dispose);
      final notifier = container.read(domainNotifierProvider(descriptor).notifier);
      await notifier.ready;
      expect(domainRepo.listCalls, 1);

      await notifier.capture('algo');

      expect(domainRepo.listCalls, 1);
      final state = container.read(domainNotifierProvider(descriptor));
      expect(state.capturing, isFalse);
      expect(state.captureError, isNotNull);
    });

    test('NL capture works for a new (M2 slice 2) domain the same generic way — relationships', () async {
      final relationships = domainDescriptors.firstWhere((d) => d.key == 'relationships');
      final domainRepo = _FakeDomainRepository();
      final chatRepo = _FakeChatRepository(
        sendResult: ChatMessage(id: 'a', role: ChatRole.axi, text: 'listo', timestamp: DateTime.now()),
      );
      final container = ProviderContainer(overrides: [
        domainRepositoryProvider.overrideWithValue(domainRepo),
        chatRepositoryProvider.overrideWithValue(chatRepo),
      ]);
      addTearDown(container.dispose);
      final notifier = container.read(domainNotifierProvider(relationships).notifier);
      await notifier.ready;

      await notifier.capture('llamé a mi mamá y platicamos');

      expect(chatRepo.sendCalls, 1);
      expect(chatRepo.lastText, 'llamé a mi mamá y platicamos');
      expect(domainRepo.listCalls, 2);
      final state = container.read(domainNotifierProvider(relationships));
      expect(state.captureError, isNull);
    });

    test('capture ignores blank input', () async {
      final domainRepo = _FakeDomainRepository();
      final chatRepo = _FakeChatRepository();
      final container = ProviderContainer(overrides: [
        domainRepositoryProvider.overrideWithValue(domainRepo),
        chatRepositoryProvider.overrideWithValue(chatRepo),
      ]);
      addTearDown(container.dispose);
      final notifier = container.read(domainNotifierProvider(descriptor).notifier);
      await notifier.ready;

      await notifier.capture('   ');

      expect(chatRepo.sendCalls, 0);
      expect(domainRepo.listCalls, 1);
    });
  });

  group('DomainNotifier.createEntry (spec structured-domain-forms)', () {
    test('posts the body via the repository and prepends the created entry to the list', () async {
      final repo = _FakeDomainRepository(
        entries: [DomainEntry(id: 'existing', title: 'Viejo', timestamp: DateTime.utc(2026, 1, 1))],
        createResult: DomainEntry(id: 'new1', title: 'Presión', timestamp: DateTime.utc(2026, 1, 2)),
      );
      final container = ProviderContainer(overrides: [domainRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(domainNotifierProvider(descriptor).notifier);
      await notifier.ready;

      final ok = await notifier.createEntry({'kind': 'vital', 'title': 'Presión'});

      expect(ok, isTrue);
      expect(repo.createCalls, 1);
      expect(repo.lastCreateBody, {'kind': 'vital', 'title': 'Presión'});
      final state = container.read(domainNotifierProvider(descriptor));
      expect(state.entries.map((e) => e.id), ['new1', 'existing']);
      expect(state.creating, isFalse);
      expect(state.createError, isNull);
    });

    test('a repository failure sets createError and does not touch the entries list', () async {
      final existing = DomainEntry(id: 'existing', title: 'Viejo', timestamp: DateTime.utc(2026, 1, 1));
      final repo = _FakeDomainRepository(entries: [existing], createError: DomainException('kind is required'));
      final container = ProviderContainer(overrides: [domainRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(domainNotifierProvider(descriptor).notifier);
      await notifier.ready;

      final ok = await notifier.createEntry({'title': 'sin kind'});

      expect(ok, isFalse);
      final state = container.read(domainNotifierProvider(descriptor));
      expect(state.createError, 'kind is required');
      expect(state.entries, [existing]);
      expect(state.creating, isFalse);
    });
  });
}
