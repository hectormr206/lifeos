import 'package:flutter/material.dart';

/// Declarative config for one domain in the generic domain framework
/// (design D2: "a single generic data-table widget instantiated per domain
/// ... MUST NOT duplicate widget logic per domain"). Adding a 4th-7th domain
/// (relationships, spirituality, learning, calendar — spec
/// `mobile-domain-crud`) means adding one more entry to [domainDescriptors]
/// below, never new widget/notifier/repository code.
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

  /// The JSON response wrapper key. Health and finance use `"entries"`;
  /// exercise uses `"sessions"` (dashboard.py:6518 `api_ex_list` — a
  /// different noun for the same list shape), which is why this is
  /// per-descriptor config rather than a hardcoded key in the repository.
  final String listKey;

  @override
  bool operator ==(Object other) => other is DomainDescriptor && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'DomainDescriptor($key)';
}

/// The 3 core domains shipped in M2 slice 1 (spec `mobile-domain-crud`).
/// Endpoints verified by reading dashboard.py directly:
/// - health:   GET /api/v1/health/entries    (dashboard.py:6074 api_health_list)
/// - finance:  GET /api/v1/finance/entries   (dashboard.py:6218 api_finance_list)
/// - exercise: GET /api/v1/exercise/sessions (dashboard.py:6518 api_ex_list)
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
];

DomainDescriptor domainDescriptorFor(String key) =>
    domainDescriptors.firstWhere((d) => d.key == key, orElse: () => throw ArgumentError('unknown domain: $key'));
