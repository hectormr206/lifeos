// Qué merece ser un nodo del Cerebro.
//
// Visto en el Cerebro 3D el 2026-08-20, entre 41 nodos: "la otra persona",
// "Axi", "esposa_nació", "noviazgo", "Casamiento", "Lugar del casamiento".
// Ninguno de esos dice nada de la vida de nadie: son una referencia sin
// identidad, el propio asistente, el nombre interno de un campo y tres
// etiquetas sueltas. El grafo se llena de ruido y lo que sí importa se pierde
// dentro.
//
// Los nombra el modelo, y el prompt ya pedía "entidades NOMBRADAS y concretas".
// No obedece — así que se decide aquí.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/meaningful_entity.dart';

void main() {
  group('lo que NO merece un nodo', () {
    test('una referencia sin identidad', () {
      for (final vago in [
        'la otra persona',
        'esa persona',
        'alguien',
        'una persona',
        'la persona',
      ]) {
        expect(isMeaningfulEntity(name: vago, kind: 'person'), isFalse,
            reason: '"$vago" no es nadie');
      }
    });

    test('el propio asistente', () {
      // Axi no es parte de la vida del usuario: es quien pregunta.
      expect(isMeaningfulEntity(name: 'Axi', kind: 'person'), isFalse);
      expect(isMeaningfulEntity(name: 'LifeOS', kind: 'org'), isFalse);
    });

    test('el nombre interno de un campo', () {
      // "esposa_nació" es una clave, no una cosa del mundo.
      expect(isMeaningfulEntity(name: 'esposa_nació', kind: 'event'), isFalse);
      expect(isMeaningfulEntity(name: 'fecha_boda', kind: 'thing'), isFalse);
      // Visto en el Pixel con la primera versión del filtro: tres partes, y
      // el patrón sólo cubría dos.
      expect(
        isMeaningfulEntity(name: 'esposa_nació_en', kind: 'event'),
        isFalse,
      );
      expect(
        isMeaningfulEntity(name: 'lugar_de_nacimiento_esposa', kind: 'place'),
        isFalse,
      );
    });

    test('un sustantivo suelto sin nada concreto', () {
      // "Casamiento" o "noviazgo" sin fecha ni nombre no dicen cuándo, ni de
      // quién: no se puede volver a ellos a buscar nada.
      for (final suelto in ['Casamiento', 'noviazgo', 'Lugar del casamiento']) {
        expect(isMeaningfulEntity(name: suelto, kind: 'event'), isFalse,
            reason: '"$suelto" no lleva a ninguna parte');
      }
    });

    test('sin tipo, se exige lo mismo que a un nombre propio', () {
      // El modelo a veces no manda el tipo. Tratar eso como "cosa" dejaría
      // pasar cualquier palabra suelta y el filtro entero no serviría de nada.
      expect(isMeaningfulEntity(name: 'noviazgo', kind: 'unknown'), isFalse);
      expect(isMeaningfulEntity(name: 'Celia', kind: 'unknown'), isTrue);
    });

    test('una cadena vacía o de puntuación', () {
      expect(isMeaningfulEntity(name: '  ', kind: 'person'), isFalse);
      expect(isMeaningfulEntity(name: '—', kind: 'thing'), isFalse);
    });
  });

  group('los hechos', () {
    test('el nombre de una casilla no es un hecho', () {
      expect(isMeaningfulFactLabel('esposa_nació_en'), isFalse);
      expect(isMeaningfulFactLabel('fecha_boda'), isFalse);
    });

    test('un hecho de verdad se guarda entero', () {
      expect(
        isMeaningfulFactLabel('Su esposa nació en Cadereyta de Montes'),
        isTrue,
      );
    });

    test('un hecho corto y raro también', () {
      // Descartar lo corto por serlo perdería justo lo que hay que guardar.
      expect(isMeaningfulFactLabel('diabetes tipo 2'), isTrue);
    });
  });

  group('lo que SÍ merece un nodo', () {
    test('una persona con nombre', () {
      expect(
        isMeaningfulEntity(name: 'Celia García Mateo', kind: 'person'),
        isTrue,
      );
    });

    test('un vínculo familiar, aunque vaya en minúscula', () {
      // Mientras no sepamos el nombre, "mi esposa" es la mejor identidad que
      // hay, y tirarla perdería la relación entera.
      expect(isMeaningfulEntity(name: 'mi esposa', kind: 'person'), isTrue);
      expect(isMeaningfulEntity(name: 'esposa', kind: 'person'), isTrue);
    });

    test('un lugar con nombre', () {
      expect(
        isMeaningfulEntity(name: 'Cadereyta de Montes', kind: 'place'),
        isTrue,
      );
    });

    test('un evento con fecha', () {
      expect(
        isMeaningfulEntity(name: 'Boda del 26 de enero de 2019', kind: 'event'),
        isTrue,
      );
    });

    test('una condición de salud en minúscula', () {
      // Aquí la minúscula es lo normal y no significa vaguedad.
      expect(isMeaningfulEntity(name: 'diabetes', kind: 'condition'), isTrue);
      expect(
        isMeaningfulEntity(name: 'metformina', kind: 'medication'),
        isTrue,
      );
    });

    test('una empresa', () {
      expect(isMeaningfulEntity(name: 'Grupo REM', kind: 'org'), isTrue);
    });
  });
}
