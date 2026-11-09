#!/usr/bin/env bash
set -euo pipefail

# release.sh - bump version, tag, and push.
# Usage: ./release.sh [patch|minor|major]
#
# Examples:
#     ./release.sh patch            # bumps 0.3.2 -> 0.3.3
#     ./release.sh minor            # bumps 0.3.2 -> 0.4.0
#     ./release.sh major            # bumps 0.3.2 -> 1.0.0
#
# Core (always): build.zig.zon, whose version the orchd binary reports.

# --- Project add-ons (optional) ----------------------------------------------
# Extra files kept in version lockstep with build.zig.zon.
EXTRA_VERSIONED_FILES=(orchd-rootstock-bare/build.zig.zon orchd-rootstock-applz/build.zig.zon orchd-rootstock-apple/build.zig.zon)
# -----------------------------------------------------------------------------

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
OLD_VER="$(grep '^ *\.version = ' build.zig.zon | sed 's/.*"\(.*\)".*/\1/')"
case "${1:-patch}" in
  patch)
    IFS='.' read -r MAJOR MINOR PATCH <<< "$OLD_VER"
    NEW_VER="$MAJOR.$MINOR.$((PATCH + 1))"
     ;;
  minor)
    IFS='.' read -r MAJOR MINOR PATCH <<< "$OLD_VER"
    NEW_VER="$MAJOR.$((MINOR + 1)).0"
     ;;
  major)
    IFS='.' read -r MAJOR MINOR PATCH <<< "$OLD_VER"
    NEW_VER="$((MAJOR + 1)).0.0"
     ;;
  *)
    echo "error: unknown bump type '${1}' (use patch|minor|major)" >&2
    exit 1
     ;;
esac

# Files kept in version lockstep with build.zig.zon
VERSIONED_FILES=(build.zig.zon "${EXTRA_VERSIONED_FILES[@]}")

# Every versioned file must already carry OLD_VER, or versions have drifted.
for f in "${VERSIONED_FILES[@]}"; do
  if ! grep -q "\"$OLD_VER\"" "$f"; then
    echo "error: $f does not contain version $OLD_VER (files out of sync?)" >&2
    exit 1
  fi
done

# Bump `.version = "x.y.z"` in every lockstep file (fingerprints are name-bound, unchanged).
for f in "${VERSIONED_FILES[@]}"; do
  sed -i '' -e "s/\.version = \"$OLD_VER\"/.version = \"$NEW_VER\"/" "$f"
done

if ! git diff --quiet -- "${VERSIONED_FILES[@]}"; then
  git add "${VERSIONED_FILES[@]}"
  git commit -m "chore: bump to $NEW_VER"
fi

# Tag and push
TAG="v$NEW_VER"
git tag -a "$TAG" -m "v$NEW_VER"
git push origin main --tags
echo "Released $TAG ✓"