#!/bin/sh
set -eu

# Auto-release: take the release version from Resources/Info.plist (shipping a
# manual bump as-is, otherwise incrementing the last release's patch number),
# generate a CHANGELOG entry from the commits since the last tag, commit, tag,
# and dispatch the release workflow.
# Called by .github/workflows/auto-release.yml after a green CI run on main,
# with GH_TOKEN exported and `gh auth setup-git` configured for the push.
#
# Skips (exit 0, no release) when:
#   - HEAD is already tagged (the run is for a released bump commit)
#   - a newer commit landed on main while CI ran (stale run)
#   - any new commit message contains [skip release]
#   - only release-bump commits exist since the last tag
#
# AUTO_RELEASE_DRY_RUN=1 performs everything except the push and dispatch.

DRY_RUN=${AUTO_RELEASE_DRY_RUN:-0}
CI_HEAD_SHA=${CI_HEAD_SHA:-}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

skip() {
    echo "auto-release: skipping release — $1"
    exit 0
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "not a git repository"
[ -z "$(git status --porcelain=v1)" ] || skip "working tree is not clean"

if [ -n "$CI_HEAD_SHA" ] && [ "$CI_HEAD_SHA" != "$(git rev-parse HEAD)" ]; then
    skip "a newer commit landed on main since this CI run started"
fi

if git describe --tags --exact-match HEAD >/dev/null 2>&1; then
    skip "HEAD is already tagged"
fi

LATEST_TAG=$(git tag -l "v*" --sort=-v:refname | head -n 1 2>/dev/null || true)
if [ -n "$LATEST_TAG" ]; then
    COMMITS=$(git log --format=%s "${LATEST_TAG}..HEAD")
else
    COMMITS=$(git log --format=%s HEAD)
fi

[ -n "$COMMITS" ] || skip "no commits since ${LATEST_TAG:-the first release}"

HEAD_MESSAGE=$(git log -1 --format=%B)

if printf '%s\n' "$HEAD_MESSAGE" | grep -Fq '[skip release]'; then
    skip "HEAD commit contains [skip release]"
fi

RELEASABLE=$(printf '%s\n' "$COMMITS" | grep -v '^chore(release):' || true)
[ -n "$RELEASABLE" ] || skip "only release-bump commits since ${LATEST_TAG:-the first release}"

# Resources/Info.plist is the source of truth for the release version. When the
# plist has been bumped manually to a version past the latest tag (e.g. a major
# or minor landing), ship it as-is; otherwise increment the last release's patch
# number. Deriving the version from the tag alone silently renumbers manual
# bumps — that is how a 2.0.0 landing was released as 1.3.6.
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || true)

if [ -z "$LATEST_TAG" ]; then
    NEW_VERSION="${PLIST_VERSION:-1.0.0}"
else
    TAG_VERSION="${LATEST_TAG#v}"
    if [ -n "$PLIST_VERSION" ] && [ "$PLIST_VERSION" != "$TAG_VERSION" ]; then
        NEW_VERSION="$PLIST_VERSION"
    else
        MAJOR=${TAG_VERSION%%.*}
        REST=${TAG_VERSION#*.}
        MINOR=${REST%%.*}
        PATCH=${REST#*.}
        PATCH=$((PATCH + 1))
        NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
    fi
fi

printf '%s' "$NEW_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
    echo "auto-release: refusing to release — Resources/Info.plist has invalid version '${NEW_VERSION}'" >&2
    exit 1
}

if git rev-parse -q --verify "refs/tags/v${NEW_VERSION}" >/dev/null 2>&1; then
    skip "v${NEW_VERSION} is already tagged — bump Resources/Info.plist to release"
fi

DATE=$(date +%F)

bulletize() {
    printf '%s\n' "$1" | sed -E 's/^(feat|fix)(\([^)]*\))?:[[:space:]]*//' | sed 's/^/- /'
}

ADDED=$(bulletize "$(printf '%s\n' "$RELEASABLE" | grep -E '^feat' || true)")
FIXED=$(bulletize "$(printf '%s\n' "$RELEASABLE" | grep -E '^fix' || true)")
CHANGED=$(bulletize "$(printf '%s\n' "$RELEASABLE" | grep -vE '^(feat|fix)' || true)")

ENTRY="## [$NEW_VERSION] - $DATE"
add_section() {
    if [ -n "$2" ]; then
        ENTRY="$ENTRY

### $1

$2"
    fi
}
add_section "Added" "$ADDED"
add_section "Fixed" "$FIXED"
add_section "Changed" "$CHANGED"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" Resources/Info.plist
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist 2>/dev/null || echo "0")
NEXT_BUILD=$((CURRENT_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" Resources/Info.plist

TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/hisingen-auto-release.XXXXXX")
cleanup() { rm -f "$TMP_FILE"; }
trap cleanup EXIT HUP INT TERM

FIRST_HEADING=$(grep -n '^## \[' CHANGELOG.md | head -n 1 | cut -d: -f1 || true)
{
    if [ -n "$FIRST_HEADING" ]; then
        head -n $((FIRST_HEADING - 1)) CHANGELOG.md
        printf '%s\n' "$ENTRY"
        printf '\n'
        tail -n "+$FIRST_HEADING" CHANGELOG.md
    else
        cat CHANGELOG.md
        printf '%s\n' "$ENTRY"
    fi
} > "$TMP_FILE"
mv "$TMP_FILE" CHANGELOG.md

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git add Resources/Info.plist CHANGELOG.md
git commit -m "chore(release): bump version to v${NEW_VERSION} (build ${NEXT_BUILD})"
git tag -a "v${NEW_VERSION}" -m "Release v${NEW_VERSION}"

if [ "$DRY_RUN" = "1" ]; then
    echo "auto-release: dry run — would push v${NEW_VERSION} and dispatch the release workflow"
    exit 0
fi

git push origin HEAD "v${NEW_VERSION}"
gh workflow run release.yml --ref main -f tag="v${NEW_VERSION}"
echo "auto-release: v${NEW_VERSION} tagged and the release workflow dispatched"
