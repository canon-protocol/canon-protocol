#!/usr/bin/env bash
set -euo pipefail

# Add an npm package version to the static registry.
#
# Usage: ./scripts/add-npm-package.sh <name> <version>
#   name:    cli, sdk, or types
#   version: e.g., 7.4.0
#
# Requires: npm (authenticated to GitHub Packages), jq, openssl, sha1sum

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

NAME="${1:?Usage: add-npm-package.sh <name> <version>}"
VERSION="${2:?Usage: add-npm-package.sh <name> <version>}"

SCOPE="@canon-protocol"
FULL_NAME="$SCOPE/$NAME"
TARBALL_DIR="$REPO_DIR/packages/$SCOPE/$NAME"
PACKUMENT_FILE="$REPO_DIR/npm/$SCOPE/$NAME"

echo "Downloading $FULL_NAME@$VERSION from GitHub Packages..."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"
npm pack "$FULL_NAME@$VERSION" --registry=https://npm.pkg.github.com

TGZ_FILE=$(ls canon-protocol-*.tgz)
DEST_FILE="$NAME-$VERSION.tgz"

# Compute hashes
SHASUM=$(sha1sum "$TGZ_FILE" | cut -d' ' -f1)
INTEGRITY="sha512-$(openssl dgst -sha512 -binary "$TGZ_FILE" | openssl base64 -A)"

# Extract package.json from tarball
tar xzf "$TGZ_FILE" package/package.json
PKG_JSON="$TMPDIR/package/package.json"

# Extract fields for the packument version entry
DEPS=$(jq '.dependencies // {}' "$PKG_JSON")
BIN=$(jq '.bin // {}' "$PKG_JSON")
DESC=$(jq -r '.description // ""' "$PKG_JSON")
ENGINES=$(jq '.engines // {}' "$PKG_JSON")

# Build the version entry
VERSION_ENTRY=$(jq -n \
  --arg name "$FULL_NAME" \
  --arg version "$VERSION" \
  --arg desc "$DESC" \
  --argjson deps "$DEPS" \
  --argjson bin "$BIN" \
  --argjson engines "$ENGINES" \
  --arg shasum "$SHASUM" \
  --arg integrity "$INTEGRITY" \
  --arg tarball "https://canon-protocol.org/packages/$SCOPE/$NAME/$NAME-$VERSION.tgz" \
  '{
    name: $name,
    version: $version,
    description: $desc,
    dependencies: $deps,
    bin: $bin,
    engines: $engines,
    dist: {
      shasum: $shasum,
      integrity: $integrity,
      tarball: $tarball
    }
  } | if .bin == {} then del(.bin) else . end')

# Place tarball
mkdir -p "$TARBALL_DIR"
cp "$TGZ_FILE" "$TARBALL_DIR/$DEST_FILE"
echo "Placed tarball at packages/$SCOPE/$NAME/$DEST_FILE"

# Update or create packument
if [ -f "$PACKUMENT_FILE" ]; then
  # Add version and update dist-tags.latest
  jq --arg ver "$VERSION" --argjson entry "$VERSION_ENTRY" \
    '.versions[$ver] = $entry | .["dist-tags"].latest = $ver' \
    "$PACKUMENT_FILE" > "$PACKUMENT_FILE.tmp"
  mv "$PACKUMENT_FILE.tmp" "$PACKUMENT_FILE"
else
  # Create new packument
  mkdir -p "$(dirname "$PACKUMENT_FILE")"
  jq -n \
    --arg name "$FULL_NAME" \
    --arg ver "$VERSION" \
    --argjson entry "$VERSION_ENTRY" \
    '{
      name: $name,
      "dist-tags": { latest: $ver },
      versions: { ($ver): $entry }
    }' > "$PACKUMENT_FILE"
fi

echo "Updated packument at npm/$SCOPE/$NAME"
echo ""
echo "Done. Commit and push to publish $FULL_NAME@$VERSION."
