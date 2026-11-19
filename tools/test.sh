#!/bin/bash
# Runs the automatic tests (lyrics parsing and matching, saved lyrics, settings, Apple Music layout).
# With only the Command Line Tools installed (no Xcode), Swift Testing sits in a folder that
# swift doesn't search by default, so point it there.
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools* && -d "$CLT/Frameworks/Testing.framework" ]]; then
    exec swift test -Xswiftc -F -Xswiftc "$CLT/Frameworks" -Xlinker -F -Xlinker "$CLT/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
fi
exec swift test "$@"
