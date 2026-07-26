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
    final gateway = MethodChannelAssistantGateway(channel: channel);

    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'consumeAssistLaunches') return <String>['cold-1'];
      return null;
    });

    await gateway.start((activation) => activations.add(activation.id));

    expect(calls, ['consumeAssistLaunches']);
    expect(activations, ['cold-1']);
    await gateway.dispose();
  });

  test('deduplicates a cold warm race and preserves distinct later IDs', () async {
    final activations = <String>[];
    final gateway = MethodChannelAssistantGateway(channel: channel);

    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'consumeAssistLaunches') {
        await messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(const MethodCall('assistLaunch', {'id': 'same'})),
          (_) {},
        );
        return <String>['same', 'next'];
      }
      return null;
    });

    await gateway.start((activation) => activations.add(activation.id));
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('assistLaunch', {'id': 'later'})),
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
