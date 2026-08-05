/// Couple-partner scoping (relationships-robustness, Slice 5).
///
/// `couple_act` entries record what one partner did / said they valued, but
/// carry no `partner_id` today — there is no way to tell WHICH partner an act
/// belongs to once the relationship has more than one over time. Per the
/// binding user answer, the current partner exists as an `unnamed: true`
/// person identity (Slice 2) from the start: existing and new acts attach to
/// that ULID immediately, and naming the partner later is a RENAME (Slice 2's
/// `renamed()`), never a re-attribution.
///
/// The user has NOT supplied the partner's name at the time of this slice —
/// this module MUST NOT invent one. [couplePartnerDisplayLabel] is the single
/// place that decision is enforced.
///
/// PURE — no I/O. The repository wires the identity/backfill I/O in a
/// separate file.
library;

import 'person_identity.dart' show PersonIdentity;

/// Shown wherever the partner's name would otherwise appear, for as long as
/// they are `unnamed`. Leads with the ask, never a guessed name or a blank —
/// silence here would look like a bug, not a "not yet told" state.
const String kUnnamedPartnerPrompt = 'Sin asignar — nombra a tu pareja para vincular estos registros';

/// The label to show for the current partner: their canonical name once
/// named, or the explicit [kUnnamedPartnerPrompt] — NEVER a placeholder name,
/// and never blank — while [partner] is null or still [PersonIdentity.unnamed].
String couplePartnerDisplayLabel(PersonIdentity? partner) {
  if (partner == null || partner.unnamed) return kUnnamedPartnerPrompt;
  return partner.canonicalName;
}
