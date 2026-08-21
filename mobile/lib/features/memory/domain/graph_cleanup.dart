/// Limpiar lo que ya se guardó mal.
///
/// El filtro de [isMeaningfulEntity] evita que entren más nodos sin
/// significado, pero no toca los que ya están: en un Cerebro con meses de uso
/// siguen "la otra persona", "Axi" o "esposa_nació_en", y el ruido es
/// justamente lo que hace que no se encuentre lo que importa.
///
/// LA REGLA DE ORO. Ante la duda, se queda. Un nodo de ruido que sobrevive es
/// una molestia; un recuerdo borrado por error no vuelve. Por eso esto es una
/// lista corta y explícita de lo que SÍ se puede olvidar, y todo lo demás se
/// respeta aunque parezca inútil.
library;

import '../../../core/graph/graph_records.dart';
import 'meaningful_entity.dart';

/// Tipos de nodo que esta limpieza NO juzga nunca, sea cual sea su etiqueta.
///
/// Una conversación es lo que el usuario dijo. Un ajuste tiene forma de clave
/// interna a propósito ("briefing.hour=6") y olvidarlo apagaría su
/// configuración. Un recordatorio existe para sonar, no para leerse bonito.
///
/// "person" NO está aquí, y es deliberado: los nodos que el usuario quiere
/// quitar —"la otra persona", "Axi"— llegaron como personas. Lo que protege a
/// las personas de verdad es [isMeaningfulEntity], que deja pasar cualquier
/// nombre propio y cualquier vínculo ("mi esposa") aunque no sepamos su
/// nombre. Blindar el tipo entero habría hecho que esta limpieza no limpiara
/// justo lo que se pidió limpiar.
const Set<String> _untouchable = {
  'conversation',
  'setting',
  'reminder',
  'person_link',
};

/// Lo que se puede olvidar de [nodes], en el mismo orden.
List<GraphNodeRecord> forgettableNodes(Iterable<GraphNodeRecord> nodes) => [
      for (final node in nodes)
        if (_isForgettable(node)) node,
    ];

bool _isForgettable(GraphNodeRecord node) {
  if (_untouchable.contains(node.kind)) return false;
  // Escrito a mano por una persona: no lo inventó el modelo, y no nos toca
  // decidir que no significa nada.
  final source = node.data['source']?.toString();
  if (source != null && source != 'relation_extractor') return false;

  if (node.kind == 'fact') return !isMeaningfulFactLabel(node.label);
  return !isMeaningfulEntity(name: node.label, kind: node.kind);
}
