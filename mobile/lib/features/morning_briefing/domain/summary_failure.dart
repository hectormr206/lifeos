/// Why an on-demand summary could not be produced — and, the part the reader
/// actually needs, what can be done about it.
///
/// WHY THIS EXISTS. The on-demand summary used to catch every error in one
/// `catch (_)` and write one string: "No se pudo generar el resumen. Inténtalo
/// de nuevo." A phone with NO MODEL INSTALLED therefore looked exactly like a
/// paywalled page, and the only suggestion — try again — was wrong for both.
/// The user hit this on build 799 and had to go hunting for the real cause
/// himself.
///
/// Each value is a cause we actually OBSERVED at a specific step. Nothing here
/// is a guess: when the step that failed cannot be identified, that is
/// [unknown] and it says so, rather than naming the most likely suspect.
library;

import '../../local_model/domain/engine_failure_detail.dart';

export '../../local_model/domain/engine_failure_detail.dart'
    show EngineFailureDetail, LlmEngineCall;

enum SummaryFailure {
  /// There is no model on the device at all. Nothing can be summarized until
  /// one is downloaded.
  modelMissing,

  /// A model IS installed, but it could not be used: loading it failed, or the
  /// generation itself blew up (out of memory, a broken file, a busy engine).
  /// Trying again can genuinely work.
  modelUnavailable,

  /// The article page (or the comments thread) could not be downloaded:
  /// network, timeout, or the site refusing us.
  pageUnavailable,

  /// The page WAS downloaded and holds no readable text — a paywall, a
  /// JavaScript-only page, a pure video/PDF. Permanent for this article.
  pageUnreadable,

  /// A Hacker News thread with no comments to summarize.
  commentsMissing,

  /// The model ran and returned nothing usable.
  emptyGeneration,

  /// Something failed that we could not attribute to any step above. Reported
  /// as unclassified on purpose — a wrong diagnosis is worse than an honest
  /// "no sé".
  unknown,
}

/// What the card should OFFER for a failure. Three shapes, never two: some
/// failures deserve a retry, one deserves a completely different action, and
/// some deserve no tap at all.
enum SummaryRecovery {
  /// Transient: a retry can succeed.
  retry,

  /// Nothing to retry — the user needs a model first.
  installModel,

  /// Permanent for this item: retrying would produce the identical failure.
  none,
}

extension SummaryFailureRecovery on SummaryFailure {
  SummaryRecovery get recovery => switch (this) {
    SummaryFailure.modelMissing => SummaryRecovery.installModel,
    SummaryFailure.pageUnreadable ||
    SummaryFailure.commentsMissing => SummaryRecovery.none,
    SummaryFailure.modelUnavailable ||
    SummaryFailure.pageUnavailable ||
    SummaryFailure.emptyGeneration ||
    SummaryFailure.unknown => SummaryRecovery.retry,
  };
}

/// Thrown inside the on-demand summary job to carry the identified cause out
/// to the one place that records it. Internal to the summary pipeline.
///
/// [detail] carries the underlying engine exception when the cause was
/// identified BY one — the evidence [SummaryFailure.modelUnavailable]'s merge
/// would otherwise destroy. Null for causes identified without touching the
/// model (an unreadable page, a thread with no comments): there is no engine
/// exception there, and inventing one would be a fabricated observation.
class SummaryFailureException implements Exception {
  const SummaryFailureException(this.failure, {this.detail});

  final SummaryFailure failure;
  final EngineFailureDetail? detail;

  @override
  String toString() => 'SummaryFailureException(${failure.name})';
}

/// A failure as the card shows it: WHAT went wrong, plus how many times the
/// user has now asked for this summary.
///
/// The attempt count exists because the retry is instant: without it, a second
/// failure repaints the identical red line and the tap looks swallowed.
class SummaryAttemptFailure {
  const SummaryAttemptFailure({
    required this.failure,
    required this.attempt,
    this.detail,
  });

  final SummaryFailure failure;

  /// 1 for the first failure, 2 for the first retry, and so on.
  final int attempt;

  /// The underlying engine exception, when the cause came from one. The card
  /// keeps it COLLAPSED — the plain-language sentence stays the headline — but
  /// it must be reachable and copyable, because it is the only evidence that
  /// exists on the device where the failure actually happens.
  final EngineFailureDetail? detail;

  @override
  bool operator ==(Object other) =>
      other is SummaryAttemptFailure &&
      other.failure == failure &&
      other.attempt == attempt &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(failure, attempt, detail);

  @override
  String toString() =>
      'SummaryAttemptFailure(${failure.name}, attempt: $attempt)';
}
