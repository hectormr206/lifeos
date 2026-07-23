import 'package:flutter/services.dart';

/// Thin wrapper over the `lifeos/dictation` MethodChannel (implemented in
/// MainActivity.kt) for the Axi keyboard (IME) setup flow: enabling an input
/// method and opening the system keyboard picker have no Flutter/plugin API.
///
/// Injectable so tests (and the provider graph) can swap a fake.
class DictationChannel {
  DictationChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('lifeos/dictation');

  final MethodChannel _channel;

  /// Opens the system "input methods" screen where the user toggles Axi on.
  Future<void> openImeSettings() => _channel.invokeMethod<void>('openImeSettings');

  /// Shows the system keyboard picker so the user can switch to Axi.
  Future<void> showImePicker() => _channel.invokeMethod<void>('showImePicker');

  /// Whether the Axi keyboard is enabled in system settings (step 1 done).
  Future<bool> isImeEnabled() async =>
      await _channel.invokeMethod<bool>('isImeEnabled') ?? false;

  /// Whether the Axi keyboard is the currently selected one (step 2 done).
  Future<bool> isImeSelected() async =>
      await _channel.invokeMethod<bool>('isImeSelected') ?? false;
}
