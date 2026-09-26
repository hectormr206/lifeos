/// Arnés de medición SIN INTERFAZ para el modelo local: carga el modelo, corre
/// un conjunto fijo de prompts, imprime una línea por generación y sale.
///
/// ─── POR QUÉ EXISTE ───────────────────────────────────────────────────────
///
/// En el teléfono se puede medir por el chat: hay línea de métricas bajo cada
/// burbuja y se automatiza con `adb`. En el ordenador NO hay forma de
/// automatizar la interfaz, así que sin un instrumento no hay medición, y sin
/// medición no hay decisión — sobre la decodificación especulativa o sobre
/// ninguna otra cosa. Esto es ese instrumento.
///
/// ─── QUÉ NO TOCA ──────────────────────────────────────────────────────────
///
/// Nada del usuario. No abre el grafo, no lee ni escribe preferencias, no
/// genera boletines y no registra trabajos en segundo plano. Construye el motor
/// a mano — como hace `executeMorningBriefingBackgroundTask()` con su grafo
/// mínimo — precisamente para no arrastrar el `ProviderScope`, que sí leería
/// las preferencias del usuario y le cambiaría la configuración bajo los pies.
/// Al terminar suelta el modelo.
///
/// ─── USO ──────────────────────────────────────────────────────────────────
///
/// ```
/// lifeos --bench [--bench-backend=auto|cpu|gpu|npu]
///                [--bench-speculative=auto|on|off]
///                [--bench-max-output-tokens=N]
///                [--bench-repeat=N]
///                [--bench-prompts=prompts.json]
///                [--bench-show-text=on|off]
/// ```
///
/// `--bench-prompts` cambia los tres prompts fijos por los de un archivo JSON,
/// una lista de `{"id": "...", "text": "...", "temperature": 0.2}` (la
/// temperatura es opcional). Con `--bench-show-text=on` se imprime además lo
/// que respondió el modelo. Sirve para medir la CALIDAD de un prompt nuevo
/// contra el modelo de verdad, no sólo su velocidad.
///
/// Ejemplos (desde el directorio de la instalación en Linux):
/// ```sh
/// # Línea base: lo que hace la aplicación hoy en este aparato.
/// ./lifeos --bench
///
/// # El A/B que responde «¿viene encendida de fábrica?»:
/// ./lifeos --bench --bench-speculative=auto --bench-repeat=3 > auto.txt
/// ./lifeos --bench --bench-speculative=off  --bench-repeat=3 > off.txt
/// ./lifeos --bench --bench-speculative=on   --bench-repeat=3 > on.txt
/// # Si `auto` y `off` miden igual y `on` mide distinto, venía APAGADA;
/// # si `auto` y `on` miden igual, venía ENCENDIDA.
///
/// # Forzando también el backend (en el ordenador el automático ya es CPU):
/// ./lifeos --bench --bench-backend=cpu --bench-speculative=on
/// ```
///
/// CADA INVOCACIÓN ES UN PROCESO NUEVO, y tiene que serlo: la decodificación
/// especulativa se fija al CREAR el motor nativo
/// (`litert_lm_engine_settings_set_enable_speculative_decoding`), no en cada
/// generación. Por eso el A/B no se puede hacer dentro de una sola ejecución
/// sin recargar el modelo, y por eso aquí cada corrida carga una vez con una
/// sola configuración.
///
/// ─── QUÉ IMPRIME ──────────────────────────────────────────────────────────
///
/// Por `stdout`, una línea por generación, en `clave=valor` separado por
/// espacios para que `awk`/`cut` lo lean sin ceremonia:
///
/// ```
/// bench prompt=resumen round=1 backend=cpu speculative=auto model=gemma-4-E2B-it.litertlm tokens=118 total_ms=4210 ttft_ms=812 tok_s=34.7 approx=false
/// ```
///
/// `backend` es el REAL (el que el runtime acabó usando, vía
/// `model.activeBackend` → `GenerationMetrics.backend`), no el que se pidió: un
/// runtime puede caer a CPU por su cuenta y repetir «gpu» porque es lo que se
/// pidió convertiría el benchmark en una mentira. `ttft_ms=na` cuando el
/// runtime no reportó tiempo hasta el primer token — nunca se inventa.
///
/// ─── CÓDIGOS DE SALIDA ────────────────────────────────────────────────────
///
/// `0` midió; `2` el modelo no está instalado; `3` la carga falló; `4` alguna
/// generación falló; `64` los argumentos no se entienden. Todo lo que no es
/// una medición se explica por `stderr`.
library;

