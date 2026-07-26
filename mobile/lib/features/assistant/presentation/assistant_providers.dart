import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/method_channel_assistant_gateway.dart';
import '../domain/assistant_gateway.dart';
import 'assistant_handoff_controller.dart';

/// Injectable platform boundary; routing remains outside this Unit 1 provider.
final assistantGatewayProvider = Provider<AssistantGateway>((ref) {
  final gateway = MethodChannelAssistantGateway();
  ref.onDispose(gateway.dispose);
  return gateway;
});

/// Lock-first assistant request lifecycle. app.dart owns navigation; Chat owns
/// the final mounted/eligible atomic microphone claim.
final assistantHandoffControllerProvider = Provider<AssistantHandoffController>((ref) {
  final controller = AssistantHandoffController(
    navigateToChat: () {},
    isCurrentChatRoute: () => false,
  );
  ref.onDispose(controller.dispose);
  return controller;
});
