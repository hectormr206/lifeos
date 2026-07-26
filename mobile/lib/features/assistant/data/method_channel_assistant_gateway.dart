import 'package:flutter/services.dart';

import '../domain/assistant_gateway.dart';

/// Android [AssistantGateway] implementation for the `lifeos/assistant`
/// channel. It deliberately installs the warm handler before draining the cold
/// queue so no launch can disappear between those two lifecycle operations.
class MethodChannelAssistantGateway implements AssistantGateway {
  MethodChannelAssistantGateway({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('lifeos/assistant');

  final MethodChannel _channel;
  final Set<String> _deliveredIds = <String>{};
  void Function(AssistantActivation activation)? _onActivation;
  bool _started = false;

  @override
  Future<void> start(
    void Function(AssistantActivation activation) onActivation,
  ) async {
    if (_started) return;
    _started = true;
    _onActivation = onActivation;
    _channel.setMethodCallHandler(_handlePlatformCall);

    try {
      final pending = await _channel.invokeMethod<List<dynamic>>(
        'consumeAssistLaunches',
      );
      for (final id in pending ?? const <dynamic>[]) {
        if (id is String) _deliver(id);
      }
    } catch (_) {
      // Non-Android and teardown hosts have no native bridge. A future warm
      // callback remains harmlessly unavailable rather than breaking app boot.
    }
  }

  Future<dynamic> _handlePlatformCall(MethodCall call) async {
    if (call.method != 'assistLaunch') return null;
    final arguments = call.arguments;
    if (arguments is Map && arguments['id'] is String) {
      _deliver(arguments['id'] as String);
    }
    return null;
  }

  void _deliver(String id) {
    if (!_started || !_deliveredIds.add(id)) return;
    _onActivation?.call(AssistantActivation(id));
  }

  @override
  Future<bool> openAssistantSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openAssistantSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    _started = false;
    _onActivation = null;
    _deliveredIds.clear();
    _channel.setMethodCallHandler(null);
  }
}
