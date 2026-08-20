// How people from different walks of life actually say things, and whether
// LifeOS files them in the right place.
//
// Asked for: "haz pruebas de todo esto para que veas si funciona con varios
// tipos de situaciones y pláticas, haciendo la función de cómo pueden hablar y
// expresarse varias personas diferentes de edad, sexo, rango social y demás
// cosas que influyan en la conversación".
//
// The router is where that lands. It decides which domain a sentence belongs
// to from its words alone, and it is deliberately conservative: null means
// "let ordinary chat handle it", never a wrong write. So this corpus checks
// two different things, and the second matters more:
//
//   * that plain, everyday phrasings DO route — a grandmother writing "me
//     duele la panza" and a doctor's kid writing "presenté dolor abdominal"
//     mean the same shelf;
//   * that nothing routes WRONG. A misfiled entry is worse than an unfiled
//     one: unfiled still shows up in the chat and in search, misfiled shows up
//     under a heading that makes it a lie.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/domain_router.dart';

/// (what was said, the domain it belongs to or null if it should not route)
typedef Turn = (String, String?);

const corpus = <String, List<Turn>>{
  'señora de 68, escribe sin acentos ni puntuacion': [
    ('me duele mucho la cabeza desde ayer', 'health'),
    ('fui a caminar al parque en la mañana', 'exercise'),
    ('le di la limosna en la iglesia', 'spirituality'),
  ],
  'obrero de 45, dictado por voz': [
    ('me pagaron la quincena y aparte el bono', 'finance'),
    ('ando con dolor de espalda de cargar', 'health'),
  ],
  'estudiante de 19, jerga y abreviaturas': [
    ('estuve estudiando calculo toda la noche', 'learning'),
    ('fui al gym e hice pierna', 'exercise'),
  ],
  'profesionista de 38, escribe correcto': [
    ('Pagué la hipoteca y me quedaron 12 mil de ahorro.', 'finance'),
    ('Tuve una sesión de meditación de veinte minutos.', 'spirituality'),
  ],
  'ama de casa de 52': [
    ('mi presion salio en 130 sobre 85', 'health'),
    ('gaste como mil pesos en el super', 'finance'),
  ],
  'joven de 24, mezcla español e inglés': [
    ('hoy hice running 5k', 'exercise'),
    ('estoy leyendo un libro de historia', 'learning'),
  ],
};

void main() {
  const router = DomainRouter();

  group('the same meaning routes the same, whoever says it', () {
    corpus.forEach((who, turns) {
      test(who, () {
        for (final (message, expected) in turns) {
          expect(router.routeDomain(message), expected,
              reason: '"$message" fue a ${router.routeDomain(message)}');
        }
      });
    });
  });

  group('nothing is filed under the wrong heading', () {
    // A misfiled entry is worse than an unfiled one: unfiled still shows up in
    // the chat and in search, misfiled shows up under a heading that makes it
    // a lie. So for these, ANY domain would be wrong — null is the right
    // answer.
    const shouldNotRoute = [
      'hola como estas',
      'ya me voy a dormir',
      'gracias por todo',
      'no se que hacer',
      'oye una pregunta',
    ];

    for (final message in shouldNotRoute) {
      test('"$message" no se archiva en ningún lado', () {
        expect(router.routeDomain(message), isNull,
            reason: 'se archivó en ${router.routeDomain(message)}');
      });
    }

    test('una frase que toca dos dominios no elige uno a la fuerza', () {
      // "Gasté en el gimnasio" is money AND exercise. Picking one silently is
      // how something ends up somewhere the user will never look for it.
      expect(router.routeDomain('pagué la mensualidad del gimnasio'), isNull);
    });
  });
}
