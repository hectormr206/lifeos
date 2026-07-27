import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/assistant_channel.dart';

/// Provider for the [AssistantChannel] gateway.
final assistantChannelProvider = Provider<AssistantChannel>((ref) {
  return AssistantChannel();
});

/// Flag set to `true` when the app is launched via Android ACTION_ASSIST so
/// the `/chat` screen knows to auto-arm the microphone on build.
final chatAssistantArmMicProvider =
    NotifierProvider<ChatAssistantArmMicNotifier, bool>(
        ChatAssistantArmMicNotifier.new);

class ChatAssistantArmMicNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void arm() => state = true;

  void consume() => state = false;
}
