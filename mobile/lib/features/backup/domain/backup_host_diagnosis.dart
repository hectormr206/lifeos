/// Why the backup host is or is not usable right now.
///
/// A single "backup failed" tells the user nothing they can act on. Setup has
/// four distinct ways to be wrong — off the VPN, wrong address, wrong key,
/// unusable store — and each has a different fix, so each gets its own state.
enum BackupHostState {
  /// Nothing entered yet. Not an error; the user simply has not set it up.
  notConfigured,

  /// Nothing answered. On a private address the overwhelmingly likely cause
  /// is that the phone is not on the VPN, so that is what we say first.
  unreachable,

  /// Something answered, but it is not a LifeOS backup host — a router page,
  /// another service, a captive portal. Reporting "connected" would be a lie.
  notABackupHost,

  /// The host is there and the address is right; the key is not.
  keyRejected,

  /// Reachable and authorised, but it cannot store anything: a read-only
  /// volume or a full disk. Surfacing this during setup is the whole point —
  /// the alternative is discovering it on the day a restore is needed.
  storeNotWritable,

  /// Everything works.
  ready,
}

class BackupHostDiagnosis {
  const BackupHostDiagnosis({
    required this.state,
    required this.message,
    this.freeBytes,
    this.backupCount,
  });

  final BackupHostState state;

  /// Shown to the user as-is. Says what is wrong AND what to do about it.
  final String message;
  final int? freeBytes;
  final int? backupCount;

  bool get isReady => state == BackupHostState.ready;
}

class BackupHostException implements Exception {
  const BackupHostException(this.state, this.message);

  final BackupHostState state;
  final String message;

  @override
  String toString() => 'BackupHostException($state): $message';
}
