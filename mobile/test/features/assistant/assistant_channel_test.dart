import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/assistant/data/assistant_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AssistantChannel', () {
    const channel = MethodChannel('lifeos/assistant');
    final log = <MethodCall>[];

    setUp(() {
      log.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        log.add(call);
        switch (call.method) {
          case 'consumeAssistLaunch':
            return true;
          case 'openAssistantSettings':
            return true;
          default:
            return null;
        }
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('consumeAssistLaunch returns value from method channel', () async {
      final assistant = AssistantChannel();
      final result = await assistant.consumeAssistLaunch();

      expect(result, isTrue);
      expect(log.length, equals(1));
      expect(log.first.method, equals('consumeAssistLaunch'));
    });

    test('openAssistantSettings returns value from method channel', () async {
      final assistant = AssistantChannel();
      final result = await assistant.openAssistantSettings();

      expect(result, isTrue);
      expect(log.length, equals(1));
      expect(log.first.method, equals('openAssistantSettings'));
    });

    test('registerAssistHandler triggers callback on assistLaunch method call', () async {
      final assistant = AssistantChannel();
      bool triggered = false;

      assistant.registerAssistHandler(() {
        triggered = true;
      });

      // Simulate native side calling assistLaunch over the channel
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'lifeos/assistant',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('assistLaunch', null)),
        (_) {},
      );

      expect(triggered, isTrue);
    });
  });
}
