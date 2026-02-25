# LifeOS Test Results & Development Plan

## Step 1: Docker Image Test Results ✅

### Container Details
| Component | Status | Details |
|-----------|--------|---------|
| Base OS | ✅ Fedora Linux 42 (Adams) | `fedora-bootc:42` base |
| GNOME Desktop | ✅ Installed | `@gnome-desktop` package group |
| GNOME Shell | ✅ Present | `/usr/bin/gnome-shell` exists |
| GDM | ✅ Installed | `/usr/sbin/gdm` exists |
| Systemd | ✅ Working | Symlinks: `/sbin/init` → `../lib/systemd/systemd` |
| Systemctl | ✅ Present | `/bin/systemctl` available |
| bootc binary | ✅ Present | `/usr/bin/bootc` (10MB) |
| OSTree | ✅ Setup | `/ostree` → `sysroot/ostree` |
| bootc lint | ✅ Passed | Container lint passed during build |

### Missing Components ⚠️
| Component | Status | Notes |
|-----------|--------|-------|
| Ollama | ❌ Not installed | Placeholder script at `/usr/local/bin/ollama-install.sh` |
| LifeOS CLI | ❌ Placeholder only | `/usr/local/bin/life` is bash stub |
| LifeOS data dir | ❌ Not created | `/var/lib/lifeos` doesn't exist |

### Image Size
- **Total**: 6.8GB (compressed)
- **Base**: Fedora bootc + GNOME desktop + system tools

---

## Step 2: ISO Generation Status ⚠️ BLOCKED

### Attempted Approaches

#### Attempt 1: Direct bootc-image-builder with Docker storage
```bash
docker run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v ./output:/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type iso --local lifeos:dev
```
**Result**: ❌ Failed - bootc-image-builder expects Podman storage at `/var/lib/containers/storage/overlay`

#### Attempt 2: Local Registry + Podman (IN PROGRESS)
1. ✅ Started local registry at `localhost:5000`
2. ✅ Pushed `lifeos:dev` to local registry
3. ✅ Installed Podman 4.9.3
4. ✅ Configured insecure registry access
5. 🔄 Pulling image into Podman storage (6.8GB - taking significant time)

### Current Blocker
**Podman image pull is slow** - The 6.8GB image is being copied from Docker registry to Podman storage layer by layer. This is a one-time setup operation.

### Resolution Path
Once Podman pull completes:
```bash
# Generate ISO with bootc-image-builder
docker run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v ./output:/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type iso localhost:5000/lifeos:dev
```

### Alternative Quick-Start for Development
Skip ISO generation for now and test directly:
```bash
# Test bootable container directly
docker run --rm --privileged --entrypoint /sbin/init lifeos:dev

# Or use podman for local testing
podman run --rm --privileged --entrypoint /sbin/init lifeos:dev
```

---

## Step 3: Next Development Sprint Plan

### Sprint Goal
Create a functional LifeOS CLI with Ollama integration and basic configuration system.

### Phase 1: Foundation (Week 1)

#### 1.1 CLI Architecture Setup
```
cli/
├── src/
│   ├── main.rs          # Entry point
│   ├── commands/        # Subcommand modules
│   │   ├── mod.rs
│   │   ├── init.rs      # System initialization
│   │   ├── config.rs    # Configuration management
│   │   ├── ai.rs        # Ollama integration
│   │   └── status.rs    # System status
│   ├── core/
│   │   ├── mod.rs
│   │   ├── config.rs    # Config struct & persistence
│   │   ├── systemd.rs   # systemd service management
│   │   └── ollama.rs    # Ollama client
│   └── lib.rs
├── Cargo.toml
└── tests/
```

#### 1.2 Core CLI Commands
| Command | Purpose | Priority |
|---------|---------|----------|
| `life init` | Initialize LifeOS system | P0 |
| `life config` | View/edit configuration | P0 |
| `life ai start` | Start Ollama service | P0 |
| `life ai status` | Check Ollama status | P0 |
| `life status` | Show system health | P1 |
| `life update` | Update system image | P1 |

