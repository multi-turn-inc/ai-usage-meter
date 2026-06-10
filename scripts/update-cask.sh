#!/bin/bash
# Updates the Homebrew cask in multi-turn-inc/homebrew-tap after a release.
# Usage: scripts/update-cask.sh <version> [dmg-path]
# Run after the versioned DMG is uploaded to the GitHub release.
set -euo pipefail

VERSION="${1:?usage: update-cask.sh <version> [dmg-path]}"
DMG="${2:-.build/release/AIUsageMeter-$VERSION.dmg}"

if [ ! -f "$DMG" ]; then
    echo "❌ DMG not found: $DMG" >&2
    exit 1
fi

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
TAP_DIR=$(mktemp -d)
trap 'rm -rf "$TAP_DIR"' EXIT

git clone --quiet --depth 1 "https://github.com/multi-turn-inc/homebrew-tap.git" "$TAP_DIR"
CASK="$TAP_DIR/Casks/token-burn.rb"

sed -i '' "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK"
sed -i '' "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"

if git -C "$TAP_DIR" diff --quiet; then
    echo "✅ Cask already up to date (v$VERSION)"
    exit 0
fi

git -C "$TAP_DIR" commit --quiet -am "token-burn $VERSION"
git -C "$TAP_DIR" push --quiet
echo "✅ Cask updated: token-burn $VERSION ($SHA)"
