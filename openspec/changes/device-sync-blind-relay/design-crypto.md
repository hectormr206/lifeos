# Design: device-sync-blind-relay — CRYPTO scheme (companion to design.md)

Concrete primitives only. Everything here must be byte-identical between
Python (`cryptography` lib) and Dart (`cryptography: ^2.9.0`,
`mobile/pubspec.yaml:115`) — §5 defines how that identity is proven.

## 1. Recovery phrase → root key

**Wordlist**: BIP-39 English (2048 words), **vendored** as an asset in both
codebases, not pulled via `bip39`-style packages.
**Encoding**: standard BIP-39 — 128 bits CSPRNG entropy + 4-bit SHA-256
checksum → 132 bits → 12 × 11-bit indices. Validation on entry rejects a bad
checksum before any network call. ~40 lines per language, pinned by the
official Trezor test vectors embedded in the shared vector file.
**KDF**: `root_key RK (32 B) = HKDF-SHA256(ikm = entropy_16B, salt = "",
info = "lifeos/sync/root/v1")`.

**Decision — HKDF, not argon2id, not BIP-39's PBKDF2.** The codebase precedent
(`_derive_kek`, `axi/src/axi/mesh_trust.py:248`) uses argon2id to harden a
*human-chosen* passphrase. Our input is machine-generated, uniform 128-bit
entropy: no KDF work factor improves a 2^128 search, so argon2id would buy
zero security while adding a heavy dependency and cross-platform
parameter-mismatch risk (argon2 version/memory drift across 5 platforms).
BIP-39's PBKDF2-HMAC-SHA512 (2048 iters) rejected for the same reason plus its
optional passphrase field, which invites a second, escrow-shaped secret.
HKDF-SHA256 is deterministic, present in both libraries, and trivially
test-vectored. Rejected alternative recorded; this is a deliberate divergence
from `_derive_kek`, not an oversight.

## 2. Key hierarchy

    12 words ──BIP39──▶ entropy (16 B)
                          │ HKDF "lifeos/sync/root/v1"
                          ▼
                        RK (32 B)                    never leaves the device
              ┌───────────┼──────────────────────┐
              ▼                                  ▼
    DK = HKDF(RK, info="lifeos/sync/data/v1")   mailbox-auth seeds (per mailbox m):
    32 B AES-256 data key, shared by the         seed_m = HKDF(RK, salt=uuid_m,
    whole device set                             info="lifeos/sync/mbauth/v1")
                                                 → Ed25519 keypair from seed

Plus, independent of the phrase: a **per-install Ed25519 device keypair**,
randomly generated at install, stored in the OS keystore, populating
`devices.device_pubkey`/`pubkey_proven` (`axi/src/axi/store.py:2886-2897`,
proposal decision 5). It identifies the device *inside* the set (roster,
future PoP); it is never shown to the relay.

**Decision — one shared symmetric data key, not per-device asymmetric.**
All recipients are the same person's devices. Sealed-box-per-device would cost
N encryptions per change, make envelopes unreadable to devices joined later,
and complicate recovery. With one DK, phrase entry alone restores the ability
to decrypt, which is exactly the recovery contract. Rejected: per-pair X25519
sessions (state per pair, breaks phrase-recovers-everything).

**Forward secrecy — explicitly none, accepted.** A compromised phrase decrypts
every envelope the adversary ever recorded, past and future. Accepted because:
(a) the threat model this change answers is "the VPS operator, or whoever
seizes the VPS, must be cryptographically unable to read" — and envelopes are
transient (delete-on-ack + 30-day TTL), so a recording adversary must tap the
relay continuously, not seize it once; (b) ratcheting requires per-pair
session state that cannot be re-derived from the phrase, destroying the
recovery property that proposal decision 3 makes mandatory. The envelope
`version` byte is the escape hatch: a future key epoch (new phrase, re-derive,
re-key) is a rotation mechanism, not FS, and is out of scope. This tradeoff is
stated in the slice-5 metadata disclosure, user-facing.

## 3. Envelope

Binary framing (not JSON), fixed offsets:

    version(1 B, =0x01) ‖ env_id(32 B, CSPRNG) ‖ recipient_uuid(16 B) ‖ ciphertext

- **Per-envelope key**: `EK = HKDF-SHA256(ikm=DK, salt=env_id, info="lifeos/sync/envelope/v1")`.
- **AEAD**: AES-256-GCM, key `EK`, **nonce = 12 zero bytes**, AAD = the 49
  header bytes.
