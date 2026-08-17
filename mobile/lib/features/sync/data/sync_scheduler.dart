// When automatic sync is allowed to run, and when it is not.
//
// Follows the automatic-backup precedent exactly
// (`features/backups/data/workmanager_automatic_backup_work.dart`), because the
// rule and its reasoning are the same: a sync pass can move a megabyte of
// envelopes, and doing that on a metered connection spends the user's data on
// something they never asked for at that moment.
//
// THE CONSTRAINT IS THE ENFORCEMENT. `NetworkType.unmetered` is an OS
// guarantee: WorkManager holds the task until Wi-Fi is available, so off Wi-Fi
// the task does not fire at all rather than firing and deciding. A runtime
// "am I on Wi-Fi?" check inside the task would be a second, weaker copy of a
// rule the OS already enforces — and the two would eventually disagree.
//
// MANUAL SYNC IS DIFFERENT AND DELIBERATELY SO. A person who taps "sincronizar
// ahora" has decided. Refusing them because they are on cellular would be the
// app overruling an explicit instruction, which is the opposite of what a
// data-saving rule is for.
import 'package:lifeos/core/network/heavy_download_policy.dart';
import 'package:workmanager/workmanager.dart';

/// The network constraint automatic sync is registered under — and therefore
/// the only place the Wi-Fi-only rule is actually enforced.
///
/// Composed from [kHeavyDownloadsRequireWiFi] rather than hardcoded, so sync
/// follows the shared policy instead of restating it. Flip that one constant
/// and backups, model downloads and sync all move together.
const NetworkType automaticSyncNetworkType = kHeavyDownloadsRequireWiFi
    ? NetworkType.unmetered
    : NetworkType.connected;

/// Why a sync pass did or did not run. Returned rather than logged so the UI
/// can tell the user "esperando Wi-Fi" instead of showing nothing and letting
/// them wonder whether sync is broken.
enum SyncRunDecision {
  ran,
  waitingForWifi,
  syncDisabled,
}

/// Whether this trigger came from the user or from the scheduler.
///
/// Modelled as a type rather than a bool: `sync(manual: true)` at a call site
/// says nothing about which way round the rule goes, and this is a rule where
/// getting it backwards means either burning the user's data or ignoring their
/// explicit tap.
enum SyncTrigger {
  /// The user asked, right now. Always allowed.
  manual,

  /// The scheduler woke us. Wi-Fi only.
  automatic,
}

/// The decision, as a pure function so both branches are testable without
/// WorkManager, a network, or a device.
///
/// In production the `waitingForWifi` branch is unreachable for automatic runs
/// — WorkManager will not start a task whose [automaticSyncNetworkType]
/// constraint is unmet — which is exactly why it is worth stating here: if the
/// constraint is ever loosened, this keeps the rule instead of silently
/// inheriting the looser one.
SyncRunDecision decideSyncRun({
  required SyncTrigger trigger,
  required bool syncEnabled,
  required bool onUnmeteredNetwork,
}) {
  if (!syncEnabled) return SyncRunDecision.syncDisabled;
  if (trigger == SyncTrigger.manual) return SyncRunDecision.ran;
  return onUnmeteredNetwork
      ? SyncRunDecision.ran
      : SyncRunDecision.waitingForWifi;
}

/// NOT A NETWORK CHECK — the registration guarantee above, read back.
///
/// Mirrors `unmeteredGuaranteedByRegistration` in the backup work for the same
/// reason: an `() async => true` would read like a real check and would not be
/// one. Deriving it from the constant means loosening the constraint
/// automatically stops this claiming Wi-Fi.
Future<bool> syncUnmeteredGuaranteedByRegistration() async =>
    automaticSyncNetworkType == NetworkType.unmetered;
