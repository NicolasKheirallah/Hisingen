#!/bin/sh
set -eu
: "${TAG:?}" "${GH_TOKEN:?}"
case "${1:-publish}" in
publish)
    python3 Scripts/release-support.py publish "$TAG"
    ;;
tap)
    : "${HOMEBREW_TAP_TOKEN:?Homebrew distribution requires HOMEBREW_TAP_TOKEN}"
    python3 Scripts/release-support.py monotonic "$TAG"
    python3 Scripts/release-support.py verify-manifest release-manifest.json "$TAG"
    work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/hisingen-tap.XXXXXX")
    trap 'rm -rf "$work"' EXIT HUP INT TERM
    gh release download "$TAG" --pattern Hisingen.dmg --dir "$work"
    test "$(shasum -a 256 "$work/Hisingen.dmg" | cut -d' ' -f1)" = "$(shasum -a 256 Hisingen.dmg | cut -d' ' -f1)"
    GH_TOKEN="$HOMEBREW_TAP_TOKEN" gh repo clone NicolasKheirallah/homebrew-tap "$work/tap" -- --depth 1
    current=$(sed -nE 's/^[[:space:]]*version "([^"]+)"/\1/p' "$work/tap/Casks/hisingen.rb")
    python3 - "$TAG" "$current" <<'PYTHON'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("release_support", "Scripts/release-support.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
if sys.argv[2] and module.semver(sys.argv[1]) < module.semver(sys.argv[2]):
    raise SystemExit("Refusing to downgrade Homebrew cask")
PYTHON
    checksum=$(shasum -a 256 Hisingen.dmg | cut -d' ' -f1)
    sh Scripts/update-homebrew-cask.sh "${TAG#v}" "$checksum" "$work/tap"
    if git -C "$work/tap" diff --quiet; then exit 0; fi
    git -C "$work/tap" config user.name 'github-actions[bot]'
    git -C "$work/tap" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
    git -C "$work/tap" add Casks/hisingen.rb
    git -C "$work/tap" commit -m "hisingen ${TAG#v}"
    GH_TOKEN="$HOMEBREW_TAP_TOKEN" gh auth setup-git
    GH_TOKEN="$HOMEBREW_TAP_TOKEN" git -C "$work/tap" push origin HEAD
    ;;
*) echo "Unknown publication phase" >&2; exit 2 ;;
esac
