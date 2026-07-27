import 'package:flutter/services.dart';

/// Wrapper over the `lifeos/assistant` MethodChannel (implemented in MainActivity.kt)
/// for the Android Digital Assistant role (ACTION_ASSIST).
class AssistantChannel {
  AssistantChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('lifeos/assistant');

  final MethodChannel _channel;

  /// Registers a callback for warm-resume assist launches (app already in memory
  /// when the user long-presses power / triggers the assistant gesture).
  void registerAssistHandler(void Function() onAssistLaunch) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'assistLaunch') {
        onAssistLaunch();
      }
    });
  }

  /// Checks if this cold start was triggered by an assist launch (ACTION_ASSIST).
  /// Resets the pending flag on the native side.
  Future<bool> consumeAssistLaunch() async {
    try {
      return await _channel.invokeMethod<bool>('consumeAssistLaunch') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens system settings where the user can pick LifeOS / Axi as their
  /// default digital assistant app.
  Future<bool> openAssistantSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openAssistantSettings') ?? false;
    } catch (_) {
      return false;
    }
  }
}
