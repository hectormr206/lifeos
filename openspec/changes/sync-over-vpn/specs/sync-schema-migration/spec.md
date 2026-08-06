# Sync Schema Migration Specification

## Purpose

Add `uuid`, lamport/origin columns, and soft-delete tombstones to
`nodes`/`edges` (`axi/src/axi/store.py:198-222`), in isolation, with zero
behavior change. This migration is a one-way, irreversible prerequisite
for the future sync engine — no merge logic, no transport, no event log.

## Requirements

### Requirement: The migration is preceded by a mandatory, verified backup

Because the migration is irreversible, it MUST NOT proceed without a
fresh backup taken specifically as a migration precondition.

#### Scenario: Migration refuses to run without a pre-migration backup

- GIVEN no backup has been taken as part of this migration run
- WHEN the migration is invoked
- THEN it MUST take (or require and verify) a backup before altering any schema or data
- AND it MUST abort without touching `nodes`/`edges` if the backup cannot be confirmed to have completed successfully

#### Scenario: Migration proceeds once the backup is confirmed

- GIVEN a pre-migration backup has completed and been verified readable
- WHEN the migration runs
- THEN it MUST proceed to apply schema and data changes

### Requirement: A migration interrupted midway leaves the database in a recoverable, known state

#### Scenario: Process is killed partway through migration

- GIVEN the migration has started and altered some but not all rows/tables
- WHEN the process is killed (power loss, `kill -9`) before completion
- THEN restarting the migration MUST either safely resume to completion or leave the database in a state restorable from the pre-migration backup
- AND the migration MUST NOT leave the schema in a state where `nodes`/`edges` are only partially migrated with no way to detect that mid-state

#### Scenario: Restarting an interrupted migration is idempotent

- GIVEN a previous migration attempt was interrupted
- WHEN the migration is run again
- THEN it MUST NOT double-apply changes to rows already migrated (e.g. assign a second `uuid`, or duplicate tombstone columns)

### Requirement: Every pre-existing row survives the migration with a stable, verifiable identity

Row survival MUST be independently verified after migration, not merely
asserted by the migration script's own exit code.

#### Scenario: Row count and identity are verified after migration

- GIVEN N rows exist in `nodes` and M rows in `edges` before migration
- WHEN the migration completes
- THEN a post-migration verification step MUST confirm exactly N `nodes` rows and M `edges` rows exist (accounting only for documented, intentional changes, if any)
- AND MUST confirm each pre-existing row's new `uuid` maps back to its original `id` (e.g. via a recorded id→uuid mapping or audit table), so identity continuity can be checked, not just claimed

#### Scenario: No behavior change is observable post-migration

- GIVEN the existing test suite passes before migration
- WHEN the migration is applied and the same test suite is run again
- THEN the full suite MUST pass with zero user-visible behavior change, per the proposal's success criterion
