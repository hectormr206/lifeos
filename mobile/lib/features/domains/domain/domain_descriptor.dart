import 'package:flutter/material.dart';

/// Declarative config for one domain in the generic domain framework
/// (design D2: "a single generic data-table widget instantiated per domain
/// ... MUST NOT duplicate widget logic per domain"). All 7 domains (spec
/// `mobile-domain-crud`) are just entries in [domainDescriptors] below —
/// no per-domain widget/notifier/repository code, ever (proven by M2 slice
/// 2: relationships/spirituality/learning/calendar shipped as pure registry
/// additions, zero changes to `domain_repository.dart` or any widget).
class DomainDescriptor {
  const DomainDescriptor({
    required this.key,
    required this.title,
    required this.icon,
    required this.listPath,
    required this.listKey,
    this.routerHint = '',
    this.keywords = const <String>[],
  });

  /// Stable identifier, also used as the `/domains/:key` route segment.
  final String key;

  /// Spanish display title (neutral copy).
  final String title;

  final IconData icon;

  /// The engine's exact GET path for this domain's list — read directly
  /// from `axi/src/axi/dashboard.py`, not guessed.
  final String listPath;

  /// The JSON response wrapper key. Health/finance/spirituality/learning use
  /// `"entries"`; exercise uses `"sessions"` (dashboard.py:6518
  /// `api_ex_list`); calendar uses `"events"` (dashboard.py:6824
  /// `api_calendar_window`); relationships uses `"interactions"`
  /// (dashboard.py:6442 `api_rel_interactions_list`) — different nouns for
  /// the same list shape, which is why this is per-descriptor config rather
  /// than a hardcoded key in the repository (data-driven, not special-cased
  /// per domain).
  final String listKey;

  /// One-line ES description of what this domain captures, ported verbatim
  /// from each laptop domain spec's `router_hint` (`axi/src/axi/*_chat.py`).
  /// Used by the on-device heuristic domain router (SLICE A3) and, later, as
  /// the LLM classifier prompt line (C1 seam) — one source of truth, mirroring
  /// the laptop `chat_router._build_router_system`.
  final String routerHint;

  /// Accent-insensitive keyword stems the heuristic router matches against a
  /// message, DERIVED from [routerHint]. Stems are lowercased and unaccented;
  /// the router folds accents on both sides before a word-boundary match.
  final List<String> keywords;

  @override
  bool operator ==(Object other) => other is DomainDescriptor && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'DomainDescriptor($key)';
}

