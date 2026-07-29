# Host your own LifeOS backups

Your phone keeps everything locally and encrypted. That protects your data —
but it does not protect you from losing the phone. This guide gives you a
second copy, on a machine you control, without anyone (including whoever runs
that machine) being able to read it.

**Time:** about ten minutes. **You need:** a server you can run Docker on, and
a private network between it and your phone (WireGuard, Tailscale, or a home
LAN).

---

## What you are setting up

```
  Phone                          Your server
  ─────                          ───────────
  graph.db  ──seal with your──►  backup-host  ──►  /data
            your passphrase          (this)        (opaque bytes)
```

Your phone encrypts the backup **before** it leaves, using a key derived from
a passphrase only you know. The server stores the result and can never open
it. That is what makes this safe to run anywhere.

Two consequences, both deliberate:

- Someone who steals the server gets nothing readable.
- **If you forget the passphrase, the backup is gone.** There is no reset,
  no recovery link, nobody to ask. Write it down and keep it somewhere safe.

---

## Step 1 — Get the files

```bash
git clone https://github.com/hectormr206/lifeos.git
cd lifeos/backup-host
```

## Step 2 — Generate an access key

This key is what stops strangers on your network from uploading to your store.
It is *not* what encrypts your data — your passphrase does that.

```bash
printf 'LIFEOS_BACKUP_KEY=%s\n' \
  "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" > .env
chmod 600 .env
cat .env    # copy this value, the app will ask for it
```

The service refuses to start with a key shorter than 32 characters.

## Step 3 — Choose what address it listens on

This is the most important decision here, so take a moment.

Find your server's private address — the one your phone reaches it on:

```bash
ip -brief addr    # look for wg0, tailscale0, or your LAN interface
```

Add it to `.env`:

```bash
echo 'LIFEOS_BACKUP_BIND=10.66.66.1' >> .env    # ← your private address
```

> **Do not put `0.0.0.0` here.** That publishes your backups to the whole
> internet behind a single header. The default is `127.0.0.1`, which is safe
> but only reachable from the server itself.

## Step 4 — Start it

```bash
docker compose up -d
docker compose ps        # should show "healthy" within ~30s
```

Check it from the server:

```bash
curl http://127.0.0.1:8099/v1/health
# {"service": "lifeos-backup-host", "version": 1}
```

## Step 5 — Connect the app

In LifeOS: **Settings → Backups → Server**.

| Field | Value |
| --- | --- |
| Address | `http://10.66.66.1:8099` (your private address) |
| Access key | the value from `.env` |

Tap **Check connection**. The app tests three things in order and tells you
which one failed:

| Result | Meaning | Fix |
| --- | --- | --- |
| Cannot reach the server | Wrong address, or the VPN is down | Confirm the phone is on the VPN; check `LIFEOS_BACKUP_BIND` |
| Reached, key rejected | Address is right, key is wrong | Re-copy the key from `.env` — no spaces, no line break |
| Reached, store not writable | Volume is read-only or the disk is full | `docker compose logs`; check free space |
| Ready | Everything works | — |

---

## Resource use

The container is capped at **0.5 CPU and 256 MB RAM**, with a read-only root
filesystem and all Linux capabilities dropped. It parses small HTTP requests
and copies bytes to disk — no database, no cache, no background work — so
these limits are generous rather than tight. Idle cost is close to nothing.

Storage is what actually grows: each backup is roughly the size of your graph.
Keep an eye on the volume, and delete old archives you no longer want.

## Behind a reverse proxy (optional)

If you would rather reach it over HTTPS on a domain than over a VPN, set
`LIFEOS_BACKUP_BIND=127.0.0.1` and point your proxy at `127.0.0.1:8099`.

Understand the trade-off before you do: a public endpoint can be probed by
anyone who finds it, and the access key becomes the only thing between them
and your upload store. Your backups stay unreadable either way — the seal
does not depend on the transport — but a VPN keeps them from being *reachable*
in the first place. Prefer the VPN.

## Updating

```bash
git pull
docker compose up -d --build
```

Your `/data` volume is untouched by rebuilds.

## Backing up the backups

The archives are already encrypted, so you can copy `/data` anywhere — another
disk, an object store, a friend's server — without exposing anything:

```bash
docker run --rm -v backup-host_backups:/data:ro -v "$PWD":/out alpine \
  tar czf /out/lifeos-backups.tar.gz -C /data .
```

That copy is as safe as your passphrase. Which is the whole point.
