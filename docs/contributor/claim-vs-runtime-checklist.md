# Claim vs Runtime Checklist

Use this before merging or releasing changes that touch docs, update flows, service commands, or public-facing copy.

## Canonical references

- Updates and channels: `docs/architecture/update-channels.md`
- Service runtime model: `docs/architecture/service-runtime.md`
- Public maturity taxonomy: `docs/public/README.md`
- Operator runbooks: `docs/operations/system-admin.md`, `docs/operations/bootc-playbook.md`

## Fast review

1. If you changed update or channel docs, confirm these claims still hold:
   - `bootc status` is the runtime authority on host.
   - The GHCR image digest is the operational release artifact.
   - `channels/*.json` is publication metadata.
   - `lifeos.toml` and `channels.toml` are preference/policy, not proof of what is installed.
   - There is no shipped `life channel set` flow today; explicit channel switches are documented with `bootc switch`.

2. If you changed service docs or troubleshooting text, confirm these commands stay canonical:
   - `lifeosd` -> `systemctl --user ...`
   - `llama-server` -> `sudo systemctl ...`
   - `lifeosd` system scope is legacy/debug only.
   - `llama-server` user scope is fallback only.

3. If you changed public-facing copy, keep claims inside the defined taxonomy:
   - `validated on host`
   - `integrated in repo`
   - `experimental`
   - `shipped disabled / feature-gated`

4. Run the repo guardrail:

```bash
make truth-alignment
```

If `make truth-alignment` fails, fix the mismatch before merge unless you are intentionally changing the canonical model and have updated the source-of-truth docs first.
