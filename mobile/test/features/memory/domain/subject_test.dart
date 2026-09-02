import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/subject.dart';

/// SLICE A3 — family-subject detection (ported from _common/subject.py).
void main() {
  group('detectSubject', () {
    test('leading marker with verb keeps + strips the verb', () {
      final m = detectSubject('Mi esposa tuvo 121, 79, 61 pulsos');
      expect(m, isNotNull);
      expect(m!.subject, 'esposa');
      expect(m.remainder, 'tuvo 121, 79, 61 pulsos');
      expect(m.remainderNoVerb, '121, 79, 61 pulsos');
    });

    test('trailing marker strips the "de mi X" tail', () {
      final m = detectSubject('108, 72, 66 pulsos de mi esposa');
      expect(m!.subject, 'esposa');
      expect(m.remainder, '108, 72, 66 pulsos');
      expect(m.remainderNoVerb, isNull);
    });

    test('EN synonym collapses to canonical ES label', () {
      final m = detectSubject('My wife slept 7 hours');
      expect(m!.subject, 'esposa');
      expect(m.remainder, 'slept 7 hours');
    });

    test('accent-free dictation still matches ("mi mama")', () {
      final m = detectSubject('mi mama durmió mal');
      expect(m!.subject, 'mamá');
    });

    test('unmarked text -> null (belongs to the user)', () {
      expect(detectSubject('presión 120/80'), isNull);
      expect(detectSubject('mi presión estaba alta'), isNull);
      expect(detectSubject(''), isNull);
    });
  });

  group('detectQuerySubject', () {
    test('possessive family marker anywhere returns the label', () {
      expect(detectQuerySubject('la presión de mi esposa ayer'), 'esposa');
      expect(detectQuerySubject('how did my mom sleep'), 'mamá');
    });

    test('self query -> null', () {
      expect(detectQuerySubject('mi presión'), isNull);
      expect(detectQuerySubject('resumen de salud'), isNull);
    });
  });

  group('subjectPossessive', () {
    test('ES and EN phrasing', () {
      expect(subjectPossessive('esposa'), 'tu esposa');
      expect(subjectPossessive('esposa', en: true), 'your wife');
    });
  });

  group('speaksInFirstPerson', () {
    // El portero que separa "esto lo dijo el usuario de sí mismo" de "esto se
    // apoya en la persona de la que estamos hablando". MEDIDO: sin él, con
    // "Tere" activa, `gaste 200 pesos en gasolina` y `me duele la cabeza` se
    // archivaban con label=Tere.
    test('pronombres y posesivos de primera persona', () {
      expect(speaksInFirstPerson('yo dormí 7 horas'), isTrue);
      expect(speaksInFirstPerson('vino conmigo'), isTrue);
      expect(speaksInFirstPerson('mi presión 120/80'), isTrue);
      expect(speaksInFirstPerson('mis hijos ya cenaron'), isTrue);
    });

    test('la CONJUGACIÓN basta, con acento o sin él', () {
      expect(speaksInFirstPerson('gasté 200 pesos en gasolina'), isTrue);
      expect(speaksInFirstPerson('gaste 200 pesos en gasolina'), isTrue);
      expect(speaksInFirstPerson('corrí 5 km'), isTrue);
      expect(speaksInFirstPerson('tengo cita con el dentista'), isTrue);
      expect(speaksInFirstPerson('estoy cansado'), isTrue);
    });

    test('"me" + verbo es del usuario; "le" es de la otra persona', () {
      expect(speaksInFirstPerson('me duele la cabeza'), isTrue);
      expect(speaksInFirstPerson('me tomé la presión'), isTrue);
      // Tercera persona: no es del usuario, y por eso sí se atribuye al hilo.
      expect(speaksInFirstPerson('le duele la cabeza'), isFalse);
      // "-o" es ambiguo y se deja fuera a propósito: "me dijo" es de la otra
      // persona.
      expect(speaksInFirstPerson('me dijo que tiene dos hijos'), isFalse);
    });

    test('las formas que se apoyan en el hilo NO son primera persona', () {
      expect(speaksInFirstPerson('tiene dos hijos'), isFalse);
      expect(speaksInFirstPerson('vive en Monterrey'), isFalse);
      expect(speaksInFirstPerson('se llama Mateo'), isFalse);
      expect(speaksInFirstPerson('trabaja en Bimbo'), isFalse);
      expect(speaksInFirstPerson('su esposa se llama Marta'), isFalse);
    });

    test('nombre/verbo ambiguos: solo delante de un número', () {
      // Así se registran de verdad.
      expect(speaksInFirstPerson('peso 80 kilos'), isTrue);
      // Y así NO: aquí "peso" y "pesos" son sustantivos.
      expect(speaksInFirstPerson('su peso es alto'), isFalse);
      expect(speaksInFirstPerson('le costó 200 pesos'), isFalse);
    });

    test('verbos de OPINIÓN quedan fuera a propósito', () {
      // La frase es del usuario pero el HECHO es de la otra persona, así que
      // tiene que seguir atribuyéndose al hilo.
      expect(speaksInFirstPerson('creo que tiene dos hijos'), isFalse);
      expect(speaksInFirstPerson('recuerdo que vive en Monterrey'), isFalse);
    });

    test('un marcador familiar no es un "mi" suelto', () {
      // "mi esposa" es una marca de SUJETO, no una de primera persona.
      expect(speaksInFirstPerson('mi esposa tuvo 121, 79'), isFalse);
    });

    test('texto vacío no afirma nada', () {
      expect(speaksInFirstPerson(''), isFalse);
      expect(speaksInFirstPerson(null), isFalse);
    });
  });
}
