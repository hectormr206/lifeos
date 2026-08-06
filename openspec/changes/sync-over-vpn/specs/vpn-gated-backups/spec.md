# VPN-Gated Automatic Backups Specification

## Purpose

Make "los backups se deben hacer siempre y cuando estemos conectados al
VPN" enforceable on mobile, where today only last-call success is tracked
(`mobile/lib/core/connectivity/connectivity_status.dart`), which cannot
distinguish VPN from LAN Wi-Fi or another VPN. Reuses the server-side
precedent at `axi/src/axi/feet.py:95-127`. Does not implement data sync.

## Requirements

### Requirement: Automatic backups run only while the mobile app can prove the VPN is up

The system MUST determine VPN state by reachability of the VPN-only
address (e.g. `backup-host` at `10.66.66.1:8099`), not by engine
reachability in general and not by the OS's generic "a VPN is active"
signal alone.

#### Scenario: Backup runs when the VPN-only address is reachable

- GIVEN the phone can reach the VPN-only backup-host address
- WHEN the automatic backup scheduler fires
- THEN the backup MUST run

#### Scenario: Backup does not run when the VPN is down

- GIVEN the phone cannot reach the VPN-only backup-host address
- WHEN the automatic backup scheduler fires
- THEN the backup MUST NOT run

#### Scenario: Home Wi-Fi with the engine reachable on the LAN is not treated as VPN

- GIVEN the phone is on home Wi-Fi and can reach the paired engine directly on the LAN
- AND the phone cannot reach the VPN-only address (VPN is down)
- WHEN the automatic backup scheduler fires
- THEN the backup MUST NOT run

#### Scenario: An unrelated commercial VPN being active does not satisfy the gate

- GIVEN a third-party VPN is active on the device (`NetworkCapabilities.TRANSPORT_VPN` true)
- AND the phone cannot reach the VPN-only backup-host address through it
- WHEN the automatic backup scheduler fires
- THEN the backup MUST NOT run

### Requirement: The VPN dropping mid-backup is a defined failure, not silent partial success

#### Scenario: VPN goes down while a backup is in progress

- GIVEN an automatic backup is running
- WHEN the VPN-only address becomes unreachable before the backup completes
- THEN the backup MUST be aborted (not left half-applied)
- AND the failure MUST be recorded and surfaced to the user (see loud-failure requirement)
- AND no partial backup MUST be presented as a successful one

### Requirement: A failed, skipped, or undetermined backup is always visible to the user

Per the repo rule that a check which cannot run must fail loudly, VPN
state or backup outcome MUST NEVER degrade to "probably fine".

#### Scenario: VPN state cannot be determined

- GIVEN the reachability check itself errors or times out ambiguously
- WHEN the scheduler evaluates whether to run
- THEN the backup MUST NOT run
- AND the app MUST surface that the state was undetermined and no backup ran

#### Scenario: A scheduled backup is skipped because the VPN was down

- GIVEN the VPN was down at the scheduled time
- WHEN the scheduler evaluates the gate
- THEN the skip MUST be visible to the user (not merely logged)

#### Scenario: A backup fails for a reason other than VPN state

- GIVEN the VPN gate passed but the backup call itself fails
- WHEN the failure occurs
- THEN it MUST be surfaced to the user, same as an existing manual-backup failure

### Requirement: Automatic backups respect the Wi-Fi-only heavy-transfer policy

#### Scenario: Automatic backup deferred off Wi-Fi per existing heavy-download policy

- GIVEN `kHeavyDownloadsRequireWiFi` applies to the backup payload size
- AND the device is on VPN but not on Wi-Fi
- WHEN the scheduler fires
- THEN the backup MUST wait for Wi-Fi per the existing policy (`mobile/lib/core/network/heavy_download_policy.dart`), same as other heavy automatic transfers

### Requirement: The user can turn automatic backups off, and the choice persists

Automatic backups are a deliberate, explicit exception to "the user
activates things himself" (unlike game mode, dictation, meetings). The
opt-out MUST exist and MUST survive app restarts.

#### Scenario: User disables automatic backups

- GIVEN automatic backups are enabled
- WHEN the user turns the setting off
- THEN no automatic backup MUST run afterward, regardless of VPN state

#### Scenario: The off setting persists across app restarts

- GIVEN the user disabled automatic backups
- WHEN the app is closed and reopened
- THEN automatic backups MUST remain disabled until the user re-enables them
