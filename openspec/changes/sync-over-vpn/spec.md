# Spec: sync-over-vpn

Concatenated delta spec across three domains. Each is a NEW capability (no
prior `openspec/specs/` entries). See `specs/{domain}/spec.md` for the
canonical per-domain files; this file mirrors them for the Engram artifact.

## Domain: mesh-trust-hardening

### Requirement: Revocation is enforced on every membership verification

`verify_membership` (`axi/src/axi/mesh_trust.py:497-536`) MUST reject a
cert whose node/device is revoked, regardless of `expires_at`, and MUST
re-check on every call (no caching).

#### Scenario: Revoked device fails verification within its cert's validity window
- GIVEN a cert with `expires_at` in the future
- AND `revoked_at` has since been set for that device
- WHEN `verify_membership` runs
- THEN it MUST return `False`

#### Scenario: Revocation is re-checked on every call, not cached
- GIVEN a device verified successfully once
- WHEN it is revoked and `verify_membership` runs again with the same cert
- THEN the second call MUST return `False`

#### Scenario: Non-revoked device with a valid cert still passes
- GIVEN no `revoked_at` and an unexpired, correctly-signed cert
- WHEN `verify_membership` runs
- THEN it MUST return `True`

### Requirement: Pairing requires proof of possession of `device_pubkey`

`POST /api/v1/pair` (`axi/src/axi/api_v1.py:219-227`) MUST NOT accept a
`device_pubkey` without valid PoP; failure MUST state PoP failed.

#### Scenario: Pairing with an unproven device_pubkey is refused
- GIVEN a request with `device_pubkey` and no valid PoP
- WHEN `POST /api/v1/pair` is called
- THEN it MUST be refused with a PoP-failure reason

#### Scenario: Pairing with a valid PoP succeeds
- GIVEN a request with `device_pubkey` and a valid possession proof
- WHEN called
- THEN pairing MUST succeed as today

#### Scenario: Pairing with no device_pubkey is unaffected
- GIVEN `device_pubkey` omitted
- WHEN called
- THEN pairing MUST proceed unchanged

### Requirement: Already-paired devices with an unproven stored key are handled explicitly

#### Scenario: Migration marks pre-existing unproven keys as unproven
- GIVEN a pre-change device row with `device_pubkey` and no PoP record
- WHEN the migration runs
- THEN the key MUST be recorded unproven, and any future sealing to it MUST refuse until re-pair/PoP challenge

## Domain: vpn-gated-backups

### Requirement: Automatic backups run only while reachability of the VPN-only address proves the tunnel is up

Not engine reachability, not the OS's generic VPN-active flag alone.

#### Scenario: Backup runs when the VPN-only address is reachable — MUST run
#### Scenario: Backup does not run when the VPN is down — MUST NOT run
#### Scenario: Home Wi-Fi with LAN engine reachable but VPN-only address unreachable — MUST NOT run
#### Scenario: Unrelated commercial VPN active but VPN-only address unreachable — MUST NOT run

(Each: GIVEN the stated network condition, WHEN the scheduler fires, THEN the backup runs/does not run as labeled.)

### Requirement: VPN dropping mid-backup is a defined failure

#### Scenario: VPN goes down during backup
- GIVEN a backup in progress
- WHEN the VPN-only address becomes unreachable
- THEN the backup MUST abort, MUST be recorded as failed and surfaced, and MUST NOT be presented as successful

### Requirement: Failed, skipped, or undetermined backups are always visible — never silent

#### Scenario: VPN state undetermined — MUST NOT run, MUST surface "undetermined"
#### Scenario: Skipped because VPN was down — MUST be visible to user, not just logged
#### Scenario: Backup call fails post-gate — MUST surface like existing manual-backup failures

### Requirement: Automatic backups respect the Wi-Fi-only heavy-transfer policy

#### Scenario: On VPN but not Wi-Fi
- GIVEN the payload qualifies as heavy
- WHEN on VPN but off Wi-Fi
- THEN it MUST wait for Wi-Fi per `heavy_download_policy.dart`

### Requirement: The user can disable automatic backups, and the choice persists

#### Scenario: User disables — no automatic backup runs afterward regardless of VPN state
#### Scenario: Setting persists across app restart

## Domain: sync-schema-migration

### Requirement: Migration is preceded by a mandatory, verified backup

#### Scenario: No backup taken — migration MUST abort without touching `nodes`/`edges`
#### Scenario: Backup confirmed — migration MUST proceed

### Requirement: An interrupted migration leaves a recoverable, known state

#### Scenario: Process killed mid-migration — restart MUST safely resume or be restorable from the pre-migration backup; no undetectable partial-migration state
#### Scenario: Restarting is idempotent — MUST NOT double-apply (e.g. second `uuid`, duplicate tombstone writes)

### Requirement: Every pre-existing row survives with a stable, independently verifiable identity

#### Scenario: Row count + identity verified post-migration
- GIVEN N `nodes` and M `edges` rows before migration
- WHEN migration completes
- THEN a verification step MUST confirm exactly N/M rows remain and each row's new `uuid` maps back to its original `id` via a recorded mapping/audit table

#### Scenario: No observable behavior change
- GIVEN the full test suite passes before migration
- WHEN migration is applied
- THEN the full suite MUST pass unchanged, per the proposal's success criterion

## Open points carried from the proposal (not resolved here)

- Exact mechanism for "revoked" in `verify_membership` (revocation list vs.
  device-table `revoked_at` lookup) is left to `sdd-design` — the proposal's
  TODO comment (`mesh_trust.py:523-529`) names a signed revocation list as
  the intended shape; this spec only fixes the observable behavior.
- Exact PoP challenge mechanism (signature-over-nonce vs. other) is left to
  `sdd-design`.
- Android VPN-only-address reachability check details (timeout, retry,
  caching window) left to `sdd-design`.
