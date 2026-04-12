#!/bin/bash
# LifeOS Version Bumper — updates the single formal semver source of truth.
# Usage:
#   ./scripts/bump-version.sh patch    # 0.3.0 → 0.3.1
#   ./scripts/bump-version.sh minor    # 0.3.1 → 0.4.0
#   ./scripts/bump-version.sh major    # 0.4.0 → 1.0.0
#   ./scripts/bump-version.sh 0.4.2    # Set explicit version
set -euo pipefail

# Read current version from the workspace manifest (source of truth)
CURRENT=$(awk '
    BEGIN { section = "" }
    /^\[/ { section = $0 }
    section == "[workspace.package]" && $1 == "version" {
        gsub(/"/, "", $3)
        print $3
        exit
    }
' Cargo.toml)

if [[ -z "${CURRENT}" ]]; then
    echo "Could not read [workspace.package].version from Cargo.toml"
    exit 1
fi

echo "Current version: $CURRENT"

# Parse major.minor.patch
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

# Calculate new version
case "${1:-patch}" in
    patch)
        PATCH=$((PATCH + 1))
        NEW="$MAJOR.$MINOR.$PATCH"
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        NEW="$MAJOR.$MINOR.$PATCH"
        ;;
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        NEW="$MAJOR.$MINOR.$PATCH"
        ;;
    [0-9]*)
        NEW="$1"
        ;;
    *)
        echo "Usage: $0 [patch|minor|major|X.Y.Z]"
        exit 1
        ;;
esac

echo "New version: $NEW"
echo ""

echo "Updating files..."
sed -i "/^\[workspace.package\]/,/^\[/ s/^version = \"${CURRENT//./\\.}\"$/version = \"$NEW\"/" Cargo.toml
echo "  ✓ Cargo.toml [workspace.package].version"

# Cargo.lock pins an exact version per workspace crate; --locked
# container builds reject any Cargo.toml ↔ Cargo.lock drift. Keep the
# two in sync by rewriting each workspace package entry in place. We
# only touch the three LifeOS crates (life, lifeosd,
# lifeos-integration-tests) so the 500+ external dependency pins stay
# byte-identical.
if [[ -f Cargo.lock ]]; then
    for pkg in life lifeosd lifeos-integration-tests; do
        sed -i "/^name = \"${pkg}\"\$/ { n; s/^version = \"${CURRENT//./\\.}\"\$/version = \"$NEW\"/ }" Cargo.lock
    done
    echo "  ✓ Cargo.lock workspace package versions"
fi

echo ""
echo "Version bumped: $CURRENT → $NEW"
echo ""
echo "Derived consumers: cli/, daemon/, tests/, image/Containerfile, lifeos-apply-theme.sh"
