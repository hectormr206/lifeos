import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/method_channel_assistant_gateway.dart';
import '../domain/assistant_gateway.dart';

/// Injectable platform boundary; routing remains outside this Unit 1 provider.
final assistantGatewayProvider = Provider<AssistantGateway>((ref) {
  final gateway = MethodChannelAssistantGateway();
  ref.onDispose(gateway.dispose);
  return gateway;
});
