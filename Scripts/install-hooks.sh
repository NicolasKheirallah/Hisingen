#!/bin/sh
set -eu
# Installs this repository's git hooks into .git/hooks. Re-run after a hook changes; the
# symlink makes the tracked copy the only copy.
#
#   make hooks
#
# Hooks are per-clone and cannot be committed, so a fresh checkout needs this once.

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

if [ ! -d .git ]; then
    echo "Not a git checkout: .git is missing in $root" >&2
    exit 1
fi

hooks_dir=$(git rev-parse --git-path hooks)
mkdir -p "$hooks_dir"

installed=""
for hook in Scripts/hooks/*; do
    [ -f "$hook" ] || continue
    name=$(basename "$hook")
    chmod +x "$hook"
    ln -sf "../../$hook" "$hooks_dir/$name"
    installed="$installed $name"
done

if [ -z "$installed" ]; then
    echo "No hooks found in Scripts/hooks." >&2
    exit 1
fi

echo "Installed git hooks:$installed"
echo "Bypass one commit with HISINGEN_SKIP_HOOKS=1 git commit ..."