/// All 7 domains. Endpoints/wrapper keys verified by reading dashboard.py
/// directly, never guessed:
/// - health:        GET /api/v1/health/entries              (dashboard.py:6074 api_health_list) -> "entries"
/// - finance:       GET /api/v1/finance/entries              (dashboard.py:6218 api_finance_list) -> "entries"
/// - exercise:      GET /api/v1/exercise/sessions             (dashboard.py:6518 api_ex_list) -> "sessions"
/// - relationships: GET /api/v1/relationships/interactions    (dashboard.py:6442 api_rel_interactions_list) -> "interactions"
/// - spirituality:  GET /api/v1/spirituality/entries          (dashboard.py:6599 api_spirit_list) -> "entries"
/// - learning:      GET /api/v1/learning/entries              (dashboard.py:6672 api_learn_list) -> "entries"
/// - calendar:      GET /api/v1/calendar                      (dashboard.py:6824 api_calendar_window) -> "events"
///
/// NOTE on calendar: `/api/v1/events` (alias of dashboard.py:1844
/// `api_events`) was NOT used — that endpoint is the unrelated system
/// event-log feed (`level`/`source`/`since_ts` filters, `unread_critical`
/// count), not the LifeOS calendar/events domain. The real calendar domain
/// lives at `/calendar` / `/api/calendar` precisely to avoid that name
/// collision (see dashboard.py:6799-6803's own comment). `api_calendar_window`
/// (the combined recent-past + upcoming window) was chosen over
/// `/api/calendar/upcoming`/`/api/calendar/past` as the single "list" this
/// generic framework needs.
///
/// NOTE on relationships: this descriptor surfaces the INTERACTIONS timeline
/// (person_id, kind, title, body, mood_pre/post/delta, ts) — not the People
/// registry (GET /api/v1/relationships/people). Interaction rows do carry
/// their own required `title` (rendered as-is), but NOT a person name —
/// only `person_id`. Resolving person_id -> person name (and a dedicated
/// People list/detail view) is a documented follow-up, not implemented here.
const domainDescriptors = <DomainDescriptor>[
  DomainDescriptor(
    key: 'health',
    title: 'Salud',
    icon: Icons.favorite,
    listPath: '/api/v1/health/entries',
    listKey: 'entries',
    routerHint: 'salud física/médica: presión, glucosa, peso, pulso, sueño, '
        'síntomas, dolor, enfermedad, medicamentos, estudios médicos',
    // 'dormir' (infinitive) is NOT here on purpose: "ya me voy a dormir" is a
    // goodnight, and it was being filed as a health entry. The conjugated
    // forms are what a report looks like.
    keywords: <String>[
      'presion', 'glucosa', 'peso', 'pulso', 'sueno', 'dormi', 'dormido',
      'desvele', 'sintoma', 'sintomas', 'dolor', 'duele', 'dolia', 'malestar',
      'enfermedad', 'enfermo', 'enferma', 'gripa', 'fiebre', 'temperatura',
      'mareo', 'nausea', 'medicamento', 'medicina', 'pastilla', 'receta',
      // 'doctor' and 'consulta' are NOT here: "recuérdame llamar al doctor
      // mañana" is an appointment, not a health reading, and routing it to
      // Salud files a reminder as a medical record.
      'salud', 'azucar', 'frecuencia cardiaca',
    ],
  ),
  DomainDescriptor(
    key: 'finance',
    title: 'Finanzas',
    icon: Icons.attach_money,
    listPath: '/api/v1/finance/entries',
    listKey: 'entries',
    routerHint: 'dinero: gastos, ingresos, ahorros, pagos de deuda, sueldo, '
        'precios, compras, presupuesto, cuentas',
    keywords: <String>[
      'gasto', 'gaste', 'gastamos', 'ingreso', 'ahorro', 'ahorre', 'deuda',
      'sueldo', 'salario', 'quincena', 'aguinaldo', 'bono', 'precio',
      'compra', 'compre', 'presupuesto', 'cuenta', 'dinero', 'pago', 'pague',
      'cobre', 'cobraron', 'pagaron', 'gasolina', 'factura', 'renta',
      'hipoteca', 'prestamo', 'pesos',
    ],
  ),
  DomainDescriptor(
    key: 'exercise',
    title: 'Ejercicio',
    icon: Icons.fitness_center,
    listPath: '/api/v1/exercise/sessions',
    listKey: 'sessions',
    routerHint: 'actividad física: caminar, correr, cardio, pesas/fuerza, yoga, '
        'deportes, gimnasio, entrenar',
    keywords: <String>[
      'caminar', 'camine', 'caminata', 'correr', 'corri', 'cardio', 'pesas',
      'fuerza', 'yoga', 'deporte', 'gimnasio', 'gym', 'entrenar', 'entrene',
      'ejercicio', 'trote', 'running', 'bici', 'bicicleta', 'nade', 'natacion',
      'futbol', 'flexiones', 'sentadillas',
    ],
  ),
  DomainDescriptor(
    key: 'relationships',
    title: 'Relaciones',
    icon: Icons.people,
    listPath: '/api/v1/relationships/interactions',
    listKey: 'interactions',
    routerHint: 'relaciones con personas: llamadas, mensajes, encuentros, '
        'conflictos, con familia/amigos/pareja',
    keywords: <String>[
      'llamada', 'llame', 'mensaje', 'encuentro', 'conflicto', 'amigo',
      'amiga', 'familia', 'pareja', 'discuti', 'visite', 'reconcilie',
    ],
  ),
  DomainDescriptor(
    key: 'spirituality',
    title: 'Espiritualidad',
    icon: Icons.self_improvement,
    listPath: '/api/v1/spirituality/entries',
    listKey: 'entries',
    routerHint: 'vida interior: reflexión, gratitud, meditación, oración, '
        'mindfulness, valores, propósito, paz',
    keywords: <String>[
      'reflexion', 'gratitud', 'meditacion', 'medite', 'oracion', 'rece',
      'mindfulness', 'valores', 'proposito', 'paz', 'agradeci', 'espiritual',
      'iglesia', 'misa', 'templo', 'fe', 'limosna', 'diezmo', 'confesion',
      'retiro', 'biblia', 'comunion',
    ],
  ),
  DomainDescriptor(
    key: 'learning',
    title: 'Aprendizaje',
    icon: Icons.school,
    listPath: '/api/v1/learning/entries',
    listKey: 'entries',
    routerHint: 'conocimiento: libros, cursos, artículos, ideas, preguntas de '
        'investigación, notas de estudio, citas',
    keywords: <String>[
      'libro', 'curso', 'articulo', 'idea', 'aprendi', 'estudie', 'estudiando',
      'estudiar', 'estudio', 'lei', 'leyendo', 'repase', 'tarea', 'examen',
      'investigacion', 'apunte', 'leccion', 'aprendizaje', 'clase',
    ],
  ),
  DomainDescriptor(
    key: 'calendar',
    title: 'Calendario',
    icon: Icons.event,
    listPath: '/api/v1/calendar',
    listKey: 'events',
    routerHint: 'eventos y fechas: viajes, cumpleaños, aniversarios, fiestas, '
        'hitos, citas con fecha, deadlines',
    keywords: <String>[
      'viaje', 'cumpleanos', 'aniversario', 'fiesta', 'hito', 'deadline',
      'evento', 'cita', 'reunion', 'vuelo', 'vencimiento',
    ],
  ),
];

DomainDescriptor domainDescriptorFor(String key) =>
    domainDescriptors.firstWhere((d) => d.key == key, orElse: () => throw ArgumentError('unknown domain: $key'));
