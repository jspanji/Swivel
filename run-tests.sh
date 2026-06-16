#!/usr/bin/env bash
# Run the SwivelCore test suite (swift-testing).
#
# On a machine with full Xcode, `swift test` finds the testing frameworks on
# its own. On a Command Line Tools-only machine, swift-testing's frameworks
# live under the CLT Developer/Frameworks dir and aren't on the default search
# path, so we point the compiler/linker at them explicitly.
set -euo pipefail

FW="$(xcode-select -p)/Library/Developer/Frameworks"

if [ -d "$FW/Testing.framework" ]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$FW" \
        -Xlinker -F -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$FW" "$@"
else
    exec swift test "$@"
fi
