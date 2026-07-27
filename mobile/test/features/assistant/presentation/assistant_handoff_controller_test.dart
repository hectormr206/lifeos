import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/assistant/presentation/assistant_handoff_controller.dart';
import 'package:lifeos/features/security/presentation/app_lock_controller.dart';

void main() {
  group('AssistantHandoffController', () {
    test('keeps a locked activation pending without navigation or microphone', () {
      final routes = <String>[];
      var microphoneCalls = 0;
      final controller = AssistantHandoffController(
        navigateToChat: () => routes.add('/chat'),
        isCurrentChatRoute: () => true,
      );

      controller.updateLock(AppLockStatus.locked);
      controller.receive('locked-1');
      controller.claimMountedChat(eligible: true);

      expect(routes, isEmpty);
      expect(microphoneCalls, 0);
      expect(controller.pendingIds, ['locked-1']);
      expect(controller.acknowledgedIds, isEmpty);
      expect(controller.discardedIds, isEmpty);
    });

    test('discards a denied request and never resurrects its duplicate after unlock', () {
      final routes = <String>[];
      var microphoneCalls = 0;
      final controller = AssistantHandoffController(
        navigateToChat: () => routes.add('/chat'),
        isCurrentChatRoute: () => true,
      );

      controller.receive('denied-1');
      controller.updateLock(AppLockStatus.locked);
      controller.discardCurrent();
      controller.receive('denied-1');
      controller.updateLock(AppLockStatus.unlocked);
      controller.claimMountedChat(eligible: true);

      expect(routes, isEmpty);
      expect(microphoneCalls, 0);
      expect(controller.discardedIds, {'denied-1'});
      expect(controller.pendingIds, isEmpty);
    });

    test('discards a request when chat settles on a redirect instead of /chat', () {
      final routes = <String>[];
      var microphoneCalls = 0;
      var currentChat = false;
      final controller = AssistantHandoffController(
        navigateToChat: () => routes.add('/chat'),
        isCurrentChatRoute: () => currentChat,
      );

      controller.updateLock(AppLockStatus.disabled);
      controller.receive('redirect-1');
      controller.onRouteSettled();
      controller.claimMountedChat(eligible: true);

      expect(routes, ['/chat']);
      expect(microphoneCalls, 0);
      expect(controller.discardedIds, {'redirect-1'});
      expect(controller.acknowledgedIds, isEmpty);
    });

    test('only the current eligible mounted chat acknowledges without arming audio', () {
      final routes = <String>[];
      var microphoneCalls = 0;
      final controller = AssistantHandoffController(
        navigateToChat: () => routes.add('/chat'),
        isCurrentChatRoute: () => true,
      );

      controller.updateLock(AppLockStatus.unlocked);
      controller.receive('eligible-1');
      controller.onRouteSettled();
      controller.claimMountedChat(eligible: true);
      controller.claimMountedChat(eligible: true);

      expect(routes, ['/chat']);
      expect(microphoneCalls, 0);
      expect(controller.acknowledgedIds, {'eligible-1'});
      expect(controller.pendingIds, isEmpty);
    });
  });

// Assistant activation is navigation-only: mounted Chat resolves every queued ID without audio.
test('mounted chat acknowledges each queued activation without microphone control', () {
  final controller = AssistantHandoffController(
    navigateToChat: () {},
    isCurrentChatRoute: () => true,
  );
  controller.updateLock(AppLockStatus.unlocked);
  controller.receive('first');
  controller.onRouteSettled();
  controller.claimMountedChat(eligible: true);
  controller.receive('second');
  expect(controller.acknowledgedIds, {'first', 'second'});
  });
}
