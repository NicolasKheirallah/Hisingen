#!/bin/sh
# Runs the unit tests of the Home Assistant component. They use only the Python standard library,
# so no Home Assistant install is needed.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root/home-assistant"
exec python3 -I -B -m unittest discover -s tests -t . -v
