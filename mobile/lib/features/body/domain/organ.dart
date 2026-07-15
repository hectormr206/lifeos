/// One row from `GET /api/v1/organs` (design D2-style read-only feature;
/// spec-adjacent "visible soul" slice — Axi's body). Shape read directly
/// from `axi/src/axi/organs.py` (`all_organs()`, :297): each organ is
/// `{key, name, state, detail, description}`. `state` is one of
/// `organs.STATES` (:38): `ok | degraded | down | off | unknown | planned`.
class OrganState {
  const OrganState({
    required this.key,
    required this.name,
    required this.state,
    required this.detail,
    required this.description,
  });

  /// Stable identifier (e.g. "heart", "lungs", "brain").
  final String key;

  /// Spanish display name (e.g. "corazón", "pulmones", "cerebro") — already
  /// localized server-side, rendered as-is.
  final String name;

  /// One of: ok | degraded | down | off | unknown | planned.
  final String state;

  /// Short human-readable status line (Spanish, server-composed).
  final String detail;

  /// Longer Spanish description of what this organ does — shown on expand.
  final String description;

  @override
  bool operator ==(Object other) =>
      other is OrganState &&
      other.key == key &&
      other.state == state &&
      other.detail == detail &&
      other.description == description;

  @override
  int get hashCode => Object.hash(key, state, detail, description);

  @override
  String toString() => 'OrganState(key: $key, state: $state)';
}
