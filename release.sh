#!/usr/bin/env bash
set -euo pipefail

# release.sh - bump version, tag, and push.
# Usage: ./release.sh [major|minor|patch|exact] [version]
#
# Examples:
#   ./release.sh patch          # bumps 0.3.2 -> 0.3.3
#   ./release.sh minor          # bumps 0.3.2 -> 0.4.0
#   ./release.sh major          # bumps 0.3.2 -> 1.0.0
#   ./release.sh exact 1.2.3    # sets version to 1.2.3

BRANCH="$(git branch --show-current)"
if [[ "$BRANCH" != "main" ]]; then
  echo "error: must be on main (currently on '$BRANCH')" >&2
  exit 1
fi

# Sync with origin
git fetch origin main
git reset --hard origin/main

# Determine version
NEW_VER=""
case "${1:-patch}" in
  patch)
    OLD_VER="$(grep '^version' Cargo.toml | sed 's/.*"\(.*\)"/\1/')"
    IFS='.' read -r MAJOR MINOR PATCH <<< "$OLD_VER"
    NEW_VER="$MAJOR.$MINOR.$((PATCH + 1))"
    ;;
  minor)
    OLD_VER="$(grep '^version' Cargo.toml | sed 's/.*"\(.*\)"/\1/')"
    IFS='.' read -r MAJOR MINOR PATCH <<< "$OLD_VER"
    NEW_VER="$MAJOR.$((MINOR + 1)).0"
    ;;
  major)
    OLD_VER="$(grep '^version' Cargo.toml | sed 's/.*"\(.*\)"/\1/')"
    IFS='.' read -r MAJOR MINOR PATCH <<< "$OLD_VER"
    NEW_VER="$((MAJOR + 1)).0.0"
    ;;
  exact)
    if [[ -z "${2:-}" ]]; then
      echo "error: 'exact' requires a version argument (e.g., './release.sh exact 1.2.0')" >&2
      exit 1
    fi
    NEW_VER="$2"
    ;;
  *)
    echo "error: unknown bump type '${1}' (use patch|minor|major|exact)" >&2
    exit 1
    ;;
esac

# Bump Cargo.toml
sed -i '' "s/version = \"$OLD_VER\"/version = \"$NEW_VER\"/" Cargo.toml

# Bump .zon files (orchd-apple and orchd-osx)
for zon in orchd-apple/build.zig.zon orchd-osx/build.zig.zon; do
  [[ -f "$zon" ]] && sed -i '' "s/version = \"$OLD_VER\"/version = \"$NEW_VER\"/" "$zon"
done

# Verify no uncommitted changes aside from version bump
if ! git diff --quiet -- Cargo.toml orchd-apple/build.zig.zon orchd-osx/build.zig.zon; then
  git add Cargo.toml orchd-apple/build.zig.zon orchd-osx/build.zig.zon
  git commit -m "chore: bump to $NEW_VER"
fi

# Tag and push
TAG="v$NEW_VER"
git tag -a "$TAG" -m "v$NEW_VER"
git push origin main --tags
echo "Released $TAG ✓"
