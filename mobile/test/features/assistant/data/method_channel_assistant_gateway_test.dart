import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/assistant/data/method_channel_assistant_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('lifeos/assistant');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('registers the warm callback before it consumes cold activations', () async {
    final calls = <String>[];
    final activations = <String>[];
    Map? completion;
    final gateway = MethodChannelAssistantGateway(channel: channel);

    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'assistantReadyAndDrain') return <String>['cold-1'];
      if (call.method == 'completeAssistLaunch') {
        completion = call.arguments as Map;
        return true;
      }
      return null;
    });

    await gateway.start((activation) => activations.add(activation.id));

    expect(calls, ['assistantReadyAndDrain']);
    expect(activations, ['cold-1']);
    expect(await gateway.complete('cold-1', AssistantTerminalOutcome.acknowledged), isTrue);
    expect(completion, {'id': 'cold-1', 'outcome': 'acknowledged'});
    await gateway.dispose();
  });

  test('deduplicates a cold warm race and preserves distinct later IDs', () async {
    final activations = <String>[];
    final gateway = MethodChannelAssistantGateway(channel: channel);

    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'assistantReadyAndDrain') return <String>['same', 'next'];
      if (call.method == 'drainAssistLaunches') return <String>['same', 'later'];
      return null;
    });

    await gateway.start((activation) => activations.add(activation.id));
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('assistAvailable')),
      (_) {},
    );

    expect(activations, ['same', 'next', 'later']);
    await gateway.dispose();
  });

  test('returns false when assistant settings is unsupported', () async {
    final gateway = MethodChannelAssistantGateway(channel: channel);
    messenger.setMockMethodCallHandler(channel, (call) async => false);

    expect(await gateway.openAssistantSettings(), isFalse);
    await gateway.dispose();
  });
}