import 'dart:convert';
import 'dart:io';

import '../data/flutter_gemma_llm_engine.dart';
import '../domain/local_llm_engine.dart';

/// Código de salida cuando el modelo no está instalado en este aparato.
const int benchModelMissingExitCode = 2;

/// Código de salida cuando la carga del modelo falló.
const int benchLoadFailedExitCode = 3;

/// Código de salida cuando alguna generación falló.
const int benchGenerationFailedExitCode = 4;

/// Código de salida cuando los argumentos no se entienden (`EX_USAGE`).
const int benchUsageExitCode = 64;

/// Texto de ayuda que acompaña a cualquier salida por argumentos inválidos.
const String benchUsage = '''
uso: lifeos --bench [--bench-backend=auto|cpu|gpu|npu]
                    [--bench-speculative=auto|on|off]
                    [--bench-max-output-tokens=N]
                    [--bench-repeat=N]
                    [--bench-prompts=prompts.json]
                    [--bench-show-text=on|off]''';

/// Un prompt del conjunto fijo, con el identificador que aparece en la salida.
class BenchPrompt {
  const BenchPrompt(this.id, this.text, {this.temperature});

  /// Identificador estable: es la columna por la que se agrupa al comparar dos
  /// corridas, así que NO cambia aunque se retoque el texto.
  final String id;

  /// El texto que se le manda al modelo.
  final String text;

  /// La temperatura de esta generación, o `null` para la afinada del modelo.
  final double? temperature;
}

/// Los prompts de un archivo `--bench-prompts`: una lista JSON de objetos con
/// `id` y `text`, y `temperature` opcional. Lanza [FormatException] si no es
/// eso, para que un archivo mal escrito PARE en vez de medir otra cosa.
List<BenchPrompt> parseBenchPrompts(String source) {
  final json = jsonDecode(source);
  if (json is! List || json.isEmpty) {
    throw const FormatException('--bench-prompts espera una lista no vacía');
  }
  return [
    for (final item in json)
      if (item is Map && item['id'] is String && item['text'] is String)
        BenchPrompt(
          item['id'] as String,
          item['text'] as String,
          temperature: (item['temperature'] as num?)?.toDouble(),
        )
      else
        throw FormatException('--bench-prompts: elemento sin id o text: $item'),
  ];
}

/// El conjunto FIJO de prompts, escrito aquí y no en un fichero, para que dos
/// corridas en dos aparatos (o en dos versiones) midan exactamente lo mismo.
///
/// Cubre las tres categorías donde el fabricante dice que el efecto de la
/// decodificación especulativa DIFIERE — su tabla sube resumiendo texto y baja
/// escribiendo código — porque un conjunto que no cubriera ambas no podría
/// responder la pregunta, sólo promediarla hasta que no significara nada.
const List<BenchPrompt> benchPrompts = [
  BenchPrompt(
    'resumen',
    'Resume en tres frases el siguiente texto, sin añadir nada que no esté '
        'en él:\n\n'
        'El ferrocarril transformó la vida de los pueblos por los que pasaba '
        'mucho antes de que nadie midiera su efecto. Donde antes el correo '
        'tardaba cuatro días, empezó a llegar el mismo día; los mercados '
        'locales dejaron de fijar sus precios solos y pasaron a mirar los de '
        'la capital. Los oficios que vivían del transporte lento —arrieros, '
        'posaderos, herradores de camino— desaparecieron en menos de una '
        'generación, mientras aparecían otros que nadie había nombrado antes: '
        'jefes de estación, telegrafistas, guardabarreras. Los ayuntamientos '
        'que consiguieron una parada crecieron; los que la perdieron por unos '
        'kilómetros quedaron congelados durante un siglo. Y casi nadie de los '
        'que lo vivieron lo contó como un cambio: lo contaron como el tiempo '
        'que hacía y como el precio del trigo.',
  ),
  BenchPrompt(
    'codigo',
    'Escribe una función en Dart llamada `mediana` que reciba una '
        '`List<double>` y devuelva su mediana. Tiene que ordenar una copia (no '
        'mutar la lista que recibe), promediar los dos centrales cuando la '
        'longitud es par, y lanzar `ArgumentError` si la lista está vacía. '
        'Devuelve sólo el código, con un comentario breve encima.',
  ),
  BenchPrompt(
    'libre',
    'Explícale a alguien que no es programador por qué un programa puede ir '
        'muy rápido con datos pequeños y volverse lentísimo con datos grandes. '
        'Usa una comparación de la vida diaria y no más de un párrafo.',
  ),
];

