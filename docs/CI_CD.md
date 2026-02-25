# LifeOS CI/CD Guide

## Overview

This guide explains the CI/CD pipeline for LifeOS, including how to add new workflows and debug failures.

## Pipeline Architecture

```
┌─────────────┐
│   Trigger   │  PR / Push / Tag / Schedule
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  CI (ci.yml)│  Build → Test → Lint → Security
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ Docker Build│  Build OCI Image → Lint → Push
└──────┬──────┘
       │
       ▼
┌─────────────┐
│   Release   │  Create Release → Binaries → Docs
└─────────────┘
```

## Workflows

### 1. CI Workflow (`.github/workflows/ci.yml`)

**Triggers:**
- Push to `main` or `develop`
- Pull requests to `main` or `develop`

**Jobs:**

| Job | Purpose | Duration |
|-----|---------|----------|
| `build-cli` | Build and test CLI | ~3 min |
| `build-daemon` | Build and test daemon | ~3 min |
| `integration-tests` | Run integration tests | ~2 min |
| `security-audit` | Run cargo audit | ~1 min |
| `coverage` | Generate coverage report | ~5 min |
| `docs` | Build documentation | ~2 min |

### 2. Docker Workflow (`.github/workflows/docker.yml`)

**Triggers:**
- Push to `main`
- Tags matching `v*`
- Changes to `image/**`

**Jobs:**

| Job | Purpose |
|-----|---------|
| `build-image` | Build OCI container with Podman |
| `sign-image` | Sign image with cosign |
| `generate-sbom` | Generate SBOM artifacts |

### 3. Release Workflow (`.github/workflows/release.yml`)

**Triggers:**
- Tags matching `v*`
- Manual workflow dispatch

**Jobs:**

| Job | Purpose |
|-----|---------|
| `create-release` | Create GitHub release draft |
| `build-binaries` | Cross-compile for multiple targets |
| `update-docs` | Deploy docs to GitHub Pages |
| `finalize-release` | Publish release |

### 4. CodeQL Workflow (`.github/workflows/codeql.yml`)

**Triggers:**
- Push to `main` or `develop`
- Weekly schedule (Sundays)

## Local CI Simulation

Test CI workflows locally before pushing:

```bash
# Install act (GitHub Actions local runner)
curl https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash

# Run CI workflow locally
act -j build-cli

# Run all jobs
act
```

## Adding New Workflows

### Step 1: Create Workflow File

Create `.github/workflows/my-workflow.yml`:

```yaml
name: My Workflow

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  my-job:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup Rust
        uses: dtolnay/rust-action@stable
      
      - name: Run my task
        run: echo "Hello, World!"
```

### Step 2: Add to Makefile

```makefile
my-task:
	@echo "Running my task..."
	# Task implementation
```

### Step 3: Test Locally

```bash
act -j my-job
```

### Step 4: Document

Add to this guide with:
- Purpose
- Triggers
- Dependencies

## Debugging CI Failures

### Step 1: Check Logs

1. Go to **Actions** tab in GitHub
2. Click on failed workflow
3. Click on failed job
4. Expand failed step

### Step 2: Reproduce Locally

```bash
# Run the same commands locally
cd cli && cargo build --release
cd daemon && cargo test --all-features
```

### Step 3: Enable Debug Logging

Add to workflow:

```yaml
env:
  ACTIONS_STEP_DEBUG: true
  RUST_BACKTRACE: full
```

### Step 4: Common Issues

#### Cache Corruption

```yaml
# Add cache version to bust corrupted caches
- uses: actions/cache@v4
  with:
    key: ${{ runner.os }}-cargo-v2-${{ hashFiles('**/Cargo.lock') }}
```

#### Missing Dependencies

```yaml
- name: Install system dependencies
  run: |
    sudo apt-get update
    sudo apt-get install -y libdbus-1-dev pkg-config
```

#### Permission Errors

```yaml
- name: Fix permissions
  run: chmod +x target/release/life
```

## Security Scanning

### cargo audit

Checks for known vulnerabilities in dependencies:

```yaml
- name: Run security audit
  run: cargo audit
```

### Trivy

Scans container images:

