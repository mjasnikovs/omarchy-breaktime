#!/usr/bin/env bash
# Final gate before a push that users will install from.
#
# 1. Model.mjs on disk must match the source. The marketplace installs the
#    raw repo with no build step, so the built file is committed.
# 2. The tracked files, copied without node_modules, must pass the shell's
#    plugin validator (it refuses symlinks, which node_modules/.bin has).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! git diff --quiet -- Model.mjs; then
    echo "prepublish: Model.mjs is not committed. Run: git add Model.mjs" >&2
    git --no-pager diff --stat -- Model.mjs >&2
    exit 1
fi

stage=".prepublish"
rm -rf "$stage"
mkdir -p "$stage"
git ls-files -z | xargs -0 -I{} cp --parents {} "$stage"
omarchy plugin validate "$stage"
rm -rf "$stage"
echo "prepublish: ok"
