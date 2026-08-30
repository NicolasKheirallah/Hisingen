#!/bin/sh
set -eu

developer_dir=${DEVELOPER_DIR:-}
if [ -z "$developer_dir" ]; then
  developer_dir=$(xcode-select -p 2>/dev/null || true)
fi
if [ -z "$developer_dir" ]; then
  echo "No Apple developer toolchain is selected. Install Xcode or compatible Command Line Tools." >&2
  exit 1
fi
if [ ! -d "$developer_dir" ]; then
  echo "Apple developer toolchain not found at $developer_dir." >&2
  exit 1
fi

echo "Developer tools: $developer_dir"
xcrun swiftc --version
xcrun --show-sdk-path

# Package.swift declares swift-tools-version:6.0 and builds in the Swift 6 language
# mode. A 5.x toolchain cannot parse the manifest, so fail early with a clear message
# instead of a cryptic manifest-parse error later.
swift_version=$(xcrun swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1 \2/p' | head -n1)
swift_major=${swift_version%% *}
if [ -n "$swift_major" ] && [ "$swift_major" -lt 6 ]; then
  echo "Swift 6.0 or newer is required (found $swift_version). Install Xcode 16 or newer." >&2
  exit 1
fi

module_cache=${TMPDIR:-/tmp}/hisingen-doctor-module-cache
mkdir -p "$module_cache"
if ! SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
     CLANG_MODULE_CACHE_PATH="$module_cache" \
     swift package dump-package >/dev/null; then
  echo "The selected Swift compiler, SDK, or SwiftPM libraries do not match." >&2
  echo "Select a complete compatible Xcode installation with xcode-select, then retry." >&2
  exit 1
fi

echo "Hisingen toolchain check passed."
