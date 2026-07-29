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

## Install

    cp systemd/lifeos-backup-host.service ~/.config/systemd/user/
    printf 'LIFEOS_BACKUP_KEY=%s\n' "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
        > backup-host.env
    chmod 600 backup-host.env
    systemctl --user daemon-reload
    systemctl --user enable --now lifeos-backup-host.service

`backup-host.env` is gitignored. The service refuses to start with a key
shorter than 32 characters rather than exposing the store behind a weak one.

## Verify

    # From the VPN — expect 201 then a listing
    curl -X PUT --data-binary @archive.lifeos \
        -H "X-LifeOS-Backup-Key: $KEY" \
        http://10.66.66.1:8099/v1/backups/archive.lifeos

    # From the public interface — expect a refused connection
    curl -m 5 http://<public-ip>:8099/v1/backups

## Tests

Standard library only, so they run anywhere `python3` does — including a VPS
with no project virtualenv:

    python3 -m unittest discover -s tests
