import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/tray/tray_localization.dart';
import 'package:lifeos/l10n/app_localizations.dart';

/// The tray menu is the ONLY part of LifeOS a user can reach without the app
/// window in front of him, so its wording carries more weight than its size
/// suggests. It follows the same neutral, tuteo-free register as the rest of
/// `app_es.arb` ("Abrir", "Salir", not "Abra usted"), and it is localized like
/// everything else rather than hardcoded at the plugin edge.
void main() {
  Future<AppLocalizations> load(String code) =>
      AppLocalizations.delegate.load(Locale(code));

  test('Spanish labels match the app copy style', () async {
    final labels = trayMenuLabelsFrom(await load('es'));

    expect(labels.showWindow, 'Abrir LifeOS');
    expect(labels.quit, 'Salir de LifeOS');
    expect(labels.tooltip, 'LifeOS está funcionando');
  });

  test('English labels exist too — both ARBs stay in step', () async {
    final labels = trayMenuLabelsFrom(await load('en'));

    expect(labels.showWindow, 'Open LifeOS');
    expect(labels.quit, 'Quit LifeOS');
    expect(labels.tooltip, 'LifeOS is running');
  });

  test('the quit label is never empty in any supported locale', () async {
    // Load-bearing: the window close button only HIDES the app, so an empty
    // or missing quit item would leave the user with no way to close LifeOS
    // at all. A locale added later that forgot this key must fail here.
    for (final locale in AppLocalizations.supportedLocales) {
      final labels = trayMenuLabelsFrom(await load(locale.languageCode));
      expect(labels.quit.trim(), isNotEmpty, reason: 'locale ${locale.languageCode}');
      expect(labels.showWindow.trim(), isNotEmpty, reason: 'locale ${locale.languageCode}');
    }
  });

  test('the unavailable notice names the cause and says the app still works', () async {
    // House rule: the tray failing must be SAID, not swallowed. The message
    // has to carry the underlying detail (so it is actionable) and reassure
    // that the app itself is fine (so it is not alarming).
    final es = await load('es');
    final message = es.trayUnavailableMessage('sin StatusNotifierHost');

    expect(message, contains('sin StatusNotifierHost'));
    expect(message.toLowerCase(), contains('sigue funcionando'));
  });
}
