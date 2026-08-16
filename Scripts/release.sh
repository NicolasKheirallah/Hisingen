#!/bin/sh
set -eu

echo "=========================================="
echo "🏎️  Hisingen Release & Deployment Pipeline"
echo "=========================================="

# 1. Pre-flight Checks
echo "🔍 Running pre-flight checks..."

# Check git status
if [ -n "$(git status --porcelain=v1)" ]; then
    echo "❌ Working tree is not clean. Commit or stash all changes first."
    git status -s
    exit 1
fi

# Run test suite
echo "🧪 Running full test suite..."
sh Scripts/test.sh

# Check documentation & localization if scripts exist
if [ -f "Scripts/check-localization.py" ]; then
    python3 Scripts/check-localization.py || true
fi

# 2. Resolve version bump
BUMP="${1:-patch}"
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

echo "🚀 Preparing release v${NEW_VERSION} (previous tag: ${LATEST_TAG:-none})..."

# 3. Update Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEW_VERSION}" Resources/Info.plist
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist 2>/dev/null || echo "0")
NEXT_BUILD=$((CURRENT_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEXT_BUILD}" Resources/Info.plist

# 4. Build Universal Binary & DMG
echo "📦 Building universal app and DMG installer..."
make app-universal
make dmg

# Generate SHA256
shasum -a 256 Hisingen.dmg > Hisingen.dmg.sha256
echo "🔒 SHA256 Checksum: $(cat Hisingen.dmg.sha256)"

# 5. Commit and Tag
git add Resources/Info.plist
git commit -m "chore(release): bump version to v${NEW_VERSION} (build ${NEXT_BUILD})"
git tag -a "v${NEW_VERSION}" -m "Release v${NEW_VERSION}"

echo "=========================================="
echo "✅ Release v${NEW_VERSION} packaged successfully!"
echo "=========================================="
echo "📁 Artifacts generated:"
echo "   - Hisingen.app (Universal: arm64 + x86_64)"
echo "   - Hisingen.dmg"
echo "   - Hisingen.dmg.sha256"
echo ""
echo "🚀 To publish this release to GitHub Actions:"
echo "   git push origin HEAD --tags"
echo ""
echo "Or create a release directly via GitHub CLI if installed:"
echo "   gh release create v${NEW_VERSION} Hisingen.dmg Hisingen.dmg.sha256 --title \"v${NEW_VERSION}\" --notes \"Release v${NEW_VERSION}\""
