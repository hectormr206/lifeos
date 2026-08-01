/// Sharing policy between two partners' assistants.
///
/// THE RISK THIS GUARDS. Connecting both assistants can turn a private journal
/// into a surveilled relationship. If Axi knows what he feels and reports it,
/// it stops being his assistant and becomes a monitor — and the effect on the
/// relationship is the opposite of the one intended. That failure is not
/// technical, so a technical fix cannot come later: it has to be the shape of
/// the thing from the start.
///
/// THE RULE: explicit sharing, never synchronisation. Only what the user hands
/// over goes across, piece by piece. No mirrored moods, no automatic metrics,
/// no "share everything" switch — that last one is synchronisation wearing a
/// different label.
///
/// SCOPE, as decided: shared dates and reminders only — anniversaries, plans.
/// Everything else stays private. It is far easier to open up later than to
/// un-share something already shared, which is why the narrow start is the
/// safe one.
///
/// TRANSPORT IS DELIBERATELY ABSENT. This file decides WHAT may cross and on
/// whose initiative; it does not decide how. That choice — a peer-to-peer
/// protocol versus a server holding two people's intimate data — is the user's
/// to make, and this policy holds whichever way it goes.
library;

/// Kinds the system knows about. Only two are shareable; the rest exist here
/// precisely so that attempting to share them is a loud, testable failure
/// rather than an omission someone later "fixes".
enum ShareKind {
  date,
  reminder,

  // ── Never shareable ──────────────────────────────────────────────────────
  /// The single most damaging thing to mirror.
  mood,
  health,
  note,

  /// An observation ABOUT the relationship, made for one person to sit with.
  /// Sent across, it stops being a reflection and becomes an accusation.
  loveLanguageObservation,
}

const Set<ShareKind> _shareable = {ShareKind.date, ShareKind.reminder};

/// Something the user may hand to their partner.
///
/// Constructing one of a private kind throws: the refusal lives at the type's
/// door, so no call site can reach a state where private data is merely
/// "not shared yet".
class ShareableItem {
  ShareableItem({required this.kind, required this.title, this.when}) {
    if (!_shareable.contains(kind)) {
      throw UnsupportedError(
        '${kind.name} is never shareable. Only dates and reminders cross, and '
        'only when the user sends them one at a time.',
      );
    }
  }

  final ShareKind kind;
  final String title;
  final DateTime? when;

  /// Exactly the fields the partner needs to act on. No identifiers, no device
  /// information, no metrics: anything extra here is a leak that nobody asked
  /// for and nobody would notice.
  Map<String, Object?> toWire() => {
        'kind': kind.name,
        'title': title,
        if (when != null) 'when': when!.toUtc().toIso8601String(),
      };
}

bool canShare(ShareableItem item) => _shareable.contains(item.kind);

/// Items the user has chosen to send, awaiting transport.
///
/// Starts empty and stays empty until something is handed over by hand. There
/// is no constructor that seeds it from existing data, and no bulk operation —
/// the absence is the feature.
class ShareOutbox {
  final List<ShareableItem> _pending = [];

  /// Stated explicitly so a future reader does not add one thinking it was an
  /// oversight.
  static const bool supportsBulkSharing = false;

  List<ShareableItem> get pending => List.unmodifiable(_pending);

  /// Hand one item over. One call, one item, always by the user's action.
  void share(ShareableItem item) {
    if (!canShare(item)) {
      throw UnsupportedError('${item.kind.name} is never shareable');
    }
    _pending.add(item);
  }

  /// Take it back before it leaves. Un-sharing after the fact is not something
  /// software can promise, so the window before sending is the only honest
  /// place to offer it.
  void revoke(ShareableItem item) => _pending.remove(item);
}
