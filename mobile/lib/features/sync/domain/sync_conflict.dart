// A revision that lost a merge, kept so the user can put it back.
//
// WHY THIS EXISTS AT ALL. The merge engine has one deviation from pure
// last-writer-wins: a delete beats a concurrent edit even when the edit has the
// higher clock. That rule is right — resurrecting something the user believed
// erased is a privacy failure — but it is only SAFE because the losing edit is
// preserved and visible. Without this list, "el borrado gana" would mean "el
// borrado destruye", and the two are very different promises.
//
// The same applies to ordinary conflicts: when two devices change the same
// thing, one version survives. The other is not wrong, it just arrived on the
// losing side of a rule. Showing it is the difference between a merge and a
// coin flip the user never sees.
library;

class SyncConflict {
  const SyncConflict({
    required this.uuid,
    required this.losingLamport,
    required this.losingOrigin,
    required this.losingLabel,
    required this.resolvedAt,
  });

  /// Which record this was a version of.
  final String uuid;

  final int losingLamport;

  /// Which device authored the version that lost. Null only for rows written
  /// before the clock started, which cannot conflict with anything.
  final String? losingOrigin;

  /// What the losing version said, as the user would recognise it.
  final String losingLabel;

  final DateTime resolvedAt;

  /// The name to show for the device that lost, given the user's device set.
  ///
  /// Falls back to "otro dispositivo" rather than printing a raw UUID: a
  /// 32-character hex string tells the user nothing, and a conflict list that
  /// cannot be read is a conflict list nobody opens.
  String deviceLabel(Map<String, String> nicknamesByUuid) =>
      nicknamesByUuid[losingOrigin] ?? 'otro dispositivo';
}
