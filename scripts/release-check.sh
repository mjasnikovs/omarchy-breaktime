#!/usr/bin/env bash
# Final gate before a push that users will install from. Checks what is
# committed, not the working copy.
#
# 1. Model.mjs must be tracked and match HEAD, and src/ must be committed.
#    The marketplace installs the raw repo with no build step.
# 2. The committed tree, extracted without node_modules, must pass the
#    shell's plugin validator (it refuses symlinks, which node_modules has).
set -euo pipefail
cd "$(dirname "$0")/.."

git ls-files --error-unmatch Model.mjs >/dev/null 2>&1 || {
    echo "release: Model.mjs is not tracked. Run: bun run build && git add Model.mjs" >&2
    exit 1
}
if ! git diff --quiet HEAD -- Model.mjs src/; then
    echo "release: Model.mjs or src/ differs from HEAD. Commit first." >&2
    git --no-pager diff --stat HEAD -- Model.mjs src/ >&2
    exit 1
fi

stage=".release"
rm -rf "$stage"
mkdir -p "$stage"
git archive HEAD | tar -x -C "$stage"
omarchy plugin validate "$stage"
rm -rf "$stage"
echo "release: ok"