/// Cómo construir el motor con la configuración pedida. Producción es
/// [FlutterGemmaLlmEngine]; es una costura para poder probar el arnés en el
/// anfitrión, donde no hay canal del plugin ni pesos de 2,6 GB.
typedef BenchEngineFactory = LocalLlmEngine Function(LocalModelConfig config);

/// Lo que la línea de órdenes le pidió a la medición.
class BenchOptions {
  const BenchOptions({
    this.backend,
    this.speculativeDecoding,
    this.maxOutputTokens = defaultMaxOutputTokens,
    this.repeat = 1,
    this.promptsFile,
    this.showText = false,
  });

  /// Tope de tokens generados por respuesta. MUY POR DEBAJO del de la
  /// aplicación (512): una medición que tarda lo que el modelo quiera es una
  /// medición que nadie repite, y la velocidad de decode se estabiliza mucho
  /// antes de eso.
  static const int defaultMaxOutputTokens = 128;

  /// El backend forzado, o `null` para el automático de la plataforma.
  final LocalLlmBackend? backend;

  /// La especulativa forzada, o `null` para lo que traiga el modelo.
  final bool? speculativeDecoding;

  final int maxOutputTokens;

  /// Cuántas vueltas se le da al conjunto entero. Más de una da idea de la
  /// dispersión, que es lo que dice si una diferencia es real o es ruido.
  final int repeat;

  /// Archivo de prompts propios, o `null` para los fijos.
  final String? promptsFile;

  /// Si se imprime también el texto generado.
  final bool showText;

  /// Cómo se escribe [speculativeDecoding] en la salida: `auto`, `on` u `off`.
  String get speculativeLabel => switch (speculativeDecoding) {
        null => 'auto',
        true => 'on',
        false => 'off',
      };

  /// Lee los `--bench-*` de [arguments]. Lanza [FormatException] con un mensaje
  /// legible cuando algo no se entiende: un valor mal escrito tiene que PARAR
  /// la medición, no correrla con otra configuración y dejar un número que
  /// parece bueno y no lo es.
  factory BenchOptions.parse(List<String> arguments) {
    LocalLlmBackend? backend;
    bool? speculative;
    var maxOutputTokens = defaultMaxOutputTokens;
    var repeat = 1;
    String? promptsFile;
    var showText = false;

    for (final argument in arguments) {
      final separator = argument.indexOf('=');
      if (!argument.startsWith('--bench-') || separator < 0) continue;
      final name = argument.substring(0, separator);
      final value = argument.substring(separator + 1);
      switch (name) {
        case '--bench-backend':
          backend = _parseBackend(value);
        case '--bench-speculative':
          speculative = _parseSpeculative(value);
        case '--bench-max-output-tokens':
          maxOutputTokens = _parsePositive(name, value);
        case '--bench-repeat':
          repeat = _parsePositive(name, value);
        case '--bench-prompts':
          promptsFile = value;
        case '--bench-show-text':
          showText = _parseOnOff(name, value);
        default:
          throw FormatException('opción desconocida: $name');
      }
    }

    return BenchOptions(
      backend: backend,
      speculativeDecoding: speculative,
      maxOutputTokens: maxOutputTokens,
      repeat: repeat,
      promptsFile: promptsFile,
      showText: showText,
    );
  }

  static bool _parseOnOff(String name, String value) => switch (value) {
        'on' => true,
        'off' => false,
        _ => throw FormatException('$name sólo acepta on u off (recibido: $value)'),
      };

  static LocalLlmBackend? _parseBackend(String value) {
    if (value == 'auto') return null;
    for (final backend in LocalLlmBackend.values) {
      if (backend.name == value) return backend;
    }
    throw FormatException(
      '--bench-backend sólo acepta auto, ${LocalLlmBackend.values.map((b) => b.name).join(', ')} '
      '(recibido: $value)',
    );
  }

  static bool? _parseSpeculative(String value) => switch (value) {
        'auto' => null,
        'on' => true,
        'off' => false,
        _ => throw FormatException(
            '--bench-speculative sólo acepta auto, on u off (recibido: $value)'),
      };

