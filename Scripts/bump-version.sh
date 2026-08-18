#!/bin/sh
set -eu

BUMP="${1:-patch}"

# Check working tree
if [ -n "$(git status --porcelain=v1)" ]; then
    echo "❌ Working tree is not clean. Commit or stash your changes first."
    exit 1
fi

LATEST_TAG=$(git tag -l "v*" --sort=-v:refname | head -n 1 2>/dev/null || true)

if echo "$BUMP" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    NEW_VERSION="$BUMP"
elif [ -z "$LATEST_TAG" ]; then
    NEW_VERSION="1.0.0"
else
    RAW_VER="${LATEST_TAG#v}"
    MAJOR=$(echo "$RAW_VER" | cut -d. -f1)
    MINOR=$(echo "$RAW_VER" | cut -d. -f2)
    PATCH=$(echo "$RAW_VER" | cut -d. -f3)

    case "$BUMP" in
        major)
            MAJOR=$((MAJOR + 1))
            MINOR=0
            PATCH=0
            ;;
        minor)
            MINOR=$((MINOR + 1))
            PATCH=0
            ;;
        patch|*)
            PATCH=$((PATCH + 1))
            ;;
    esac
    NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
fi

echo "🚀 Preparing release v${NEW_VERSION}..."

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEW_VERSION}" Resources/Info.plist
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist 2>/dev/null || echo "0")
NEXT_BUILD=$((CURRENT_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEXT_BUILD}" Resources/Info.plist

git add Resources/Info.plist
git commit -m "chore(release): bump version to v${NEW_VERSION} (build ${NEXT_BUILD})"
git tag -a "v${NEW_VERSION}" -m "Release v${NEW_VERSION}"

echo "✅ Created commit and tag v${NEW_VERSION}"
echo "👉 Run: git push origin HEAD v${NEW_VERSION} to trigger the release build."
