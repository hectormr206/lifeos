// Limpiar lo que ya se guardó mal.
//
// El filtro nuevo evita que entre más basura, pero no toca lo que ya está: en
// el Cerebro del usuario siguen "la otra persona", "Axi", "esposa_nació_en".
// Esto decide QUÉ se puede olvidar sin llevarse nada por delante.
//
// La regla de oro: ante la duda, se queda. Un nodo de ruido que sobrevive es
// una molestia; un recuerdo borrado por error no vuelve.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/features/memory/domain/graph_cleanup.dart';

GraphNodeRecord node(String label, {String kind = 'entity', Map<String, Object?> data = const {}}) {
  final at = DateTime(2026, 8, 20);
  return GraphNodeRecord(
    uuid: 'u-$label',
    kind: kind,
    label: label,
    data: data,
    createdAt: at,
    updatedAt: at,
  );
}

void main() {
  group('qué se puede olvidar', () {
    test('las claves internas', () {
      final fuera = forgettableNodes([
        node('esposa_nació_en'),
        node('fecha_boda', kind: 'fact'),
      ]);

      expect(fuera.map((n) => n.label), ['esposa_nació_en', 'fecha_boda']);
    });

    test('las referencias que no señalan a nadie', () {
      // Con kind "person", que es como llegan de verdad: el Cerebro sólo
      // maneja fact, person y event. Blindar "person" entero habría dejado
      // esta limpieza sin nada que limpiar.
      final fuera = forgettableNodes([node('la otra persona', kind: 'person')]);

      expect(fuera, hasLength(1));
    });

    test('el propio asistente', () {
      expect(forgettableNodes([node('Axi', kind: 'person')]), hasLength(1));
    });

    test('un evento sin fecha ni nombre', () {
      final fuera = forgettableNodes([
        node('Casamiento', kind: 'event'),
        node('noviazgo', kind: 'event'),
      ]);

      expect(fuera, hasLength(2));
    });
  });

  group('qué NO se toca nunca', () {
    test('TU nodo, el centro de todo', () {
      // Encontrado probando en el Pixel, con el diálogo ya abierto y a un
      // toque de borrarlo: el hub del usuario se llama "Yo" y desde fuera
      // parece justo una de esas palabras vacías. Se reconoce por su marca
      // role=user, nunca por el nombre — de ahí cuelga el grafo entero.
      expect(
        forgettableNodes([
          node('Yo', kind: 'person', data: {'role': 'user'}),
          node('Usuario', kind: 'person', data: {'role': 'user'}),
        ]),
        isEmpty,
      );
    });

    test('un nodo del que cuelga media memoria, aunque se llame raro', () {
      // La segunda red, por si el hub llegara sin su marca: lo que tiene
      // muchas relaciones es un centro, no una palabra suelta. Se paga con
      // dejar vivo algún nodo feo, que es el lado bueno en el que fallar.
      final edges = [
        for (var i = 0; i < 4; i++)
          GraphEdgeRecord(
            uuid: 'e$i',
            srcUuid: 'u-Usuario',
            dstUuid: 'otro-$i',
            relation: 'about',
            createdAt: DateTime(2026, 8, 20),
            updatedAt: DateTime(2026, 8, 20),
          ),
      ];

      expect(
        forgettableNodes([node('Usuario', kind: 'person')], edges: edges),
        isEmpty,
      );
    });

    test('un nodo suelto sí se puede olvidar aunque tenga UNA relación', () {
      // Si bastara una arista, no se limpiaría nada: el extractor conecta cada
      // cosa que inventa con algo.
      final edges = [
        GraphEdgeRecord(
          uuid: 'e1',
          srcUuid: 'u-esposa_nació_en',
          dstUuid: 'otro',
          relation: 'about',
          createdAt: DateTime(2026, 8, 20),
          updatedAt: DateTime(2026, 8, 20),
        ),
      ];

      expect(
        forgettableNodes([node('esposa_nació_en')], edges: edges),
        hasLength(1),
      );
    });

    test('una persona con nombre', () {
      expect(forgettableNodes([node('Celia García Mateo', kind: 'person')]),
          isEmpty);
    });

    test('un vínculo sin nombre todavía', () {
      expect(forgettableNodes([node('mi esposa', kind: 'person')]), isEmpty);
    });

    test('un hecho que se puede leer', () {
      expect(
        forgettableNodes([
          node('Nos casamos el 6 de septiembre de 2018', kind: 'fact'),
        ]),
        isEmpty,
      );
    });

    test('una conversación, pase lo que pase', () {
      // El historial del chat no es una entidad y no se juzga con esta regla:
      // borrarlo sería borrar lo que el usuario dijo.
      expect(
        forgettableNodes([node('esposa_nació_en', kind: 'conversation')]),
        isEmpty,
      );
    });

    test('un ajuste, tampoco', () {
      // Los ajustes viajan como nodos "clave=valor" y tienen forma de clave
      // interna a propósito: olvidarlos apagaría configuración del usuario.
      expect(
        forgettableNodes([node('briefing.hour=6', kind: 'setting')]),
        isEmpty,
      );
    });

    test('nada escrito a mano por el usuario', () {
      // Si lo tecleó una persona, no lo inventó el modelo, y no nos toca
      // decidir que no significa nada.
      expect(
        forgettableNodes([
          node('noviazgo', kind: 'event', data: {'source': 'manual'}),
        ]),
        isEmpty,
      );
    });

    test('un recordatorio con forma rara sigue siendo un recordatorio', () {
      expect(
        forgettableNodes([node('cita_dentista', kind: 'reminder')]),
        isEmpty,
      );
    });
  });
}
