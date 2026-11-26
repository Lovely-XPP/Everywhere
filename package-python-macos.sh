#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")" && pwd -P)
exec python3 "$root/qt/package_posix.py" --platform macOS "$@"
