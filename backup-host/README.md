# backup-host

Stores passphrase-sealed LifeOS backups on the VPS, reachable only over the
WireGuard network.

## What it is not

It never decrypts anything and holds no key that could. The phone seals each
archive under a key derived from the user's passphrase before uploading
(`mobile/lib/core/security/passphrase_backup_sealer.dart`), so this service —
and anyone who reads its disk — sees opaque bytes. Losing the server does not
expose the data; losing the passphrase does, permanently, by design.

## Why not the OTA host

`updates.lifeos.<domain>` is public, behind Cloudflare, gated by a static
header. That is right for signed APKs, which are public artefacts anyway.
Personal data takes the private path instead: this binds to the WireGuard
address, so the traffic never leaves the VPN even though the payload could
survive doing so. Defence in depth, and it keeps the product's promise
literally true rather than merely cryptographically true.

## Endpoints

All require `X-LifeOS-Backup-Key`; anything else is `401`.

| Method | Path | Result |
| --- | --- | --- |
| `PUT` | `/v1/backups/<name>` | `201` — stores (replaces) the archive |
| `GET` | `/v1/backups` | `200` — `{"backups":[{name,sizeBytes,modifiedAt}]}` |
| `GET` | `/v1/backups/<name>` | `200` bytes, or `404` |

Names must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`. Uploads are written to a
temporary file and `os.replace`d into position, so a reader never sees a
half-uploaded archive and a failed upload leaves nothing that could later be
restored as if it were whole.

## Diagnostics

Three rungs, so a setup screen can say WHICH step is broken rather than just
"failed":

| Method | Path | Auth | Answers |
| --- | --- | --- | --- |
| `GET` | `/v1/health` | no | "is a LifeOS backup host here?" — tells a wrong address from a wrong key |
| `GET` | `/v1/status` | yes | `{writable, backups, freeBytes, maxUploadBytes}` — reachable and authorised is still not usable |

`writable` is probed by actually writing a temporary file. Checking permission
bits would answer a different question: a full disk, a read-only remount, or a
volume mounted `ro` all pass a permission check and still lose the backup.

`/v1/health` is deliberately empty of everything else — it reveals nothing
about what is stored beyond what an open TCP port already reveals.

## Run it

It ships as a container; see [SELF-HOSTING.md](SELF-HOSTING.md) for the full
walkthrough. In short:

    printf 'LIFEOS_BACKUP_KEY=%s\n' "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" > .env
    echo 'LIFEOS_BACKUP_BIND=10.66.66.1' >> .env   # your private address
    docker compose up -d

Capped at 0.5 CPU / 256 MB, read-only root filesystem, all capabilities
dropped, running as an unprivileged user.

Nothing is installed on the host: the same image users deploy on their own
servers is the one that runs here.

## Tests

Standard library only, so they run anywhere `python3` does — including a VPS
with no project virtualenv:

    python3 -m unittest discover -s tests
