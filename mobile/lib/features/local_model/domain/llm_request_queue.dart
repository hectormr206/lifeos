import 'dart:async';

/// A FIFO queue that lets exactly ONE piece of on-device model work run at a
/// time.
///
/// WHY THIS EXISTS. The phone runs a single native LiteRT-LM session. Every
/// feature that thinks it owns the model — chat, briefing translation, the
/// short-brief writer, the on-demand article summary, the Hacker News comments
/// summary — is really sharing that one session. Two overlapping generations do
/// not queue themselves at the native layer: they interleave, and the user sees
/// it as the first answer stopping mid-sentence ("se queda mocho").
///
/// The contract is deliberately narrow:
///   * jobs run strictly in submission order, one at a time;
///   * a job is NEVER dropped — a second request waits and then runs, so no
///     work the user asked for disappears;
///   * a failing job propagates its error to ITS caller only, and the queue
///     keeps draining;
///   * [runningLabel] / [queuedLabels] / [onStart] make the wait observable, so
///     the UI can honestly distinguish "running now" from "waiting its turn".
///
/// Re-entrancy is explicitly allowed: a job that itself calls back into the
/// queue (a queued task using a queued engine) runs the nested work INLINE,
/// because it already holds the slot. Without this, wrapping a task around an
/// already-serialized engine would deadlock.
class LlmRequestQueue {
  /// Zone key marking "this fiber already holds a slot of THIS queue".
  static const Object _holderKey = #lifeosLlmRequestQueueHolder;

  /// The chain every submitted job appends itself to. Completed jobs never
  /// throw into it (errors are routed to each job's own future), so one failure
  /// cannot stall the queue.
  Future<void> _tail = Future<void>.value();

  final List<String?> _waiting = <String?>[];
  String? _runningLabel;
  bool _running = false;

  /// Label of the job executing right now, or null when idle.
  String? get runningLabel => _runningLabel;

  /// Labels of the jobs that are waiting their turn, in the order they will
  /// run. A null label is reported as an empty string so the list stays simple
  /// for the UI.
  List<String> get queuedLabels => [for (final l in _waiting) l ?? ''];

  /// How many jobs are waiting (not counting the one running).
  int get pending => _waiting.length;

  /// Whether a job is executing right now.
  bool get isBusy => _running;

  /// Enqueues [task] and returns its result. [label] names the job for the UI;
  /// [onStart] fires at the moment the job actually begins (never at
  /// submission), which is what lets a caller show "en cola" and then
  /// "ejecutando".
  Future<T> add<T>(
    Future<T> Function() task, {
    String? label,
    void Function()? onStart,
  }) {
    if (identical(Zone.current[_holderKey], this)) {
      // Already inside a job of this queue: run inline, or we would wait for a
      // slot that we are ourselves occupying.
      onStart?.call();
      return task();
    }

    final completer = Completer<T>();
    _waiting.add(label);
    final previous = _tail;
    _tail = () async {
      try {
        await previous;
      } catch (_) {
        // A previous job's failure belongs to ITS caller, never to this one.
      }
      _waiting.remove(label);
      _running = true;
      _runningLabel = label;
      try {
        // Inside the try on purpose: a listener that throws must not strand the
        // caller's future uncompleted — that would be work silently lost, the
        // exact failure this queue exists to prevent.
        onStart?.call();
        completer.complete(
          await runZoned(task, zoneValues: {_holderKey: this}),
        );
      } catch (error, stack) {
        completer.completeError(error, stack);
      } finally {
        _running = false;
        _runningLabel = null;
      }
    }();
    return completer.future;
  }
}
