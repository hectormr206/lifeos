# LifeOS Makefile
# Build automation for CLI, Daemon, and Container Image

.PHONY: all build build-cli build-daemon test test-cli test-daemon test-integration \
        lint lint-cli lint-daemon fmt fmt-check audit audit-cli audit-daemon \
        docker docker-build docker-lint docker-push clean install dev-setup help \
        check-daemon-prereqs phase3-hardening

# =============================================================================
# Default Target
# =============================================================================

all: build

# =============================================================================
# Build Targets
# =============================================================================

## Build all components (CLI and Daemon)
build: build-cli build-daemon

## Build CLI in release mode
build-cli:
	@echo "🔨 Building CLI..."
	cd cli && cargo build --release

## Build Daemon in release mode with all features
build-daemon:
	@echo "🔨 Building Daemon..."
	cd daemon && cargo build --release --all-features

## Build both in debug mode
debug:
	@echo "🔨 Building in debug mode..."
	cd cli && cargo build
	cd daemon && cargo build --all-features

# =============================================================================
# Test Targets
# =============================================================================

## Run all tests
test: test-cli test-daemon test-integration

## Run CLI tests
test-cli:
	@echo "🧪 Running CLI tests..."
	cd cli && cargo test --all-features

## Run Daemon tests
test-daemon:
	@echo "🧪 Running Daemon tests..."
	cd daemon && cargo test --all-features

## Run integration tests
test-integration:
	@echo "🧪 Running integration tests..."
	@if [ -f tests/Cargo.toml ]; then \
		cd tests && cargo test --test integration_tests; \
	else \
		echo "No tests/Cargo.toml found"; \
	fi

## Verify prerequisites to build daemon with all features
check-daemon-prereqs:
	@echo "🔍 Checking daemon build prerequisites..."
	bash scripts/check-daemon-prereqs.sh

## Run Phase 3 hardening verification flow (fmt + clippy + tests)
phase3-hardening:
	@echo "🛡️  Running Phase 3 hardening checks..."
	bash scripts/phase3-hardening-checks.sh

## Run all tests with coverage
test-coverage:
	@echo "📊 Running tests with coverage..."
	cd cli && cargo tarpaulin --out Html --output-dir ./coverage
	cd daemon && cargo tarpaulin --out Html --output-dir ./coverage

# =============================================================================
# Lint and Format Targets
# =============================================================================

## Run all linting checks
lint: fmt-check lint-cli lint-daemon

## Run clippy on CLI
lint-cli:
	@echo "🔍 Running clippy on CLI..."
	cd cli && cargo clippy --all-features -- -D warnings

## Run clippy on Daemon
lint-daemon:
	@echo "🔍 Running clippy on Daemon..."
	cd daemon && cargo clippy --all-features -- -D warnings

## Format all code
fmt:
	@echo "📝 Formatting code..."
	cd cli && cargo fmt
	cd daemon && cargo fmt

## Check formatting without making changes
fmt-check:
	@echo "📝 Checking code formatting..."
	cd cli && cargo fmt -- --check
	cd daemon && cargo fmt -- --check

# =============================================================================
# Security Audit Targets
# =============================================================================

## Run security audit on all components
audit: audit-cli audit-daemon

## Run cargo audit on CLI
audit-cli:
	@echo "🔒 Auditing CLI dependencies..."
	cd cli && cargo audit

## Run cargo audit on Daemon
audit-daemon:
	@echo "🔒 Auditing Daemon dependencies..."
	cd daemon && cargo audit

# =============================================================================
# Docker/Container Targets
# =============================================================================

## Build OCI container image
docker: docker-build docker-lint

docker-build:
	@echo "🐳 Building container image..."
	@BUILD_DATE="$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	VCS_REF="$$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"; \
	podman build \
		--build-arg "BUILD_DATE=$$BUILD_DATE" \
		--build-arg "VCS_REF=$$VCS_REF" \
		-t lifeos:dev \
		-f image/Containerfile \
		.

docker-lint:
	@echo "🔍 Linting container image..."
	podman run --rm lifeos:dev bootc container lint || true

docker-push:
	@echo "📤 Pushing container image..."
	podman push lifeos:dev ghcr.io/hectormr/lifeos:latest

# =============================================================================
# Development Targets
# =============================================================================

## Set up development environment
dev-setup:
	@echo "⚙️  Setting up development environment..."
	rustup component add rustfmt clippy
	cargo install cargo-audit --locked
	cargo install cargo-tarpaulin --locked
	pre-commit install
	@echo "✅ Development environment ready!"

## Install CLI locally (requires cargo)
install:
	@echo "📦 Installing life CLI..."
	cd cli && cargo install --path .

## Run CLI in development mode
run-cli:
	cd cli && cargo run --

## Run Daemon in development mode
run-daemon:
	cd daemon && cargo run --all-features

## Watch for changes and rebuild (requires cargo-watch)
watch:
	@echo "👀 Watching for changes..."
	cd cli && cargo watch -x 'build --release'

# =============================================================================
# Documentation Targets
# =============================================================================

docs:
	@echo "📚 Building documentation..."
	cd cli && cargo doc --no-deps --open
	cd daemon && cargo doc --no-deps

docs-serve:
	@echo "🌐 Serving documentation..."
	cd cli && cargo doc --no-deps
	python3 -m http.server 8000 --directory target/doc/

# =============================================================================
# Clean Targets
# =============================================================================

## Clean build artifacts
clean:
	@echo "🧹 Cleaning build artifacts..."
	cd cli && cargo clean
	cd daemon && cargo clean
	rm -rf target/
	find . -type d -name "coverage" -exec rm -rf {} + 2>/dev/null || true