```yaml
- name: Scan with Trivy
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: 'ghcr.io/user/image:tag'
    format: 'sarif'
    output: 'trivy-results.sarif'
```

### CodeQL

Static analysis for security issues:

```yaml
- name: Initialize CodeQL
  uses: github/codeql-action/init@v3
  with:
    languages: rust
```

## Secrets Management

Required secrets:

| Secret | Purpose | Used In |
|--------|---------|---------|
| `GITHUB_TOKEN` | Provided by GitHub | All workflows |
| `CODECOV_TOKEN` | Upload coverage | ci.yml |
| `CRATES_IO_TOKEN` | Publish to crates.io | release.yml (optional) |

Add secrets:
1. Go to Settings → Secrets → Actions
2. Click "New repository secret"
3. Add name and value

## Artifact Management

Artifacts are retained for 7 days by default:

```yaml
- uses: actions/upload-artifact@v4
  with:
    name: my-artifact
    path: ./output
    retention-days: 7
```

Download artifacts:

```bash
# Using GitHub CLI
gh run download --name my-artifact
```

## Workflow Optimization

### Caching Strategy

```yaml
- uses: actions/cache@v4
  with:
    path: |
      ~/.cargo/bin/
      ~/.cargo/registry/index/
      ~/.cargo/registry/cache/
      ~/.cargo/git/db/
      target/
    key: ${{ runner.os }}-cargo-${{ hashFiles('**/Cargo.lock') }}
    restore-keys: |
      ${{ runner.os }}-cargo-
```

### Parallel Jobs

Run independent jobs in parallel:

```yaml
jobs:
  job-a:
    runs-on: ubuntu-latest
    steps: [...]
  
  job-b:
    runs-on: ubuntu-latest
    steps: [...]
  
  job-c:
    needs: [job-a, job-b]  # Runs after both complete
    runs-on: ubuntu-latest
    steps: [...]
```

### Matrix Builds

Test multiple configurations:

```yaml
strategy:
  matrix:
    rust: [stable, beta, nightly]
    os: [ubuntu-latest, macos-latest]
    exclude:
      - rust: nightly
        os: macos-latest
```

## Container Registry

Images are pushed to GitHub Container Registry (GHCR):

```
ghcr.io/hectormr/lifeos:latest
ghcr.io/hectormr/lifeos:v0.1.0
ghcr.io/hectormr/lifeos:sha-abc123
```

Pull images:

```bash
podman pull ghcr.io/hectormr/lifeos:latest
```

## Release Process

### Automatic Release

1. Push tag: `git tag v0.1.0 && git push origin v0.1.0`
2. Release workflow triggers automatically
3. Binaries built for multiple platforms
4. Release draft created
5. After all jobs pass, release is published

### Manual Release

1. Go to Actions → Release
2. Click "Run workflow"
3. Enter version number
4. Click "Run workflow"

### Post-Release Checklist

- [ ] Release notes are accurate
- [ ] Binaries attached to release
- [ ] Container image pushed
- [ ] Documentation updated
- [ ] Announcement made

## Monitoring

### Workflow Status Badge

Add to README.md:

```markdown
![CI](https://github.com/hectormr/lifeos/workflows/CI/badge.svg)
![Docker](https://github.com/hectormr/lifeos/workflows/Docker/badge.svg)
```

### Notifications

Configure Slack/Discord notifications:

```yaml
- name: Notify on failure
  if: failure()
  uses: 8398a7/action-slack@v3
  with:
    status: ${{ job.status }}
    channel: '#ci-alerts'
```

## Troubleshooting

### Workflow Not Triggering

- Check branch filters in `on:` section
- Verify file paths in `paths:` filters
- Ensure workflow file is valid YAML

### Job Timeout

Increase timeout:

```yaml
jobs:
  long-job:
    timeout-minutes: 60  # Default is 360
```

### Out of Disk Space

Clean up before build:

```yaml
- name: Free disk space
  run: |
    sudo rm -rf /usr/share/dotnet
    sudo rm -rf /opt/ghc
    sudo rm -rf "/usr/local/share/boost"
```

## Contributing

When modifying CI/CD:

1. Test changes in a fork first
2. Use feature branches for testing
3. Document changes in PR description
4. Update this guide if needed
