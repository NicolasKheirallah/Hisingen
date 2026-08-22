#!/bin/sh
set -eu

command -v swift >/dev/null 2>&1 || { echo "Swift toolchain is required" >&2; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo "shasum is required" >&2; exit 1; }

if git ls-files --error-unmatch Sources/Hisingen/Services/API/GeneratedVolvoSecrets.swift >/dev/null 2>&1; then
    echo "GeneratedVolvoSecrets.swift must remain ignored and untracked" >&2
    exit 1
fi

if git ls-files --error-unmatch Sources/Hisingen/Services/API/GeneratedPolestarSecrets.swift >/dev/null 2>&1; then
    echo "GeneratedPolestarSecrets.swift must remain ignored and untracked" >&2
    exit 1
fi

if git ls-files | grep -E '(^|/)(\.env|.*\.pem|.*\.p12|.*\.key)$' >/dev/null 2>&1; then
    echo "Tracked secret-like file detected" >&2
    exit 1
fi

if git ls-files -z | xargs -0 grep -IlE '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}' 2>/dev/null | grep . >/dev/null 2>&1; then
    echo "Credential pattern detected in tracked source" >&2
    exit 1
fi

git diff --check

if [ -d "Hisingen.app" ]; then
    codesign --verify --deep --strict --verbose=2 "Hisingen.app"
fi

if [ -f "Hisingen.dmg" ]; then
    command -v hdiutil >/dev/null 2>&1 || { echo "hdiutil is required to validate a DMG" >&2; exit 1; }
    hdiutil verify "Hisingen.dmg"
    shasum -a 256 -c Hisingen.dmg.sha256
fi

echo "Release validation passed"