## Deep clean (includes registry cache)
clean-all: clean
	@echo "🧹 Deep cleaning (including caches)..."
	rm -rf ~/.cargo/registry/cache/
	rm -rf ~/.cargo/git/db/

# =============================================================================
# Axi Visual Assets
# =============================================================================

## Export Axi SVGs to PNGs (requires Inkscape or rsvg-convert)
axi-pngs:
	@echo "🎨 Exporting Axi PNGs from SVGs..."
	@SVG_DIR="image/files/usr/share/icons/LifeOS/axi/svg"; \
	PNG_512="image/files/usr/share/icons/LifeOS/axi/png/512"; \
	PNG_64="image/files/usr/share/icons/LifeOS/axi/png/64"; \
	PNG_32="image/files/usr/share/icons/LifeOS/axi/png/32"; \
	NOTIF="image/files/usr/share/icons/LifeOS/axi/notification"; \
	if command -v inkscape >/dev/null 2>&1; then \
		for svg in $$SVG_DIR/*.svg; do \
			name=$$(basename "$$svg" .svg); \
			echo "  Exporting $$name..."; \
			inkscape "$$svg" --export-type="png" --export-filename="$$PNG_512/$${name}.png" -w 512 -h 512 2>/dev/null || true; \
			inkscape "$$svg" --export-type="png" --export-filename="$$PNG_64/$${name}.png" -w 64 -h 64 2>/dev/null || true; \
			inkscape "$$svg" --export-type="png" --export-filename="$$PNG_32/$${name}.png" -w 32 -h 32 2>/dev/null || true; \
		done; \
		echo "✅ PNGs exported successfully with Inkscape"; \
	elif command -v rsvg-convert >/dev/null 2>&1; then \
		for svg in $$SVG_DIR/*.svg; do \
			name=$$(basename "$$svg" .svg); \
			echo "  Exporting $$name..."; \
			rsvg-convert -w 512 -h 512 "$$svg" > "$$PNG_512/$${name}.png"; \
			rsvg-convert -w 64 -h 64 "$$svg" > "$$PNG_64/$${name}.png"; \
			rsvg-convert -w 32 -h 32 "$$svg" > "$$PNG_32/$${name}.png"; \
		done; \
		echo "✅ PNGs exported successfully with rsvg-convert"; \
	else \
		echo "⚠️  Neither Inkscape nor rsvg-convert found. Install one of:"; \
		echo "    - Inkscape: dnf install inkscape"; \
		echo "    - librsvg2-tools: dnf install librsvg2-tools"; \
	fi

## Create ICO from PNGs (requires ImageMagick)
axi-ico:
	@echo "🖼️  Creating ICO files from PNGs..."
	@PNG_32="image/files/usr/share/icons/LifeOS/axi/png/32"; \
	if command -v convert >/dev/null 2>&1; then \
		for png in $$PNG_32/*.png; do \
			name=$$(basename "$$png" .png); \
			convert "$$png" "$${PNG_32%/*}/../$${name}.ico" 2>/dev/null || true; \
		done; \
		echo "✅ ICO files created"; \
	else \
		echo "⚠️  ImageMagick not found. Install with: dnf install ImageMagick"; \
	fi

# =============================================================================
# CI Targets (for GitHub Actions)
# =============================================================================

ci: fmt-check lint test audit
	@echo "✅ CI checks passed!"

# =============================================================================
# Help Target
# =============================================================================

## Show this help message
help:
	@echo "LifeOS Makefile"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Build Targets:"
	@echo "  build        Build all components (CLI and Daemon)"
	@echo "  build-cli    Build CLI in release mode"
	@echo "  build-daemon Build Daemon in release mode with all features"
	@echo "  debug        Build both in debug mode"
	@echo ""
	@echo "Test Targets:"
	@echo "  test           Run all tests"
	@echo "  test-cli       Run CLI tests"
	@echo "  test-daemon    Run Daemon tests"
	@echo "  test-integration Run integration tests"
	@echo "  check-daemon-prereqs Verify daemon --all-features prerequisites"
	@echo "  phase3-hardening Run deterministic hardening checks"
	@echo "  test-coverage  Run tests with coverage report"
	@echo ""
	@echo "Lint Targets:"
	@echo "  lint         Run all linting checks"
	@echo "  lint-cli     Run clippy on CLI"
	@echo "  lint-daemon  Run clippy on Daemon"
	@echo "  fmt          Format all code"
	@echo "  fmt-check    Check formatting without making changes"
	@echo ""
	@echo "Security Targets:"
	@echo "  audit        Run security audit on all components"
	@echo "  audit-cli    Run cargo audit on CLI"
	@echo "  audit-daemon Run cargo audit on Daemon"
	@echo ""
	@echo "Docker Targets:"
	@echo "  docker       Build OCI container image"
	@echo "  docker-build Build container image"
	@echo "  docker-lint  Lint container image"
	@echo "  docker-push  Push container image"
	@echo ""
	@echo "Development Targets:"
	@echo "  dev-setup    Set up development environment"
	@echo "  install      Install CLI locally"
	@echo "  run-cli      Run CLI in development mode"
	@echo "  run-daemon   Run Daemon in development mode"
	@echo "  watch        Watch for changes and rebuild"
	@echo ""
	@echo "Documentation Targets:"
	@echo "  docs         Build and open documentation"
	@echo "  docs-serve   Serve documentation locally"
	@echo ""
	@echo "Clean Targets:"
	@echo "  clean        Clean build artifacts"
	@echo "  clean-all    Deep clean (includes registry cache)"
	@echo ""
	@echo "Other Targets:"
	@echo "  ci           Run all CI checks"
	@echo "  help         Show this help message"
