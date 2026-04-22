# Skill Generator & Registry — Security Model

`daemon/src/skill_generator.rs` lets Axi turn successful task traces into reusable shell scripts (`run.sh`) and lets the registry execute SKILL.md commands. Both paths are dangerous without guardrails — they take LLM-influenced content and run it as the daemon's user. This document captures the layered defences.

## Threat model

Vectors that can plant or trigger an unsafe skill:

- **SimpleX inbound** — a contact nudges Axi into generating a skill from a malicious task.
- **Dashboard chat** — same, via the in-process router.
- **Local FS write to `~/.local/share/lifeos/skills/` or `~/.config/lifeos/skills/`** — a flatpak app, supply-chain-tainted crate, or another process under the same UID drops a `manifest.json` and `run.sh` directly.

A "successful" attack runs arbitrary shell as the `lifeos` user with full access to memory plane, embeddings, screenshots, tokens, and outbound network.

## Three independent gates

Every execution path checks all three. Missing any one → execution is refused.

### Gate 1: `LIFEOS_SKILLS_AUTOEXEC_ENABLE` (operator opt-in)

Defaults OFF. The daemon will refuse to execute any auto-generated skill without this env var set to `1` / `true` / `yes` / `on`. This existed before this PR; PR 3 keeps it.

### Gate 2: `requires_review` + approval (per-skill opt-in)

Auto-generated manifests now ALWAYS set `requires_review: true` and `approved_at: null`. A skill is considered approved if any of:

1. `manifest.requires_review` is `false` (user-installed plugins, hand-written skills).
2. `manifest.approved_at` is a non-empty RFC3339 timestamp (set via dashboard or by editing the file).
3. A sibling file named `approved` exists in the skill directory (`touch <skill_dir>/approved`).

Legacy manifests on disk (pre-PR-3) lack the field; serde defaults to `false`, so they keep working as approved without migration.

### Gate 3: systemd-run sandbox

When `/usr/bin/systemd-run` (or `/bin/systemd-run`) is available, the actual exec is wrapped in a `--user --scope` invocation with these properties:

| Property | Effect |
|---|---|
| `PrivateNetwork=yes` | No outbound network. Closes the exfil channel. |
| `ProtectHome=read-only` | Skill can read `$HOME` but cannot write to it (no tampering with memory plane, embeddings, configs). |
| `NoNewPrivileges=yes` | Cannot escalate via setuid binaries (e.g. `pkexec`). |
| `ProtectSystem=strict` | No writes under `/usr`, `/boot`, `/efi`. |
| `PrivateTmp=yes` | Private `/tmp` namespace; cannot read or plant in shared `/tmp`. |
| `MemoryMax=256M` | OOM-kill before consuming the daemon's RAM. |
| `TasksMax=64` | Caps fork-bomb damage. |
| `RuntimeMaxSec=60` | Hard wall-clock kill in addition to the existing tokio timeout. |

If `systemd-run` is missing (rare, but possible in CI sandboxes or non-systemd containers), execution falls back to unconfined `bash`/`sh -c`. This is logged loudly as `[skill_gen] systemd-run not available, executing UNSANDBOXED`. Operators in this position should either install `systemd` or leave `LIFEOS_SKILLS_AUTOEXEC_ENABLE` off.

## File-size cap

All skill source files (`SKILL.md`, `manifest.json`, `run.sh`) are read via `read_skill_file_capped` which refuses anything larger than **4 MiB**. Defence against:

- A hostile process planting a 100 MB SKILL.md to OOM the daemon.
- Accidental large files from buggy generators.

The cap is checked via `fs::metadata().len()` before any read, so the 100 MB never enters memory.

## Atomic manifest writes

`update_skill_stats` (called after each execution to bump `use_count`, `last_used`, and `success_rate`) used to do a direct `fs::write`. Two concurrent skill executions could produce a torn write — the second overwrites the first mid-flight. PR 3 stages to a tempfile in the same directory and renames; rename is atomic per POSIX when source and destination are on the same filesystem, which is guaranteed here.

## Logging

Manifest parse failures used to be silent (`serde_json::from_str(...).ok()?`). They now log at `warn!` with the file path so operators can diagnose why a skill disappeared from the registry.

## Operator opt-in (full chain)

To enable auto-generated skill execution, the operator must:

```bash
# 1. Drop the systemd-run sandbox check (only needed if systemd is installed but
#    the binary is at a non-standard location; otherwise PR 3 finds it automatically)

# 2. Enable autoexec for the running daemon
mkdir -p ~/.config/systemd/user/lifeosd.service.d
printf '[Service]\nEnvironment=LIFEOS_SKILLS_AUTOEXEC_ENABLE=1\n' \
  > ~/.config/systemd/user/lifeosd.service.d/70-skills-autoexec.conf
systemctl --user daemon-reload
systemctl --user restart lifeosd

# 3. Approve a specific generated skill after reviewing run.sh
cat ~/.local/share/lifeos/skills/<skill-name>/run.sh    # READ THIS
touch ~/.local/share/lifeos/skills/<skill-name>/approved
```

Each gated execution appears in `journalctl --user -u lifeosd | rg 'skill_gen'` with the skill path, sandbox status, and exit code.

## What this PR does NOT do

- Does not validate the *contents* of a generated `run.sh`. With sandbox + approval, malicious content is contained, but a determined attacker who can also read sandbox-readable files could still exfiltrate them by, say, encoding bytes into exit codes over many invocations. A future PR could add a static analysis pass over generated scripts.
- Does not version-pin the sandbox properties to a particular systemd version. Some properties (`ProtectSystem=strict`) require systemd ≥ 232, which has been the floor on every supported LifeOS host for years.
- Does not propagate sandbox failures distinctly from real skill failures. A `MemoryMax` OOM-kill currently surfaces as a non-zero exit — operators can confirm via `journalctl` and the `MEMORY` line in the scope unit.
