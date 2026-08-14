# Recovery Phrase Specification

## Purpose

A mandatory, on-device-generated 12-word phrase that DERIVES the sync
encryption key. Zero-knowledge: the phrase (or a key derived from it) never
leaves the device unencrypted-in-transit-to-a-server, is never escrowed, and
no copy — plaintext or encrypted — is ever held by the VPS. Gates enabling
sync only; local use of LifeOS MUST remain zero-ceremony.

## Requirements

### Requirement: The phrase deterministically derives the sync encryption key

The system MUST derive the sync encryption key from the 12-word phrase via a
deterministic key-derivation function. The system MUST NOT transmit the
phrase, the derived key, or any material that reconstructs either to the
relay, the engine's own storage, or any third party. No plaintext or
encrypted copy of the key/phrase MAY exist outside the device that generated
or entered it.

#### Scenario: Same phrase entered on any device reconstructs the same key
- GIVEN a valid 12-word phrase
- WHEN it is entered on any device (the originating device or a new one)
- THEN the system MUST derive the identical encryption key, byte for byte

#### Scenario: The VPS never receives key material
- GIVEN sync is enabled and operating normally
- WHEN inspecting every request the device sends to the relay or engine
- THEN none MUST contain the phrase, the derived key, or data sufficient to
  reconstruct either

### Requirement: The phrase MUST be confirmed before it is accepted

At creation, the system MUST require the user to re-enter a subset of the
generated words before treating the phrase as accepted. An unconfirmed
phrase MUST NOT enable sync.

#### Scenario: Correct confirmation accepts the phrase
- GIVEN a freshly generated 12-word phrase
- WHEN the user correctly re-enters the requested subset of words
- THEN the phrase MUST be accepted and sync MAY be enabled

#### Scenario: Incorrect confirmation rejects the phrase
- GIVEN a freshly generated phrase
- WHEN the user re-enters even one requested word incorrectly
- THEN the phrase MUST be rejected, sync MUST NOT be enabled, and the user
  MUST be able to retry or regenerate

### Requirement: The phrase gates enabling sync only, never local use

A fresh install MUST reach full local functionality (graph, chat, reminders,
domains, etc.) without ever being prompted for a recovery phrase.

#### Scenario: Fresh install works with zero ceremony
- GIVEN a brand-new install with sync never enabled
- WHEN the user opens and uses any local-only feature
- THEN the system MUST NOT prompt for, require, or block on a recovery
  phrase at any point

#### Scenario: The phrase prompt appears only at the sync opt-in boundary
- GIVEN a user with no phrase yet
- WHEN the user explicitly chooses to enable sync
- THEN the system MUST present phrase generation/entry at that point, and
  not before

### Requirement: Entering the phrase on a new device deterministically reconstructs the key

The system MUST define a fixed wordlist, MUST normalize input before
derivation (case-insensitive comparison, leading/trailing/internal
whitespace collapsed, Unicode normalized to NFKD), and MUST validate a
built-in checksum before deriving the key.

#### Scenario: A mistyped word fails the checksum before derivation
- GIVEN a phrase where one word does not match the wordlist or the checksum
  fails
- WHEN the user submits it
- THEN the system MUST reject it before attempting key derivation and MUST
  report the failure (not silently derive a wrong key)

#### Scenario: Case and whitespace variations are normalized
- GIVEN a correct phrase entered with mixed case or extra whitespace between
  words
- WHEN it is submitted
- THEN the system MUST normalize it and derive the same key as the
  canonical form

### Requirement: A wrong phrase fails clearly, with no lockout and no partial decrypt

The system MUST NOT implement an attempt counter or lockout for phrase
entry, and MUST NOT partially decrypt or apply any sync data on an
unverified/incorrect phrase.

#### Scenario: Wrong phrase produces a clear, retryable failure
- GIVEN an incorrect phrase (valid checksum but not the enrolled one, or
  checksum failure)
- WHEN the user submits it to join an existing sync set
- THEN the system MUST report failure clearly, MUST NOT apply any decrypted
  data, and MUST allow immediate retry with no attempt limit
