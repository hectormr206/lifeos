# LifeOS CI/CD Pipeline Architecture

## Overview

This document describes the CI/CD pipeline architecture for LifeOS, including build, test, security scanning, and release workflows.

## Pipeline Structure

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Trigger   │────▶│    Build    │────▶│    Test     │
│  (PR/Push)  │     │             │     │             │
└─────────────┘     └─────────────┘     └──────┬──────┘
                                               │
                          ┌────────────────────┼────────────────────┐
                          ▼                    ▼                    ▼
                   ┌─────────────┐      ┌─────────────┐     ┌─────────────┐
                   │    Lint     │      │   Security  │     │   Docker    │
                   │  (Clippy)   │      │    Scan     │     │    Build    │
                   └─────────────┘      └─────────────┘     └──────┬──────┘
                                                                    │
                                                                    ▼
                                                             ┌─────────────┐
                                                             │  Registry   │
                                                             │   Push      │
                                                             └─────────────┘
```

## Workflows

### 1. CI Workflow (`ci.yml`)

**Triggers:** PR, push to main/develop

**Jobs:**
1. **Build CLI** - Compile CLI in release mode
2. **Build Daemon** - Compile daemon with all features
3. **Run Tests** - Execute unit and integration tests
4. **Lint Check** - Run rustfmt and clippy
5. **Security Audit** - Run cargo audit

### 2. Docker Workflow (`docker.yml`)

**Triggers:** Push to main, manual dispatch

**Jobs:**
1. **Build Image** - Build OCI image with Podman
2. **Lint Image** - Run bootc container lint
3. **Push to Registry** - Push to GHCR
4. **Sign Image** - Sign with cosign

### 3. Release Workflow (`release.yml`)

**Triggers:** Tag push (v*), manual dispatch

**Jobs:**
1. **Create Release** - Generate GitHub release
2. **Build Binaries** - Cross-compile for multiple targets
3. **Generate Changelog** - Auto-generate from commits
4. **Update Docs** - Deploy documentation

## Security Scanning

| Tool | Purpose | Stage |
|------|---------|-------|
| cargo audit | Dependency vulnerabilities | CI |
| Trivy | Container image scanning | Docker |
| CodeQL | Static analysis | CI (weekly) |
| cosign | Image signing | Docker |

## Artifact Management

- Binaries: GitHub Releases
- Container images: GHCR (ghcr.io/hectormr/lifeos)
- Documentation: GitHub Pages

## Quality Gates

- All tests must pass
- No clippy warnings
- No critical/high vulnerabilities
- Code coverage ≥ 70%
