#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/mbfoss/neotoolkit.nvim"
DEST="lua/ezpick/util"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Only the neotoolkit modules ezpick actually needs (transitive closure):
# fsutil pulls in strutil and timer, everything else stands alone. ezpick ships
# its own Picker/Layout code under lua/ezpick, so none of that is vendored.
FILES=(
    Spinner
    floatwin
    fsutil
    spawn
    strutil
    timer
    ui
)

cd "$(dirname "$0")/.."

if [[ -n "${LOCAL:-}" ]]; then
    echo "Using local repo: $LOCAL"
    cp -r "$LOCAL" "$TMP/neotoolkit"
else
    echo "Cloning $REPO..."
    git clone --depth=1 "$REPO" "$TMP/neotoolkit"
fi

SRC="$TMP/neotoolkit/lua/neotoolkit"

echo "Copying ${#FILES[@]} files into $DEST..."
mkdir -p "$DEST"
for f in "${FILES[@]}"; do
    if [[ ! -f "$SRC/$f.lua" ]]; then
        echo "error: $f.lua not found in neotoolkit source" >&2
        exit 1
    fi
    cp "$SRC/$f.lua" "$DEST/$f.lua"
done

echo "Rewriting require paths and type annotations (neotoolkit. -> ezpick.util.)..."
for f in "${FILES[@]}"; do
    sed -i '' 's/neotoolkit\./ezpick.util./g' "$DEST/$f.lua"
done

echo "Done. Vendored ${#FILES[@]} modules into $DEST; ezpick's own files are untouched."
