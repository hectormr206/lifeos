/// One Android digital-assistant activation delivered to the Flutter app.
class AssistantActivation {
  const AssistantActivation(this.id);

  final String id;
}

/// Boundary around Android's assistant platform channel.
abstract interface class AssistantGateway {
  /// Registers warm delivery before consuming any cold-start activations.
  Future<void> start(void Function(AssistantActivation activation) onActivation);

  /// Opens Android's default-assistant settings when the platform supports it.
  Future<bool> openAssistantSettings();

  /// Stops warm delivery and releases platform-channel state.
  Future<void> dispose();
}
