// A global shortcut is a desktop concept. The phone's equivalent is the
// assistant gesture, which is a different mechanism with a different setup
// screen — so the hotkey row must be ABSENT on Android, not shown and inert.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/platform/app_platform.dart';

void main() {
  test('the three desktop shells can claim a system-wide shortcut', () {
    expect(supportsGlobalHotkeys('linux'), isTrue);
    expect(supportsGlobalHotkeys('macos'), isTrue);
    expect(supportsGlobalHotkeys('windows'), isTrue);
  });

  test('the phones cannot — they have no such concept', () {
    expect(supportsGlobalHotkeys('android'), isFalse);
    expect(supportsGlobalHotkeys('ios'), isFalse);
  });

  test('an unknown shell answers no, like every other capability', () {
    expect(supportsGlobalHotkeys('web'), isFalse);
    expect(supportsGlobalHotkeys('fuchsia'), isFalse);
  });
}
