/// El buscador que LifeOS trae puesto.
///
/// POR QUÉ EXISTE. Axi buscaba por DuckDuckGo. Medido desde el servidor el
/// 2026-08-19 y confirmado el 2026-08-20: DuckDuckGo y Startpage responden
/// CAPTCHA a quien pregunta desde un centro de datos, y con el tiempo también
/// a una casa que pregunta seguido. Depender de eso es tener búsqueda hasta el
/// día que se apaga, sin aviso y sin nada que podamos arreglar.
///
/// La app viene compilada apuntando a una instancia propia de SearXNG, detrás
/// de una puerta que exige una llave. La llave viaja COMPILADA y no en las
/// preferencias: nadie tiene que pegarla, no se enseña en ninguna pantalla y
/// no hay un campo desde el que pueda salir. Va como cabecera, nunca en la
/// URL, donde acabaría en el registro del servidor y en cualquier historial.
///
/// Un checkout no lleva el servidor de nadie dentro: sin `--dart-define` esto
/// queda vacío y la app se comporta como antes.
library;

class BundledSearchInstance {
  const BundledSearchInstance({required this.baseUrl, required this.accessKey});

  /// Lo que la compilación dejó dentro. Vacío en un checkout.
  static const BundledSearchInstance fromBuild = BundledSearchInstance(
    baseUrl: String.fromEnvironment('LIFEOS_SEARCH_BASE_URL'),
    accessKey: String.fromEnvironment('LIFEOS_SEARCH_KEY'),
  );

  final String baseUrl;
  final String accessKey;

  /// Las dos cosas, o ninguna.
  ///
  /// Una dirección sin llave no es media configuración: es una puerta que va a
  /// responder 403 a cada pregunta que haga el usuario, en silencio.
  bool get isConfigured =>
      baseUrl.trim().isNotEmpty && accessKey.trim().isNotEmpty;

  String get url => baseUrl.trim();
  String get key => accessKey.trim();
}
