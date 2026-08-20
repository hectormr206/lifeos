// Los ajustes que viajan, guardados como nodos del grafo.
//
// Como nodos y no en un canal nuevo. Eso no es elegancia: el grafo ya va
// cifrado de punta a punta, ya resuelve conflictos por lamport, ya deja
// lápidas y ya se reintenta solo. Un segundo mecanismo tendría que volver a
// ganarse cada una de esas propiedades, y fallaría en la que a nadie se le
// ocurriera probar.
//
// Qué viaja y qué no lo decide `domain/synced_settings.dart`, y esta clase lo
// obedece sin excepciones: un ajuste que describe al aparato jamás llega aquí.
library;

import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import '../domain/synced_settings.dart';

/// El `kind` de los nodos de ajuste. Aparte de 'fact' a propósito: un ajuste
/// no es un recuerdo, no debe salir en el Cerebro, ni en "Mi vida", ni en la
/// memoria que lee el modelo.
const String kSettingNodeKind = 'setting';

class SyncedSettingsStore {
  SyncedSettingsStore(this._store);

  final LocalGraphStore _store;

  /// El valor guardado, o null cuando nadie lo ha puesto.
  ///
  /// Null y no cadena vacía: null deja que el llamador use SU valor por
  /// defecto, mientras que un vacío lo sobrescribiría con nada.
  Future<String?> get(String key) async => (await all())[key];

  Future<Map<String, String>> all() async {
    try {
      final nodes = await _store.listNodesByKind(kSettingNodeKind);
      final out = <String, String>{};
      for (final node in nodes) {
        final at = node.label.indexOf('=');
        if (at <= 0) continue;
        final key = node.label.substring(0, at);
        if (!isSyncedSetting(key)) continue;
        out[key] = node.label.substring(at + 1);
      }
      return out;
    } catch (_) {
      // Sin grafo, el llamador se queda con sus valores por defecto locales.
      return const {};
    }
  }

  /// Guarda [key] y lo deja listo para viajar.
  ///
  /// Un ajuste que no viaja se ignora en silencio AQUÍ, en vez de confiar en
  /// que cada llamador se acuerde: el fallo sería sincronizar un hecho sobre
  /// este aparato al resto, y lo descubriría el usuario.
  Future<void> put(String key, String value) async {
    if (!isSyncedSetting(key)) return;
    try {
      // Una clave, un nodo. Dos nodos para lo mismo y el otro aparato recibe
      // ambos sin saber cuál es el vigente.
      final existing = await _store.listNodesByKind(kSettingNodeKind);
      for (final node in existing) {
        if (node.label.startsWith('$key=')) {
          await _store.softDeleteNode(node.uuid);
        }
      }
      await _store.createNode(
        kind: kSettingNodeKind,
        label: '$key=$value',
        domain: 'settings',
      );
    } catch (_) {
      // Best-effort: el ajuste ya está aplicado localmente por su propio
      // almacén; esto sólo es lo que lo hace viajar.
    }
  }
}
