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
  ),
  DomainDescriptor(
    key: 'finance',
    title: 'Finanzas',
    icon: Icons.attach_money,
    listPath: '/api/v1/finance/entries',
    listKey: 'entries',
  ),
  DomainDescriptor(
    key: 'exercise',
    title: 'Ejercicio',
    icon: Icons.fitness_center,
    listPath: '/api/v1/exercise/sessions',
    listKey: 'sessions',
  ),
  DomainDescriptor(
    key: 'relationships',
    title: 'Relaciones',
    icon: Icons.people,
    listPath: '/api/v1/relationships/interactions',
    listKey: 'interactions',
  ),
  DomainDescriptor(
    key: 'spirituality',
    title: 'Espiritualidad',
    icon: Icons.self_improvement,
    listPath: '/api/v1/spirituality/entries',
    listKey: 'entries',
  ),
  DomainDescriptor(
    key: 'learning',
    title: 'Aprendizaje',
    icon: Icons.school,
    listPath: '/api/v1/learning/entries',
    listKey: 'entries',
  ),
  DomainDescriptor(
    key: 'calendar',
    title: 'Calendario',
    icon: Icons.event,
    listPath: '/api/v1/calendar',
    listKey: 'events',
  ),
];

DomainDescriptor domainDescriptorFor(String key) =>
    domainDescriptors.firstWhere((d) => d.key == key, orElse: () => throw ArgumentError('unknown domain: $key'));
