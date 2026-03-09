# NVIDIA + Secure Boot on LifeOS (bootc image-mode)

This document captures the production flow to keep NVIDIA working **with Secure Boot enabled** on LifeOS.

## Why this is required

On bootc/image-mode hosts, `/usr` is read-only. Runtime `akmods` builds can fail to install kernel modules, and unsigned modules are rejected when Secure Boot is enabled (`modprobe: Key was rejected by service`).

## Build-time requirements (ISO and release channels)

LifeOS image builds now support signing NVIDIA kernel modules at build time with two build args:

- `LIFEOS_NVIDIA_KMOD_SIGN_KEY_B64`: Base64-encoded PEM private key.
- `LIFEOS_NVIDIA_KMOD_CERT_DER_B64`: Base64-encoded DER public cert.

These are wired in:

- `.github/workflows/release-channels.yml`
- `.github/workflows/docker.yml`
- `scripts/build-iso.sh`
- `scripts/generate-iso-simple.sh`

Local builds can continue without these args (with warnings), but release publishing workflows now fail fast if secrets are missing to avoid shipping unsigned NVIDIA modules.
When secrets are provided, image builds now fail if NVIDIA modules cannot be signed/verified.

## GitHub secrets to configure

Set these repository secrets:

- `LIFEOS_NVIDIA_KMOD_SIGN_KEY_B64`
- `LIFEOS_NVIDIA_KMOD_CERT_DER_B64`

Recommended: keep one long-lived signing keypair for LifeOS NVIDIA modules, and rotate with a planned migration window.

## Host onboarding (one-time per machine)

After installing/updating to an image signed with your LifeOS NVIDIA cert:

```bash
sudo lifeos-nvidia-secureboot.sh status
sudo lifeos-nvidia-secureboot.sh enroll
sudo reboot
```

During reboot, enroll the key in MOK Manager:

1. `Enroll MOK`
2. `Continue`
3. `Yes`
4. Enter the one-time password you set during `mokutil --import`

After boot:

```bash
sudo modprobe nvidia
nvidia-smi
```

## Update flow for private GHCR

Use the robust helper script from repo root:

```bash
sudo ./scripts/update-lifeos.sh --channel edge --login-user <github_user> --switch --apply --yes
```

The script now prefers switching from local `containers-storage` when possible, avoiding common `bootc switch ghcr.io/...` auth failures on private registries.

## Fast diagnostics

```bash
sudo lifeos-nvidia-secureboot.sh status
sudo bootc status
life status
```

If `nvidia.ko signer` is empty, the image was built without module signing and must be rebuilt with signing secrets.
If `LifeOS MOK cert` is missing, the image did not include signing cert material and `enroll` cannot fix it; pull/update to a signed image build first.
