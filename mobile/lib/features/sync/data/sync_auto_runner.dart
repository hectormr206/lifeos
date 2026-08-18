// Automatic sync while the app is open, on every platform.
//
// `workmanager` covers Android and iOS ONLY, so the desktop had no automatic
// pass at all — the laptop moved data when the user pressed the button and
// never otherwise. That is a platform difference with no capability behind it:
// a running app can perfectly well sync itself on a timer.
//
// It also repairs an Android gap of a different shape. The periodic task was
// registered at the moment sync was ENABLED, so a device that turned it on
// before that code shipped never got one. This runner depends on the STATE
// ("is sync on?") rather than on an event having happened once, which is the
// difference between behaviour that heals itself and behaviour that stays
// broken until someone notices.
//
// It does NOT replace WorkManager on the phone: that is what syncs with the app
// closed. The two overlap harmlessly — a pass with nothing to do is cheap, and
// the engine is idempotent by construction.
import 'dart:async';

import 'package:lifeos/features/sync/data/sync_pass.dart';

/// How often a running app syncs by itself.
///
/// Short enough that two devices in use at the same time feel connected, long
/// enough to be invisible on battery: a pass with nothing to move is one small
/// request per mailbox.
const Duration kAutoSyncInterval = Duration(seconds: 30);

/// How long a local change waits before it is pushed.
///
/// Long enough that typing a note is one pass instead of forty; short enough
/// that "escribí algo" and "aparece en el otro" feel like the same action.
const Duration kSyncChangeDebounce = Duration(seconds: 2);

class SyncAutoRunner {
  SyncAutoRunner({
    required this.isEnabled,
    required this.runPass,
    this.onReport,
  });

  /// Read fresh on every tick, never captured once: sync can be turned off
  /// between ticks and the runner must notice.
  final Future<bool> Function() isEnabled;

  final Future<SyncPassReport> Function() runPass;

  /// Where the outcome goes. An automatic pass nobody records is one the user
  /// cannot see — the whole reason the last-sync line exists.
  final Future<void> Function(SyncPassReport)? onReport;

  Timer? _timer;
  Timer? _debounce;
  bool _busy = false;
  bool _again = false;

  /// Something changed locally — push it without waiting for the interval.
  ///
  /// The interval alone made "casi de inmediato" a lie: a note written on one
  /// device sat there until the next tick. Debounced, because a paragraph being
  /// typed is one change, not one per keystroke.
  void requestSoon() {
    _debounce?.cancel();
    _debounce = Timer(kSyncChangeDebounce, tick);
  }

  void start({Duration every = kAutoSyncInterval}) {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _debounce?.cancel();
    _debounce = null;
  }

  /// One automatic pass. Safe to call at any time.
  Future<void> tick() async {
    // Overlapping passes would deposit envelopes that retire each other and
    // advance the cursor from whichever finished last. A slow pass simply skips
    // the tick it overran.
    if (_busy) {
      // Remember that something arrived while we were busy, so a change made
      // DURING a pass is not lost until the next interval — which is exactly
      // the window where a user writes something and expects it to travel.
      _again = true;
      return;
    }
    _busy = true;
    try {
      if (!await isEnabled()) return;
      final report = await runPass();
      await onReport?.call(report);
    } catch (_) {
      // Swallowed so ONE bad tick cannot end automatic sync for the session —
      // the relay being down for a minute must not require restarting the app.
      // The outcome is still visible: a failing pass records its own reason
      // through `onReport`, and the manual button reports in full.
    } finally {
      _busy = false;
      if (_again) {
        _again = false;
        unawaited(tick());
      }
    }
  }
}

/// The one place local writes say "something changed".
///
/// A global on purpose, and a tiny one. The alternative was threading a
/// callback from the app root through every repository that writes to the
/// graph — chat, notes, reminders, health — and the day one of them was missed
/// its changes would sync late with nothing to show for it.
class SyncChangeSignal {
  void Function()? _listener;

  void listen(void Function() listener) => _listener = listener;
  void stopListening() => _listener = null;

  /// Called after any local write. Cheap and safe when nothing is listening
  /// (tests, headless isolates, sync turned off).
  void changed() => _listener?.call();
}

final syncChangeSignal = SyncChangeSignal();
