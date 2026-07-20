"""Minimal owner CLI to initialise a mesh and admit (enroll) nodes.

The owner passphrase is the root of trust (:mod:`axi.mesh_trust`); admitting a
node means signing a membership cert with the root key, which requires the
passphrase. This CLI is the human seam for that:

    # First time on the first node — create the mesh root of trust:
    python -m axi.mesh_enroll --init

    # Admit another node (paste its public key hex; prints the cert token):
    python -m axi.mesh_enroll --node-pubkey <hex>

The passphrase is read with :func:`getpass.getpass` ONLY — never taken from
argv, never echoed, never logged. ``--init`` asks twice and aborts on mismatch
so a typo can't lock the owner out. Kept deliberately small.
"""
from __future__ import annotations

import argparse
import getpass
import sys
from typing import Callable

from axi import mesh_trust


def _run(
    args: argparse.Namespace,
    *,
    prompt: Callable[..., str],
    out: Callable[[str], None],
) -> int:
    base_dir = args.base_dir

    if args.init:
        p1 = prompt("Owner passphrase (new mesh root of trust): ")
        p2 = prompt("Confirm passphrase: ")
        if not p1:
            print("error: passphrase must be non-empty", file=sys.stderr)
            return 2
        if p1 != p2:
            print("error: passphrases do not match; aborted", file=sys.stderr)
            return 2
        try:
            info = mesh_trust.init_mesh(p1, base_dir=base_dir)
        except mesh_trust.MeshTrustError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        out(f"mesh initialized")
        out(f"mesh_id: {info['mesh_id']}")
        out(f"root_pubkey: {info['root_pubkey']}")
        return 0

    # Enrollment path.
    passphrase = prompt("Owner passphrase: ")
    try:
        token = mesh_trust.enroll_node(
            args.node_pubkey, passphrase,
            base_dir=base_dir, ttl_seconds=args.ttl_seconds,
        )
    except mesh_trust.WrongPassphrase:
        print("error: wrong passphrase", file=sys.stderr)
        return 1
    except mesh_trust.MeshNotInitialized:
        print("error: no mesh on this node; run --init first", file=sys.stderr)
        return 1
    except mesh_trust.MeshTrustError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    out(token)
    return 0


def main(
    argv: list[str] | None = None,
    *,
    prompt: Callable[..., str] = getpass.getpass,
    out: Callable[[str], None] = print,
) -> int:
    """Parse args and run. ``prompt``/``out`` are injectable for testing."""
    parser = argparse.ArgumentParser(
        prog="python -m axi.mesh_enroll",
        description="Initialise the mesh root of trust, or enroll a node.",
    )
    parser.add_argument(
        "--init", action="store_true",
        help="create the mesh root of trust (prompts for a new owner passphrase)",
    )
    parser.add_argument(
        "--node-pubkey", metavar="HEX",
        help="Ed25519 node public key (hex) to enroll; prints the cert token",
    )
    parser.add_argument(
        "--ttl-seconds", type=int, default=mesh_trust._DEFAULT_TTL_SECONDS,
        help="membership cert lifetime in seconds (default: 1 year)",
    )
    parser.add_argument(
        "--base-dir", default=None,
        help="key-material base dir (default: $XDG_STATE_HOME/axi); for testing",
    )
    args = parser.parse_args(argv)

    if not args.init and not args.node_pubkey:
        parser.error("one of --init or --node-pubkey is required")

    return _run(args, prompt=prompt, out=out)


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
