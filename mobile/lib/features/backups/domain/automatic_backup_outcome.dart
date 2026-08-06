/// Every terminal state one firing of the automatic backup scheduler can end
/// in. Deliberately seven distinct values rather than a bool: per this repo's
/// fail-loudly rule, "it didn't run" is never one undifferentiated fact — the
/// user needs to know WHY (off VPN? disabled? waiting for Wi-Fi? uncertain?
/// no passphrase to seal with? or it ran and actually failed?), because each
/// has a different meaning and [skippedVpnUnknown]/[passphraseUnavailable]
/// demand loud surfacing (spec: "VPN state cannot be determined"; owner
/// decision on 3.9: a switch that reads "on" while nothing is being backed
/// up is the worst outcome this feature can produce).
enum AutomaticBackupOutcome {
  /// The backup ran and landed on the server.
  succeeded,

  /// Ordinary, expected wait — same status class as waiting for Wi-Fi. The
  /// VPN was checked and found down; nothing uncertain about it.
  skippedVpnDown,

  /// The VPN check itself could not conclude either way. NEVER treated as
  /// permission to run (rule: `unknown` must never be treated as `onVpn`).
  skippedVpnUnknown,

  /// The user turned automatic backups off (persists across restarts).
  skippedDisabled,

  /// On VPN, but not on Wi-Fi/unmetered — held per the app-wide heavy-
  /// transfer policy (`heavy_download_policy.dart`), same as any other
  /// automatic heavy download.
  waitingForWifi,

  /// The gate passed but the backup itself did not land — including the VPN
  /// dropping mid-upload, which surfaces the same way an ordinary upload
  /// failure does. Never presented as a partial success.
  failed,

  /// The VPN/Wi-Fi gate passed but no sealing passphrase could be read from
  /// secure storage — e.g. the OS keystore backend is unavailable (a Linux
  /// box with no Secret Service daemon running is the concrete case that
  /// drove this: `tools/install-linux.sh` warns about exactly this). Kept
  /// DISTINCT from [failed] (which means "we tried the upload and it did
  /// not land") and from [skippedVpnDown]/[skippedVpnUnknown] (which are
  /// about the VPN, not the archive's encryption) — the user needs to know
  /// specifically that the passphrase, not the network, is the problem.
  passphraseUnavailable,
}
