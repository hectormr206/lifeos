# Device Identity Specification

## Purpose

Each install gets a per-device UUID and keypair, generated fully offline,
persisted on `devices.device_pubkey` / `pubkey_proven`
(`axi/src/axi/store.py:2886-2897`). Nicknames are unique only within one
user's own device set — no server-side registry.

## Requirements

### Requirement: The device UUID is generated on-device, offline, and never reused

The system MUST generate a per-install UUID locally with no server call,
MUST NOT derive it from a hardware identifier (MAC address, IMEI, serial
number, or similar) that could change, be spoofed, or collide across
devices, and MUST NOT reuse a UUID across reinstalls or other devices.

#### Scenario: UUID generation requires no network
- GIVEN a device with no network connectivity
- WHEN device identity is first established
- THEN a valid UUID MUST be generated successfully

#### Scenario: Reinstall produces a new UUID
- GIVEN a device that previously had an identity and is reinstalled/reset
- WHEN identity is established again
- THEN the new UUID MUST differ from the previous one

### Requirement: Nicknames are unique within the user's own device set only

The system MUST reject a nickname that collides with another device already
in the same user's device set, and MUST NOT require or perform any
cross-user or global uniqueness check.

#### Scenario: Duplicate nickname within one user's set is rejected
- GIVEN a device set containing a device named "Phone"
- WHEN the user tries to name a new device "Phone"
- THEN the system MUST reject the name and require a different one, without
  contacting the relay or any server-side registry

#### Scenario: Same nickname across different users' device sets is allowed
- GIVEN two independent users, each with a device named "Phone"
- WHEN either enrolls a device
- THEN no collision MUST be reported, since uniqueness is scoped per user

### Requirement: The device keypair is persisted via the existing pubkey columns

The system MUST generate an Ed25519 keypair per device and MUST persist the
public key and its proof-of-possession status using the existing
`devices.device_pubkey` / `devices.pubkey_proven` columns. The system MUST
NOT introduce a parallel identity table.

#### Scenario: Keypair generation populates the existing columns
- GIVEN a new device establishing identity
- WHEN the keypair is generated and proof of possession is completed
- THEN `device_pubkey` MUST be set and `pubkey_proven` MUST reflect the
  proof outcome

#### Scenario: An unproven key is not treated as trusted
- GIVEN a device row with `device_pubkey` set but `pubkey_proven` false
- WHEN the device attempts an identity-gated action
- THEN the system MUST treat it as unproven and refuse until proof of
  possession succeeds
