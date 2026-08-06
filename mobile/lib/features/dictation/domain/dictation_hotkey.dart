/// The keyboard shortcut that starts and stops dictation, as a value object.
///
/// WHY THIS EXISTS AT ALL. Today the shortcut is not part of LifeOS: it is a
/// desktop-environment keybinding the user configured by hand, pointing at
/// `axi/scripts/axi-toggle`. That works on exactly one laptop, cannot be seen
/// or changed from the app, and disappears on a fresh install — the same class
/// of problem as needing a terminal to update. Owning it in the app means it
/// ships with the product and is changeable inside the product.
///
/// THE RULE WITH TEETH. A global shortcut is registered with the OS, so it
/// fires no matter which application has focus. Bound to a bare key, it would
/// capture that key EVERYWHERE — every space typed in every other program would
/// toggle the microphone. So "no modifier" is not a discouraged choice, it is
/// an invalid one, rejected both when the user picks it and when it is read
/// back from storage. Storage is not a trust boundary we get to skip.
library;

import 'package:flutter/services.dart';

/// The modifiers a shortcut may carry. Deliberately a small closed set rather
/// than the platform package's enum: this is the app's own persisted format,
/// and it must not change meaning when a dependency is upgraded.
enum HotkeyModifier {
  /// The Super / Windows / Command key.
  meta,
  control,
  alt,
  shift,
}

/// A modifier + key combination.
class DictationHotkey {
  const DictationHotkey({required this.modifiers, required this.key});

  /// Super + Space — the combination the user's DE binding already uses.
  ///
  /// Keeping it identical through the migration is the point: a shortcut that
  /// is already in someone's fingers is worse than useless if it moves.
  static const DictationHotkey defaultHotkey = DictationHotkey(
    modifiers: {HotkeyModifier.meta},
    key: LogicalKeyboardKey.space,
  );

  final Set<HotkeyModifier> modifiers;
  final LogicalKeyboardKey key;

  /// Canonical display order, so the same stored value always renders the same
  /// way. Without this the settings row would show "Alt + Ctrl + D" on one
  /// launch and "Ctrl + Alt + D" on the next.
  static const List<HotkeyModifier> _displayOrder = [
    HotkeyModifier.control,
    HotkeyModifier.alt,
    HotkeyModifier.shift,
    HotkeyModifier.meta,
  ];

  static const Map<HotkeyModifier, String> _modifierLabels = {
    HotkeyModifier.control: 'Ctrl',
    HotkeyModifier.alt: 'Alt',
    HotkeyModifier.shift: 'Shift',
    HotkeyModifier.meta: 'Super',
  };

  /// Whether this combination is safe to register system-wide.
  ///
  /// Requires at least one modifier (see the class comment) and a key that is
  /// not itself a modifier — binding Super to Super means the modifier fires
  /// itself the moment it is pressed.
  bool get isValid => modifiers.isNotEmpty && !_isModifierKey(key);

  /// Human-facing rendering, e.g. `Super + Espacio`.
  String get label {
    final parts = [
      for (final modifier in _displayOrder)
        if (modifiers.contains(modifier)) _modifierLabels[modifier]!,
      _keyLabel(key),
    ];
    return parts.join(' + ');
  }

  /// Stable storage form: `mod,mod+keyId`. Uses [LogicalKeyboardKey.keyId]
  /// rather than the debug label because the label is not a stable API.
  String toStorage() {
    final mods = [
      for (final modifier in _displayOrder)
        if (modifiers.contains(modifier)) modifier.name,
    ].join(',');
    return '$mods+${key.keyId}';
  }

  /// Parse a stored shortcut, or null when it is missing, corrupt, or would be
  /// unsafe to register. Null means "the caller decides" — usually falling back
  /// to [defaultHotkey] — rather than a shortcut nobody chose.
  static DictationHotkey? tryParse(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    final split = stored.lastIndexOf('+');
    if (split <= 0 || split == stored.length - 1) return null;

    final keyId = int.tryParse(stored.substring(split + 1));
    if (keyId == null) return null;

    final modifiers = <HotkeyModifier>{};
    for (final name in stored.substring(0, split).split(',')) {
      if (name.isEmpty) continue;
      final match = HotkeyModifier.values.where((m) => m.name == name).firstOrNull;
      if (match == null) return null; // unknown modifier: refuse to guess
      modifiers.add(match);
    }

    final hotkey = DictationHotkey(
      modifiers: modifiers,
      key: LogicalKeyboardKey.findKeyByKeyId(keyId) ?? LogicalKeyboardKey(keyId),
    );
    return hotkey.isValid ? hotkey : null;
  }

  // Not `const`: LogicalKeyboardKey overrides ==, so it cannot be a const Set
  // element. `static final` still builds it exactly once.
  static final Set<LogicalKeyboardKey> _modifierKeys = {
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
  };

  static bool _isModifierKey(LogicalKeyboardKey key) => _modifierKeys.contains(key);

  static String _keyLabel(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.space) return 'Espacio';
    if (key == LogicalKeyboardKey.enter) return 'Enter';
    if (key == LogicalKeyboardKey.tab) return 'Tab';
    if (key == LogicalKeyboardKey.escape) return 'Esc';
    final label = key.keyLabel;
    return label.isEmpty ? 'Tecla ${key.keyId}' : label.toUpperCase();
  }

  @override
  bool operator ==(Object other) =>
      other is DictationHotkey &&
      other.key == key &&
      other.modifiers.length == modifiers.length &&
      other.modifiers.containsAll(modifiers);

  @override
  int get hashCode => Object.hash(key, Object.hashAllUnordered(modifiers));

  @override
  String toString() => 'DictationHotkey($label)';
}