#### 1.3 Configuration System
```yaml
# /etc/lifeos/config.yaml
version: "1.0"
system:
  hostname_template: "lifeos-{uuid}"
  auto_update: true
  timezone: "auto-detect"
ai:
  ollama:
    enabled: true
    models: ["llama3.2", "codellama"]
    gpu_acceleration: auto
    port: 11434
desktop:
  environment: "gnome"
  auto_login: false
  initial_setup: true
user:
  default_shell: "fish"
  dotfiles_repo: null
```

### Phase 2: Ollama Integration (Week 1-2)

#### 2.1 Ollama Installation
- Detect GPU (NVIDIA/AMD/Intel/CPU-only)
- Install appropriate Ollama version
- Configure systemd service
- Auto-start on boot (optional)

#### 2.2 Model Management
```bash
life ai pull <model>      # Download model
life ai list              # List installed models
life ai rm <model>        # Remove model
life ai run <model>       # Interactive chat
```

#### 2.3 Integration Points
- GNOME extension for quick AI access
- System tray indicator
- Keyboard shortcut (Super+Space)

### Phase 3: System Integration (Week 2)

#### 3.1 systemd Services
- `lifeos-init.service`: First-boot initialization
- `lifeos-ollama.service`: AI runtime management
- `lifeos-update.timer`: Automatic updates

#### 3.2 First-Boot Experience
1. Language selection
2. User creation
3. WiFi setup
4. AI model selection (optional)
5. Dotfiles clone (optional)

#### 3.3 Containerfile Updates
```dockerfile
# Replace placeholder CLI
COPY --from=ctx /ctx/files/usr/local/bin/life /usr/local/bin/life
RUN chmod +x /usr/local/bin/life

# Add lifeos user and data directory
RUN mkdir -p /var/lib/lifeos /etc/lifeos \
    && touch /etc/lifeos/config.yaml

# Enable first-boot service
RUN systemctl enable lifeos-init.service
```

### Phase 4: Testing & Polish (Week 3)

#### 4.1 Testing Framework
```bash
# Unit tests
cargo test

# Integration tests
./tests/integration/run.sh

# Container tests
docker build -f image/Containerfile -t lifeos:test .
docker run --rm lifeos:test life --version
```

#### 4.2 CI/CD Updates
- Build CLI in GitHub Actions
- Run tests on PR
- Build and push image on main
- Generate ISO artifacts

---

## Immediate Next Actions

### Action 1: Fix ISO Generation
```bash
# Install Podman for bootc-image-builder compatibility
sudo apt-get install -y podman

# Or use alternative approach with local registry
docker run -d -p 5000:5000 --name registry registry:2
docker tag lifeos:dev localhost:5000/lifeos:dev
docker push localhost:5000/lifeos:dev

# Then use with bootc-image-builder
docker run --rm --privileged \
  -v ./output:/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type iso \
  localhost:5000/lifeos:dev
```

### Action 2: Start CLI Implementation
```bash
cd /home/hectormr/.openclaw/workspace-orchestra/projects/lifeos/cli
cargo init --name life

# Add dependencies
cargo add clap -F derive
cargo add serde serde_yaml
cargo add reqwest -F json
cargo add tokio -F full
cargo add anyhow
cargo add tracing tracing-subscriber
```

### Action 3: Create Initial Config System
```bash
mkdir -p cli/src/core cli/src/commands
# Create config.rs, main.rs, commands/*.rs
```

---

## Success Criteria

- [ ] ISO successfully generated and bootable
- [ ] CLI binary builds and runs
- [ ] `life init` completes without errors
- [ ] Ollama installs and starts on first boot
- [ ] Configuration persists across reboots
- [ ] All tests pass in CI

---

## Risk Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| GPU detection fails | High | Fallback to CPU-only Ollama |
| Large image size | Medium | Investigate multi-stage builds |
| bootc compatibility | Medium | Test with Podman, document workarounds |
| First-boot failures | High | Add rollback mechanism |

---

*Generated: 2026-02-24*
*Next Review: After ISO generation complete*
