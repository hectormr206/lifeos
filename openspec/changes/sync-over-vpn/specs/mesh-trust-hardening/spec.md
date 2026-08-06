# Mesh Trust Hardening Specification

## Purpose

Close the two known holes in `axi/src/axi/mesh_trust.py` and
`axi/src/axi/api_v1.py:219-227` that sync will depend on: unenforced
revocation and unproven `device_pubkey` ownership at pairing.

## Requirements

### Requirement: Revocation is enforced on every membership verification

`verify_membership` (`axi/src/axi/mesh_trust.py:497-536`) MUST reject a
cert whose associated node/device has been revoked, independent of the
cert's `expires_at`. The check MUST run on every call — not cached from a
prior pass — because a single stale `True` defeats the purpose.

#### Scenario: Revoked device fails verification within its cert's validity window

- GIVEN a device with a membership cert whose `expires_at` is still in the future
- AND `revoked_at` has since been set for that device
- WHEN `verify_membership` is called with that cert
- THEN it MUST return `False`

#### Scenario: Revocation is re-checked on every call, not cached

- GIVEN a device verified successfully once (not yet revoked)
- WHEN the device is revoked and `verify_membership` is called again with the same cert
- THEN the second call MUST return `False`

#### Scenario: Non-revoked device with a valid, unexpired cert still passes

- GIVEN a device with no `revoked_at` and an unexpired, correctly-signed cert
- WHEN `verify_membership` is called
- THEN it MUST return `True` (unchanged behavior)

### Requirement: Pairing requires proof of possession of `device_pubkey`

`POST /api/v1/pair` (`axi/src/axi/api_v1.py:219-227`) MUST NOT accept a
`device_pubkey` without a valid proof that the caller holds the matching
private key. On failure, the response MUST state that PoP failed (not a
generic error).

#### Scenario: Pairing with an unproven device_pubkey is refused

- GIVEN a pairing request supplying `device_pubkey` but no valid PoP
- WHEN `POST /api/v1/pair` is called
- THEN the request MUST be refused
- AND the response body MUST indicate proof-of-possession failure

#### Scenario: Pairing with a valid PoP succeeds

- GIVEN a pairing request supplying `device_pubkey` and a valid signature/challenge response proving possession
- WHEN `POST /api/v1/pair` is called
- THEN the device MUST be paired as today (device_id + token issued)

#### Scenario: Pairing with no device_pubkey at all is unaffected

- GIVEN a pairing request with `device_pubkey` omitted (`None`)
- WHEN `POST /api/v1/pair` is called
- THEN pairing MUST proceed exactly as before this change (PoP is not applicable to an absent key)

### Requirement: Already-paired devices with an unproven stored key are handled explicitly

Devices paired before this change stored `device_pubkey` verbatim with no
PoP (`axi/src/axi/store.py:2606-2659`). The system MUST NOT silently
grandfather these as trusted-equivalent to newly-proven keys.

#### Scenario: Migration marks pre-existing unproven keys as unproven

- GIVEN a device row created before this change with a non-null `device_pubkey` and no PoP record
- WHEN the migration for this change runs
- THEN that device's key MUST be recorded as unproven (not silently treated as proven)
- AND any future feature that seals payloads to `device_pubkey` MUST refuse to use an unproven key until the device re-pairs or completes a PoP challenge
