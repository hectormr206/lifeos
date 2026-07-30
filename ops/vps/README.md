# VPS host limits

This box runs production (Coolify services, the OTA host, the backup host) and
development (Claude Code sessions and the builds they launch) on the same 12
cores.

## The problem this fixes

Containers were already capped at 4 CPUs each. Everything on the host side was
not: `user-1001.slice` had `CPUQuota=infinity` and `MemoryMax=infinity`. So
production was bounded and development was not — and it was development that
starved production.

Measured on 2026-07-29: load 27 on 12 cores, with `ollama` at its 4-CPU cap and
unbounded host-side TypeScript builds on top.

## What this does NOT fix

The same day's CI timeouts were attributed to this contention. That was wrong,
and the correction matters more than the original claim.

`mobile-app` runs on the `ci` runner pool — Proxmox and the laptop — neither of
which is this box. This quota bounds work on the VPS: its own `vps`-labelled
runner, the OTA build, Coolify's services. It does nothing for a job that
never executes here.

The Proxmox timeouts have a different cause. That host is a Ryzen 5 5500U, a
low-power mobile part, with 6 physical cores and twelve runner listeners across
nine repositories. Core count and disk throughput were both ruled out (PR #165),
and AES-NI was measured on both machines and ruled out too — Proxmox does 1090
MB/s of AES-256-CBC against the laptop's 1707, hardware-accelerated on both, far
from the 10x a 3-second test needs to cross 30 seconds. What remains is
single-thread performance under runner contention, on the slower of the two
machines.

So this file fixes a real problem — production being starved by development on
the VPS — and is not the fix for the CI timeouts, which PR #165 addressed by
pinning the job to the faster runner.

Development work cannot be "moved into Coolify": Claude Code runs ON this box
by design, so the builds a session launches are host-side by construction. What
is achievable is bounding the host so it cannot hurt production.

## Install

    sudo mkdir -p /etc/systemd/system/user-1001.slice.d
    sudo cp ops/vps/user-slice-limits.conf \
            /etc/systemd/system/user-1001.slice.d/limits.conf
    sudo systemctl daemon-reload

Adjust `user-1001` if the uid differs (`id -u`).

## Verify

    systemctl show user-1001.slice -p CPUQuotaPerSecUSec -p MemoryHigh

`CPUQuotaPerSecUSec=6s` means 600%, i.e. 6 of 12 cores.

To see it bite, start twelve busy loops and total their CPU: without the quota
they take all twelve cores, with it they stay under six.

## Why these limits and not others

`CPUQuota` slows and `MemoryHigh` throttles. Neither kills. An OOM kill
mid-build would trade a slow pipeline for a broken one, and this repository has
already lost a successful twenty-minute release build to a silent failure —
that lesson does not need repeating with a memory limit.

`CPUWeight=50` and `IOWeight=50` additionally put host-side work at half the
default priority, so when the box is busy, containers win.

## Revert

    sudo rm -rf /etc/systemd/system/user-1001.slice.d
    sudo systemctl daemon-reload
