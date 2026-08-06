// The shortcut that starts and stops dictation, as a value.
//
// Today this lives OUTSIDE the app: a desktop-environment keybinding the user
// set by hand, pointing at `axi/scripts/axi-toggle`. That works only on the one
// laptop where it was configured, cannot be discovered from the app, and
// vanishes on a fresh install. Moving it into the app means it ships with the
// product — and, since it is now ours, it must also be changeable from the
// product.
//
// The one rule with teeth: a global shortcut with NO modifier would swallow
// that key everywhere in the operating system. Pressing space in any other
// application would start recording. So a bare key is not a preference we
// accept and quietly break on — it is invalid.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/dictation/domain/dictation_hotkey.dart';

void main() {
  test('the default is the shortcut the user already has in their fingers', () {
    // Super+Space, the same combination their DE binding uses today. Changing
    // it during the migration would be a regression dressed as a new feature.
    const hotkey = DictationHotkey.defaultHotkey;

    expect(hotkey.modifiers, {HotkeyModifier.meta});
    expect(hotkey.key, LogicalKeyboardKey.space);
  });

  test('it renders the way the key is printed on the keyboard', () {
    expect(DictationHotkey.defaultHotkey.label, 'Super + Espacio');
  });

  test('modifiers always read in the same order, whatever order they arrive',
      () {
    // Otherwise the settings row would show "Alt + Ctrl + D" one launch and
    // "Ctrl + Alt + D" the next, for the same stored value.
    const a = DictationHotkey(
      modifiers: {HotkeyModifier.alt, HotkeyModifier.control},
      key: LogicalKeyboardKey.keyD,
    );
    const b = DictationHotkey(
      modifiers: {HotkeyModifier.control, HotkeyModifier.alt},
      key: LogicalKeyboardKey.keyD,
    );

    expect(a.label, b.label);
    expect(a.label, 'Ctrl + Alt + D');
  });

  test('a shortcut with no modifier is INVALID, not merely discouraged', () {
    // Registering this would capture the key system-wide: every space typed in
    // every other app would toggle the microphone.
    const bare = DictationHotkey(modifiers: {}, key: LogicalKeyboardKey.space);

    expect(bare.isValid, isFalse);
    expect(DictationHotkey.defaultHotkey.isValid, isTrue);
  });

  test('a modifier alone is invalid too — there is no key to press', () {
    const noKey = DictationHotkey(
      modifiers: {HotkeyModifier.meta},
      key: LogicalKeyboardKey.meta,
    );

    expect(noKey.isValid, isFalse,
        reason: 'binding Super to Super means the modifier fires itself');
  });

  test('it survives a round trip through storage', () {
    const original = DictationHotkey(
      modifiers: {HotkeyModifier.control, HotkeyModifier.shift},
      key: LogicalKeyboardKey.keyK,
    );

    final restored = DictationHotkey.tryParse(original.toStorage());

    expect(restored, original);
  });

  test('the default round-trips too', () {
    expect(
      DictationHotkey.tryParse(DictationHotkey.defaultHotkey.toStorage()),
      DictationHotkey.defaultHotkey,
    );
  });

  test('unreadable stored text yields null, never a silent wrong shortcut', () {
    // A corrupted preference must fall back to the documented default, and the
    // caller has to make that choice explicitly rather than inherit a shortcut
    // nobody chose.
    expect(DictationHotkey.tryParse(''), isNull);
    expect(DictationHotkey.tryParse('garbage'), isNull);
    expect(DictationHotkey.tryParse('meta+'), isNull);
    expect(DictationHotkey.tryParse('nosuchmod+space'), isNull);
  });

  test('parsing rejects a stored shortcut that lost its modifier', () {
    // Storage is not a trust boundary we can skip: an invalid combination read
    // back must not be registered just because it parses.
    expect(DictationHotkey.tryParse('+${LogicalKeyboardKey.space.keyId}'),
        isNull);
  });
}
