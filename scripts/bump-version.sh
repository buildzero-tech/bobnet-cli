#!/usr/bin/env bash
# Bump version and create release tag
set -euo pipefail

cd "$(dirname "$0")/.."

CURRENT=$(cat version)
TYPE=${1:-patch}

IFS='.' read -r major minor patch <<< "$CURRENT"

case "$TYPE" in
  major) ((major++)); minor=0; patch=0 ;;
  minor) ((minor++)); patch=0 ;;
  patch) ((patch++)) ;;
  *) echo "Usage: $0 [major|minor|patch]"; exit 1 ;;
esac

NEW="$major.$minor.$patch"
echo "$NEW" > version
echo "Bumped $CURRENT → $NEW"
echo ""
echo "To release:"
echo "  git add version"
echo "  git commit -m 'chore: bump version to $NEW'"
echo "  git tag v$NEW"
echo "  git push origin main v$NEW"
