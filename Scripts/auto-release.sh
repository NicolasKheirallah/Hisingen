#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
exec python3 Scripts/release-support.py auto
