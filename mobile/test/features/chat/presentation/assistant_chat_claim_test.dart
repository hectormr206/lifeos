import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/assistant/presentation/assistant_handoff_controller.dart';
import 'package:lifeos/features/security/presentation/app_lock_controller.dart';

void main() {
  test('mounted chat discards an eligibility-race request without starting audio', () {
    var microphoneCalls = 0;
    final controller = AssistantHandoffController(
      navigateToChat: () {},
      isCurrentChatRoute: () => true,
    );

    controller.updateLock(AppLockStatus.disabled);
    controller.receive('chat-claim-1');
    controller.onRouteSettled();
    controller.claimMountedChat(eligible: false, armMicrophone: () => microphoneCalls++);

    expect(controller.discardedIds, {'chat-claim-1'});
    expect(controller.acknowledgedIds, isEmpty);
    expect(microphoneCalls, 0);
  });

  test('a non-chat route at claim time cannot acknowledge or arm', () {
    var microphoneCalls = 0;
    var currentChat = true;
    final controller = AssistantHandoffController(
      navigateToChat: () {},
      isCurrentChatRoute: () => currentChat,
    );

    controller.updateLock(AppLockStatus.unlocked);
    controller.receive('chat-race-1');
    currentChat = false;
    controller.onRouteSettled();
    controller.claimMountedChat(eligible: true, armMicrophone: () => microphoneCalls++);

    expect(controller.discardedIds, {'chat-race-1'});
    expect(controller.acknowledgedIds, isEmpty);
    expect(microphoneCalls, 0);
  });
}
