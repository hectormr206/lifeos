# Threat model — Axi at-rest encryption (T1)

Scope: how LifeOS/Axi protects personal data on disk, what that protection
covers, and — just as important — what it deliberately does **not** cover. This
is the deliverable accompanying T1 (encrypted assistant memory).

## Assets

| Asset | Location | Sensitivity |
|-------|----------|-------------|
| Assistant memory (conversations, knowledge graph, meetings) | `~/.local/state/axi/memory.db` | High — verbatim of what the user says and asks |
| Life-companion data (health, finance, reminders, …) | `~/.local/state/lifeos/lifeos.db` | High — health and financial records |
| Encryption keys | `~/.local/state/axi/memory.key`, `~/.local/state/lifeos/lifeos.key` | Critical — unlock the above |

## Trust boundary

LifeOS is single-user and single-machine. The trust boundary is the user's own
account on their own device. All services bind to `127.0.0.1`; inference is local;
no data is sent off-device. There is no multi-tenancy, no remote API, and no cloud
component to attack.

## What is protected

Both data stores are encrypted at rest with **SQLCipher** (AES-256). Each store
has a 32-byte random key, generated on first run and stored `0600`
(owner-read/write only). This defends against the realistic offline threats for a
personal laptop:

- **Lost or stolen device / disk** — the `.db` files are ciphertext; without the
  key files they cannot be read. (Pair with full-disk encryption for the strongest
  posture — see limitations.)
- **Backups and file sync** — if a `.db` is copied into a backup, cloud-synced
  folder, or shared volume *without* the matching `.key`, it leaks nothing.
- **Casual access by another local account** — other non-root users cannot read
  the `0600` key or the encrypted DB.
- **Accidental exposure** — a `.db` attached to a bug report or pasted somewhere is
  inert on its own.

## What is NOT protected (by design, stated honestly)

- **A compromised live user session.** The key lives in the user's home directory
  next to the data, so any code running *as the user* (or as root) can read the key
  and therefore the data. At-rest encryption protects data *at rest*, not a live,
  unlocked account. Defense in depth here is the OS account itself.
- **Memory / runtime.** While a store is open, plaintext is in process memory and
  the decrypted pages are in the OS page cache. An attacker who can read the live
  process or RAM is out of scope.
- **Root / kernel adversary** on the running machine.
- **The dashboard has no authentication or TLS.** This is acceptable *only*
  because it binds to loopback. If the user opts to expose it (e.g. over a VPN),
  they accept that risk explicitly; it is documented and off by default.
- **Key management is single-key, no rotation, no passphrase.** Rotation requires
  re-encrypting and a restart. There is no user passphrase gating the key (that
  would trade convenience for protection against the live-session threat above —
  a candidate future option, not in T1).

## Migration safety

Upgrading an existing plaintext DB to encrypted is designed to be loss-free:

1. The plaintext DB is detected (it reads as standard SQLite).
2. An encrypted copy is built in a temp file via SQLCipher's `sqlcipher_export`
   (full schema + data + FTS indexes), then verified to open with the key.
3. Only then is the plaintext **backed up** (`*.pre-encrypt.<UTC>.bak`) and the
   encrypted copy swapped in atomically.
4. Any failure leaves the original untouched and aborts.

The backup is intentionally left in place after migration. **Operational note:**
that backup is plaintext — delete it (or move it to encrypted storage) once the
migration is confirmed, or it defeats the encryption for that snapshot.

## Residual risks / future work

- Encrypt or auto-purge the post-migration plaintext backup.
- Optional passphrase-derived key (argon2) to protect against the live-session
  threat, at the cost of an unlock step.
- Zeroize key material in memory after use where the runtime allows it.