  static int _parsePositive(String name, String value) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed <= 0) {
      throw FormatException('$name espera un entero positivo (recibido: $value)');
    }
    return parsed;
  }
}

/// Corre la medición y devuelve el código de salida.
///
/// [engineFactory], [out] y [err] son costuras de prueba; en producción son el
/// motor real, `stdout` y `stderr`.
Future<int> runLocalModelBench(
  List<String> arguments, {
  BenchEngineFactory? engineFactory,
  StringSink? out,
  StringSink? err,
  String Function(String path)? readFile,
}) async {
  final output = out ?? stdout;
  final errors = err ?? stderr;

  final BenchOptions options;
  final List<BenchPrompt> prompts;
  try {
    options = BenchOptions.parse(arguments);
    final file = options.promptsFile;
    prompts = file == null
        ? benchPrompts
        : parseBenchPrompts(
            (readFile ?? (path) => File(path).readAsStringSync())(file));
  } on FormatException catch (error) {
    errors.writeln('lifeos --bench: ${error.message}');
    errors.writeln(benchUsage);
    return benchUsageExitCode;
  }

  final config = LocalModelConfig(
    backend: options.backend,
    speculativeDecoding: options.speculativeDecoding,
    maxOutputTokens: options.maxOutputTokens,
  );
  final engine = (engineFactory ?? _productionEngine)(config);

  try {
    final bool installed;
    try {
      installed = await engine.isModelInstalled();
    } catch (error) {
      errors.writeln('lifeos --bench: no se pudo comprobar el modelo: $error');
      return benchModelMissingExitCode;
    }
    if (!installed) {
      errors.writeln(
        'lifeos --bench: el modelo local no está instalado en este aparato; '
        'no hay nada que medir.',
      );
      return benchModelMissingExitCode;
    }

    try {
      await engine.load();
    } catch (error) {
      errors.writeln('lifeos --bench: falló la carga del modelo: $error');
      return benchLoadFailedExitCode;
    }

    var failures = 0;
    for (var round = 1; round <= options.repeat; round++) {
      for (final prompt in prompts) {
        try {
          final result = await engine.generate(
            prompt.text,
            temperature: prompt.temperature,
          );
          output.writeln(_line(prompt, round, options, result.metrics));
          if (options.showText) {
            output
              ..writeln('--- ${prompt.id}')
              ..writeln(result.text)
              ..writeln('---');
          }
        } catch (error) {
          failures++;
          errors.writeln(
            'lifeos --bench: falló la generación prompt=${prompt.id} '
            'round=$round: $error',
          );
        }
      }
    }
    return failures == 0 ? 0 : benchGenerationFailedExitCode;
  } finally {
    // Soltar el modelo pase lo que pase: este proceso muere a continuación,
    // pero un fallo al liberar no puede tapar el resultado de la medición.
    try {
      await engine.dispose();
    } catch (_) {
      // Mejor esfuerzo.
    }
  }
}

/// La línea `clave=valor` de una generación.
///
/// `backend` sale de las MÉTRICAS, que es donde vive el backend real
/// (`model.activeBackend`), no de lo que se pidió. `speculative` sí es lo
/// pedido: es la variable del experimento, y el runtime no reporta si acabó
/// usándola.
String _line(
  BenchPrompt prompt,
  int round,
  BenchOptions options,
  GenerationMetrics metrics,
) =>
    'bench '
    'prompt=${prompt.id} '
    'round=$round '
    'backend=${metrics.backend.name} '
    'speculative=${options.speculativeLabel} '
    'model=${metrics.modelId} '
    'tokens=${metrics.tokensOut} '
    'total_ms=${metrics.totalMs} '
    'ttft_ms=${metrics.ttftMs ?? 'na'} '
    'tok_s=${metrics.tokensPerSec.toStringAsFixed(1)} '
    'approx=${metrics.tokensApproximate}';

/// El motor de producción: el de verdad, desnudo.
///
/// Sin `SerialLlmEngine` ni `IdleUnloadLlmEngine`: aquí no hay concurrencia que
/// serializar (las generaciones van una detrás de otra) y no hay sesión larga
/// de la que recuperar memoria — el proceso muere al acabar. Menos capas entre
/// el cronómetro y el runtime es menos ruido en la medida.
LocalLlmEngine _productionEngine(LocalModelConfig config) =>
    FlutterGemmaLlmEngine(config);
