#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
bump=${1:-patch}
# All entry points prepare the same reviewed release PR; no local tag or artifact mutation.
exec gh workflow run tag-release.yml --ref main -f "bump=$bump"
