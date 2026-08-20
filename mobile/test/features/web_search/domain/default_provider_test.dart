// A quién le pregunta Axi cuando nadie ha elegido.
//
// El valor por defecto era DuckDuckGo, que es exactamente el que responde
// CAPTCHA desde un centro de datos y, con el tiempo, a una casa que pregunta
// seguido. Si la app viene compilada con buscador propio, ese debe ser el
// punto de partida — pero SÓLO para quien nunca eligió: cambiarle el buscador
// a alguien que sí lo escogió es decidir por él a dónde van sus búsquedas.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/web_search/domain/web_search_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('nunca elegido + app con buscador propio → el propio', () async {
    final prefs = SharedPrefsWebSearchPreferences(
      prefs: await SharedPreferences.getInstance(),
      hasBundledInstance: true,
    );

    expect((await prefs.load()).provider, WebSearchProvider.searxng);
  });

  test('nunca elegido + app sin buscador propio → como siempre', () async {
    final prefs = SharedPrefsWebSearchPreferences(
      prefs: await SharedPreferences.getInstance(),
      hasBundledInstance: false,
    );

    expect((await prefs.load()).provider, WebSearchProvider.duckduckgo);
  });

  test('quien eligió DuckDuckGo se queda con DuckDuckGo', () async {
    SharedPreferences.setMockInitialValues({
      SharedPrefsWebSearchPreferences.providerKey: 'duckduckgo',
    });
    final prefs = SharedPrefsWebSearchPreferences(
      prefs: await SharedPreferences.getInstance(),
      hasBundledInstance: true,
    );

    expect((await prefs.load()).provider, WebSearchProvider.duckduckgo);
  });

  test('quien apagó la búsqueda sigue con la búsqueda apagada', () async {
    // Lo contrario sería encenderle una conexión a internet que apagó a mano.
    SharedPreferences.setMockInitialValues({
      SharedPrefsWebSearchPreferences.providerKey: 'none',
    });
    final prefs = SharedPrefsWebSearchPreferences(
      prefs: await SharedPreferences.getInstance(),
      hasBundledInstance: true,
    );

    expect((await prefs.load()).provider, WebSearchProvider.none);
  });

  test('un valor guardado que ya no existe no arrastra a nadie', () async {
    SharedPreferences.setMockInitialValues({
      SharedPrefsWebSearchPreferences.providerKey: 'bing-de-2011',
    });
    final prefs = SharedPrefsWebSearchPreferences(
      prefs: await SharedPreferences.getInstance(),
      hasBundledInstance: true,
    );

    expect((await prefs.load()).provider, WebSearchProvider.searxng);
  });
}