- **Nonce discipline — reuse made impossible by construction**: the long-lived
  key never encrypts; every envelope uses a single-use key derived from a
  random 256-bit `env_id` (collision probability negligible at 2^128 birthday
  bound), so the fixed nonce is safe and there is no counter to persist or
  desynchronize across devices. Rejected: random 96-bit GCM nonce under
  long-lived DK (2^32 birthday bound is a standing analytic obligation);
  XChaCha20-Poly1305 (192-bit nonce solves it elegantly but Python's
  `cryptography` does not expose XChaCha — it would force a new native
  dependency, pynacl, on the axi side).
- **Plaintext by necessity**: version (parsing), `recipient_uuid` (relay
  routing), `env_id` (ack/dedupe). Nothing else. AAD-binding the header means
  a relay that reroutes or re-addresses an envelope produces a decryption
  failure, never a mis-applied change.
- **Payload** (inside AEAD): JSON `{schema_version, origin_device, rows:
  {nodes:[], edges:[]}, peer_cursor_echo, roster?}` — parsed normally on
  receipt; **no canonical-JSON requirement anywhere** (see §5).

## 4. Relay authentication (blind Ed25519)

Every relay call carries `X-Sync-Sig` = Ed25519 signature by the mailbox's
auth key (§2) over `method ‖ path ‖ ts ‖ nonce ‖ sha256(body)`, with `ts`
freshness window and a relay-side nonce cache (same shape as
`build_signed_payload`, `axi/src/axi/mesh_trust.py:595`). The mailbox auth
keypair is derived from RK per mailbox, so **any** set device can sign
deposits into **any** set mailbox, while the relay sees only one random
pubkey per mailbox — it can prove "authorized for this mailbox", never "who".
Per-mailbox (rather than one per-set) keys avoid handing the relay an
explicit device-set linkage; IP/timing correlation remains and is disclosed
(design.md, residual metadata).

## 5. New-device join

**Choice: phrase entry (cryptographic membership) + one peer mailbox UUID via
QR or manual entry (routing bootstrap).** The new device derives RK/DK/auth
keys from the typed phrase — the relay never sees key material — claims its
own mailbox, and sends an encrypted `hello` to the scanned peer's mailbox;
the peer replies with the device roster (uuid, nickname, device_pubkey per
device) and announces the newcomer to the others. Roster entries merge LWW
like any synced data. Desktop without camera: the UUID is short enough to
type; every device shows its own in sync settings.
**Rejected**:
- *Phrase-entry-only* — needs peer discovery, i.e. a deterministic rendezvous
  mailbox whose announcements must outlive delete-on-ack and the 30-day TTL:
  a second retention class and permanent linkable state on the VPS, exactly
  what the relay design forbids.
- *QR carrying key material* — the phrase is the single key ceremony;
  screen-captured QR codes leak, and it would create a second secret channel
  to audit.

**Total-loss honesty**: the phrase restores *membership and decryption
ability*, not data — the relay holds only transient ciphertext. With every
device gone, data recovery is the backup product's job (VPN-only, out of
scope). Stated in the slice-5 UX.

## 6. Cross-language agreement — the byte-exact surface and its tests

Two independent implementations of one format is the top correctness risk.
The surface is deliberately minimized: signatures verify the **exact
transmitted bytes** and payload JSON is parsed, never re-canonicalized, so
cross-language canonical JSON (float formatting, key order) is **out** of the
contract. What must match byte-for-byte:

1. mnemonic ↔ entropy (wordlist + checksum),
2. HKDF derivations (all `info`/`salt` strings above),
3. Ed25519 keypair-from-seed,
4. envelope framing + AEAD output,
5. the relay signature preimage (§4).

**Contract**: `shared/sync-test-vectors/vectors.json`, generated by the Python
implementation in PR 1a (plus official BIP-39 vectors), committed, and
asserted by BOTH `axi/tests/test_sync_vectors.py` and
`mobile/test/core/sync/sync_vectors_test.dart`. Each vector fixes all inputs
(entropy, env_id, payload bytes) and the expected outputs (mnemonic, RK, DK,
auth pubkeys, full envelope bytes, signature). CI runs both suites; a
divergence is a red test, not a field incident. The merge-rule fixtures
(design.md, testing) ride the same file so LWW/tiebreak/delete-dominates
decisions are also proven identical.
