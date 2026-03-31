#!/bin/bash
# LifeOS Version Bumper — updates version across ALL files that contain it.
# Usage:
#   ./scripts/bump-version.sh patch    # 0.3.0 → 0.3.1
#   ./scripts/bump-version.sh minor    # 0.3.1 → 0.4.0
#   ./scripts/bump-version.sh major    # 0.4.0 → 1.0.0
#   ./scripts/bump-version.sh 0.4.2    # Set explicit version
set -euo pipefail

# Read current version from daemon/Cargo.toml (source of truth)
CURRENT=$(grep '^version' daemon/Cargo.toml | head -1 | sed 's/version = "\(.*\)"/\1/')
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

# Files to update
echo "Updating files..."

# 1. daemon/Cargo.toml
sed -i "0,/^version = \"$CURRENT\"/s//version = \"$NEW\"/" daemon/Cargo.toml
echo "  ✓ daemon/Cargo.toml"

# 2. cli/Cargo.toml
sed -i "0,/^version = \"$CURRENT\"/s//version = \"$NEW\"/" cli/Cargo.toml
echo "  ✓ cli/Cargo.toml"

# 3. Containerfile VERSION
sed -i "s/VERSION=\"[0-9]*\.[0-9]* Axolotl\"/VERSION=\"$NEW Axolotl\"/" image/Containerfile
echo "  ✓ image/Containerfile (VERSION)"

# 4. Containerfile PRETTY_NAME
sed -i "s/LifeOS [0-9]*\.[0-9]*\.[0-9]* Axolotl/LifeOS $NEW Axolotl/g" image/Containerfile
echo "  ✓ image/Containerfile (PRETTY_NAME)"

# 5. lifeos-apply-theme.sh
sed -i "s/CURRENT_VERSION=\"[0-9]*\.[0-9]*\.[0-9]*\"/CURRENT_VERSION=\"$NEW\"/" image/files/usr/local/bin/lifeos-apply-theme.sh
echo "  ✓ lifeos-apply-theme.sh"

echo ""
echo "Version bumped: $CURRENT → $NEW"
echo ""
echo "Files changed:"
git diff --name-only
echo ""
echo "Next steps:"
echo "  git add -A && git commit -m \"chore: bump version to v$NEW\""
