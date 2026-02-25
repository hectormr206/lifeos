#!/bin/bash
# LifeOS Phase 4 Verification Script
# Run this script to verify the testing and CI/CD setup

set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║       LifeOS Phase 4 - Testing & CI/CD Verification            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check_file() {
    if [ -f "$1" ]; then
        echo -e "${GREEN}✓${NC} $1"
        return 0
    else
        echo -e "${RED}✗${NC} $1 (missing)"
        return 1
    fi
}

check_dir() {
    if [ -d "$1" ]; then
        echo -e "${GREEN}✓${NC} $1/"
        return 0
    else
        echo -e "${RED}✗${NC} $1/ (missing)"
        return 1
    fi
}

errors=0

echo "1. Checking CI/CD Workflows..."
echo "─────────────────────────────────────────────────────────────────"
check_file ".github/workflows/ci.yml" || ((errors++))
check_file ".github/workflows/docker.yml" || ((errors++))
check_file ".github/workflows/release.yml" || ((errors++))
check_file ".github/workflows/codeql.yml" || ((errors++))
check_file ".github/workflows/nightly.yml" || ((errors++))
check_file ".github/changelog-config.json" || ((errors++))
echo ""

echo "2. Checking Pre-commit Hooks..."
echo "─────────────────────────────────────────────────────────────────"
check_file ".pre-commit-config.yaml" || ((errors++))
echo ""

echo "3. Checking Build Automation..."
echo "─────────────────────────────────────────────────────────────────"
check_file "Makefile" || ((errors++))
check_file "Cargo.toml" || ((errors++))
echo ""

echo "4. Checking CLI Tests..."
echo "─────────────────────────────────────────────────────────────────"
check_file "cli/src/config/tests.rs" || ((errors++))
check_file "cli/src/system/tests.rs" || ((errors++))
check_file "cli/src/main_tests.rs" || ((errors++))
echo ""

echo "5. Checking Daemon Tests..."
echo "─────────────────────────────────────────────────────────────────"
check_file "daemon/src/health_tests.rs" || ((errors++))
check_file "daemon/src/updates_tests.rs" || ((errors++))
check_file "daemon/src/notifications_tests.rs" || ((errors++))
echo ""

echo "6. Checking Integration Tests..."
echo "─────────────────────────────────────────────────────────────────"
check_file "tests/Cargo.toml" || ((errors++))
check_file "tests/integration/main.rs" || ((errors++))
echo ""

echo "7. Checking Documentation..."
echo "─────────────────────────────────────────────────────────────────"
check_file "docs/TESTING_STRATEGY.md" || ((errors++))
check_file "docs/CICD_ARCHITECTURE.md" || ((errors++))
check_file "docs/TESTING.md" || ((errors++))
check_file "docs/CI_CD.md" || ((errors++))
check_file "PHASE4_SUMMARY.md" || ((errors++))
echo ""

echo "8. Checking Supporting Files..."
echo "─────────────────────────────────────────────────────────────────"
check_file ".gitignore" || ((errors++))
echo ""

echo "═══════════════════════════════════════════════════════════════════"
if [ $errors -eq 0 ]; then
    echo -e "${GREEN}✓ All Phase 4 deliverables verified successfully!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Run 'make dev-setup' to install development tools"
    echo "  2. Run 'make test' to execute all tests"
    echo "  3. Run 'make ci' to simulate CI checks locally"
    echo "  4. Enable GitHub Actions in your repository"
    exit 0
else
    echo -e "${RED}✗ $errors file(s) missing or incomplete${NC}"
    exit 1
fi
