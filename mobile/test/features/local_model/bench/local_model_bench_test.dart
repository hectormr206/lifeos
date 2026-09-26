// El arnés `--bench`: el único instrumento que hay para medir el modelo en el
// escritorio.
//
// POR QUÉ IMPORTA. En el teléfono se puede medir por el chat (hay línea de
// métricas y se automatiza con adb). En la laptop no hay forma de automatizar
// la interfaz, así que sin este arnés no hay medición, y sin medición no hay
// decisión sobre si la decodificación especulativa conviene.
//
// Lo que se prueba aquí es todo lo que puede hacer mentir a la medida: que la
// configuración pedida por la línea de órdenes llegue al motor, que la línea
// impresa diga el backend REAL (el de las métricas) y no el pedido, y que el
// código de salida distinga «medí» de «no pude».
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/bench/local_model_bench.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';

import '../support/fake_local_llm_engine.dart';

void main() {
  late List<LocalModelConfig> configs;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    configs = [];
    out = StringBuffer();
    err = StringBuffer();
  });

  /// Corre el arnés con un motor falso, capturando la config con la que se
  /// construyó.
  Future<int> run(
    List<String> arguments, {
    FakeLocalLlmEngine? engine,
    Map<String, String> files = const {},
  }) {
    final fake = engine ?? FakeLocalLlmEngine(installed: true);
    return runLocalModelBench(
      arguments,
      engineFactory: (config) {
        configs.add(config);
        return fake;
      },
      out: out,
      err: err,
      readFile: (path) =>
          files[path] ?? (throw FormatException('no existe: $path')),
    );
  }

  List<String> benchLines() => out
      .toString()
      .split('\n')
      .where((line) => line.startsWith('bench '))
      .toList();

  Map<String, String> fields(String line) => {
        for (final pair in line.split(' ').skip(1))
          pair.split('=').first: pair.split('=').skip(1).join('='),
      };

  group('el conjunto de prompts', () {
    test('cubre las tres categorías donde el efecto difiere', () {
      // El README del modelo mide la ganancia POR TAREA: sube resumiendo y
      // baja escribiendo código. Un conjunto que no cubra ambas no puede
      // responder la pregunta.
      expect(benchPrompts.map((p) => p.id), containsAll(<String>['resumen', 'codigo', 'libre']));
      expect(benchPrompts.length, greaterThanOrEqualTo(3));
    });

    test('los identificadores son únicos y los textos no están vacíos', () {
      expect(benchPrompts.map((p) => p.id).toSet().length, benchPrompts.length);
      for (final prompt in benchPrompts) {
        expect(prompt.text.trim(), isNotEmpty, reason: prompt.id);
      }
    });
  });

  group('la configuración pedida llega al motor', () {
    test('sin argumentos: backend automático y especulativa automática', () async {
      expect(await run(const ['--bench']), 0);

      expect(configs.single.backend, const LocalModelConfig().backend);
      expect(configs.single.speculativeDecoding, isNull);
    });

    test('--bench-backend=cpu fuerza la CPU', () async {
      await run(const ['--bench', '--bench-backend=cpu']);
      expect(configs.single.backend, LocalLlmBackend.cpu);
    });

    test('--bench-speculative=on y =off son distintos de =auto', () async {
      await run(const ['--bench', '--bench-speculative=on']);
      expect(configs.single.speculativeDecoding, isTrue);

      configs.clear();
      await run(const ['--bench', '--bench-speculative=off']);
      expect(configs.single.speculativeDecoding, isFalse);

      configs.clear();
      await run(const ['--bench', '--bench-speculative=auto']);
      expect(configs.single.speculativeDecoding, isNull);
    });

    test('--bench-max-output-tokens acota la salida', () async {
      await run(const ['--bench', '--bench-max-output-tokens=64']);
      expect(configs.single.maxOutputTokens, 64);
    });

    test('la salida viene acotada de fábrica', () async {
      // Sin tope la medición tarda lo que el modelo quiera y nadie la repite.
      await run(const ['--bench']);
      expect(
        configs.single.maxOutputTokens,
        lessThan(const LocalModelConfig().maxOutputTokens),
      );
    });
  });

  group('lo que imprime', () {
    test('una línea por generación, con todos los campos', () async {
      final engine = FakeLocalLlmEngine(
        installed: true,
        metrics: const GenerationMetrics(
          totalMs: 4000,
          tokensOut: 120,
          backend: LocalLlmBackend.cpu,
          modelId: 'gemma-4-E2B-it.litertlm',
          ttftMs: 800,
          decodeTokensPerSec: 37.5,
        ),
      );
      expect(await run(const ['--bench', '--bench-speculative=on'], engine: engine), 0);

      final lines = benchLines();
      expect(lines.length, benchPrompts.length);

      final first = fields(lines.first);
      expect(first['prompt'], benchPrompts.first.id);
      expect(first['speculative'], 'on');
      expect(first['tokens'], '120');
      expect(first['total_ms'], '4000');
      expect(first['ttft_ms'], '800');
      expect(first['tok_s'], '37.5');
      expect(first['model'], 'gemma-4-E2B-it.litertlm');
    });

    test('dice el backend REAL, no el que se pidió', () async {
      // Si el runtime cae a CPU por su cuenta, una línea que repita «gpu»
      // porque es lo que se pidió convierte el benchmark en una mentira.
      final engine = FakeLocalLlmEngine(
        installed: true,
        metrics: const GenerationMetrics(
          totalMs: 1000,
          tokensOut: 10,
          backend: LocalLlmBackend.cpu,
          modelId: 'gemma-4-E2B-it.litertlm',
        ),
      );
      await run(const ['--bench', '--bench-backend=gpu'], engine: engine);

      for (final line in benchLines()) {
        expect(fields(line)['backend'], 'cpu');
      }
    });

    test('un TTFT ausente no se inventa', () async {
      final engine = FakeLocalLlmEngine(
        installed: true,
        metrics: const GenerationMetrics(
          totalMs: 1000,
          tokensOut: 10,
          backend: LocalLlmBackend.cpu,
          modelId: 'gemma-4-E2B-it.litertlm',
        ),
      );
      await run(const ['--bench'], engine: engine);
      expect(fields(benchLines().first)['ttft_ms'], 'na');
    });

    test('--bench-repeat mide cada prompt varias veces', () async {
      await run(const ['--bench', '--bench-repeat=3']);
      expect(benchLines().length, benchPrompts.length * 3);
      expect(fields(benchLines().last)['round'], '3');
    });
  });

  group('códigos de salida', () {
    test('0 cuando midió', () async {
      expect(await run(const ['--bench']), 0);
    });

    test('distinto de 0 y lo dice por stderr cuando el modelo no está', () async {
      final code = await run(
        const ['--bench'],
        engine: FakeLocalLlmEngine(installed: false),
      );
      expect(code, isNot(0));
      expect(err.toString(), isNotEmpty);
      expect(benchLines(), isEmpty);
    });

    test('distinto de 0 y lo dice por stderr cuando la carga falla', () async {
      final engine = FakeLocalLlmEngine(installed: true)..loadShouldFail = true;
      final code = await run(const ['--bench'], engine: engine);
      expect(code, isNot(0));
      expect(err.toString(), isNotEmpty);
    });

    test('distinto de 0 cuando una generación falla', () async {
      final engine = FakeLocalLlmEngine(installed: true, generateShouldFail: true);
      final code = await run(const ['--bench'], engine: engine);
      expect(code, isNot(0));
      expect(err.toString(), isNotEmpty);
    });

    test('un argumento inválido no se traga: sale con error y explica el uso',
        () async {
      final code = await run(const ['--bench', '--bench-speculative=quizá']);
      expect(code, isNot(0));
      expect(err.toString(), contains('--bench-speculative'));
      expect(configs, isEmpty, reason: 'no se carga un modelo para nada');
    });

    test('un backend inválido tampoco', () async {
      expect(await run(const ['--bench', '--bench-backend=tpu']), isNot(0));
      expect(configs, isEmpty);
    });

    test('un tope de tokens que no es un número positivo tampoco', () async {
      expect(await run(const ['--bench', '--bench-max-output-tokens=0']), isNot(0));
      expect(await run(const ['--bench', '--bench-max-output-tokens=x']), isNot(0));
      expect(configs, isEmpty);
    });
  });

  test('suelta el modelo al terminar', () async {
    final engine = FakeLocalLlmEngine(installed: true);
    await run(const ['--bench'], engine: engine);
    expect(engine.disposeCount, greaterThanOrEqualTo(1));
  });

  test('suelta el modelo incluso cuando una generación falla', () async {
    final engine = FakeLocalLlmEngine(installed: true, generateShouldFail: true);
    await run(const ['--bench'], engine: engine);
    expect(engine.disposeCount, greaterThanOrEqualTo(1));
  });

  group('prompts propios, para medir la CALIDAD de un prompt y no sólo la velocidad', () {
    // Un prompt nuevo (la glosa en contexto, la revisión del inglés) hay que
    // verlo contra el modelo de verdad: una prueba con motor falso sólo dice
    // que el analizador entiende la respuesta que uno imagina.
    const file = '[{"id": "glosa", "text": "¿Qué significa bank?", '
        '"temperature": 0.2}, {"id": "libre", "text": "Hola"}]';

    test('lee los prompts del archivo en vez de los fijos', () async {
      final engine = FakeLocalLlmEngine(installed: true);

      expect(
        await run(const ['--bench', '--bench-prompts=/p.json'],
            engine: engine, files: const {'/p.json': file}),
        0,
      );

      expect(engine.prompts, ['¿Qué significa bank?', 'Hola']);
      expect(benchLines().map((l) => fields(l)['prompt']), ['glosa', 'libre']);
    });

    test('la temperatura de cada prompt llega al motor', () async {
      final engine = FakeLocalLlmEngine(installed: true);

      await run(const ['--bench', '--bench-prompts=/p.json'],
          engine: engine, files: const {'/p.json': file});

      expect(engine.generateSampling.first.$1, 0.2);
      expect(engine.generateSampling.last.$1, isNull);
    });

    test('--bench-show-text=on imprime lo que respondió el modelo', () async {
      final engine = FakeLocalLlmEngine(installed: true, reply: (p) => 'R:$p');

      await run(const ['--bench', '--bench-prompts=/p.json', '--bench-show-text=on'],
          engine: engine, files: const {'/p.json': file});

      expect(out.toString(), contains('R:Hola'));
    });

    test('sin --bench-show-text la salida sigue siendo sólo de métricas', () async {
      final engine = FakeLocalLlmEngine(installed: true, reply: (p) => 'R:$p');

      await run(const ['--bench', '--bench-prompts=/p.json'],
          engine: engine, files: const {'/p.json': file});

      expect(out.toString(), isNot(contains('R:Hola')));
    });

    test('un archivo que no se entiende PARA antes de cargar nada', () async {
      final engine = FakeLocalLlmEngine(installed: true);

      final code = await run(const ['--bench', '--bench-prompts=/p.json'],
          engine: engine, files: const {'/p.json': '{"no": "una lista"}'});

      expect(code, benchUsageExitCode);
      expect(engine.prompts, isEmpty);
    });
  });
}
