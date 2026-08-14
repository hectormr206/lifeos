# Blind Relay Specification

## Purpose

A stateless HTTPS mailbox service, deployed in Coolify on the VPS with
guardrails, that stores nothing but opaque ciphertext envelopes addressed by
recipient device UUID. Store-and-forward with delete-on-ack plus a 30-day
TTL — "nothing stays" means never plaintext and never permanent, not
literally zero storage.

## Requirements

### Requirement: The relay accepts only opaque ciphertext envelopes addressed by recipient UUID

The system MUST accept envelopes consisting of opaque ciphertext, a
recipient device UUID, and an Ed25519 signature, and MUST reject any
envelope it can partially interpret (e.g. a request carrying plaintext
fields, malformed envelope structure, or a missing/invalid recipient UUID).

#### Scenario: Well-formed opaque envelope is accepted
- GIVEN a correctly structured envelope (ciphertext blob, recipient UUID,
  signature) within size limits
- WHEN it is submitted
- THEN the relay MUST accept and queue it

#### Scenario: Malformed or interpretable content is rejected
- GIVEN an envelope missing the recipient UUID, missing a signature, or
  containing fields the relay is not designed to parse
- WHEN it is submitted
- THEN the relay MUST reject it without storing it

### Requirement: The relay verifies the Ed25519 envelope signature without learning device identity

The system MUST verify the envelope's Ed25519 signature proves possession of
a signing key, and MUST NOT require, log, or derive the signer's device UUID
or nickname from the signature itself.

#### Scenario: Valid signature is accepted anonymously
- GIVEN an envelope signed with a valid Ed25519 key
- WHEN the relay verifies it
- THEN verification MUST succeed and the relay MUST NOT record which device
  key signed it, beyond the signature check itself

#### Scenario: Invalid signature is rejected
- GIVEN an envelope with a signature that does not verify against its
  claimed public key
- WHEN submitted
- THEN the relay MUST reject it

### Requirement: Envelopes are deleted on acknowledgment

The system MUST permanently delete an envelope as soon as the recipient
acknowledges receipt.

#### Scenario: Acked envelope is gone
- GIVEN an envelope delivered to and acknowledged by its recipient
- WHEN a subsequent fetch for that recipient occurs
- THEN the acknowledged envelope MUST NOT be returned or retrievable

### Requirement: Unacknowledged envelopes expire after 30 days

The system MUST delete any envelope that has not been acknowledged within 30
days of receipt, independent of delete-on-ack.

#### Scenario: Envelope older than 30 days and unacked is purged
- GIVEN an envelope stored 30+ days without acknowledgment
- WHEN the TTL sweep runs (or the envelope is next accessed)
- THEN it MUST be deleted and MUST NOT be delivered

#### Scenario: Envelope within TTL and unacked remains available
- GIVEN an envelope stored fewer than 30 days, unacked
- WHEN the intended recipient fetches it
- THEN it MUST still be delivered

### Requirement: The relay enforces a maximum envelope size

The system MUST define and enforce a maximum envelope size and MUST reject
oversized submissions before storage.

#### Scenario: Oversized envelope is rejected
- GIVEN an envelope larger than the configured maximum
- WHEN it is submitted
- THEN the relay MUST reject it with a clear size-limit error and MUST NOT
  store any part of it

### Requirement: The relay holds no state beyond pending envelopes and live mailbox claims

The system MUST NOT maintain a per-device registry, an account table, or any
persisted mapping of *device identity*. It MAY persist exactly one record per
mailbox — its UUID and the pseudonymous Ed25519 auth pubkey presented when the
mailbox was claimed — and nothing else. That record exists solely so the relay
can reject deposits into unclaimed mailboxes; without it the relay is an open
drop box that anyone knowing a UUID can flood.

The mailbox claim MUST expire on the same 30-day TTL as an unacked envelope,
refreshed by any successfully authenticated use of that mailbox. A device set
that stops syncing therefore leaves no trace on the VPS once its last envelope
and its claim have both expired.

The claim record MUST NOT contain, or allow the relay to derive, a nickname,
a device name, a `devices.device_pubkey`, or any linkage between two mailboxes
of the same device set.

#### Scenario: An idle device set leaves nothing behind
- GIVEN every envelope for a mailbox has been acked or expired
- AND the mailbox has gone 30 days without an authenticated request
- WHEN inspecting relay-side storage
- THEN no envelope, claim, or any other row MUST remain for that mailbox UUID

#### Scenario: A live claim is kept alive by use
- GIVEN a claimed mailbox with no pending envelopes
- WHEN any authenticated request for that mailbox succeeds
- THEN its claim expiry MUST be extended by a further 30 days

#### Scenario: The relay cannot link two mailboxes of one device set
- GIVEN two mailboxes belonging to the same device set
- WHEN inspecting every field the relay persists for both
- THEN nothing MUST identify them as related — the auth pubkeys MUST be
  distinct and independently random-looking

### Requirement: Residual metadata the relay unavoidably observes is documented, not hidden

The system MUST document, in user-facing terms, that the relay necessarily
observes the recipient UUID, envelope size, and delivery timing for every
envelope it handles, even though it never observes content.

#### Scenario: Residual metadata is disclosed to the user
- GIVEN a user enabling sync
- WHEN they review what the relay can see
- THEN the documentation MUST explicitly state that recipient UUID,
  envelope size, and timing are visible to the relay operator, distinct from
  content, which is never visible
