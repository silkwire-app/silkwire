#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$root/output/physical-ownership"
mkdir -p "$out/ModuleCache"
/usr/bin/xcrun swiftc -O -parse-as-library -swift-version 5 \
    -module-cache-path "$out/ModuleCache" \
    "$root/Sources/Silkwire/PhysicalWorkOwnership.swift" \
    "$root/Tests/PhysicalWorkOwnershipTests.swift" \
    -o "$out/PhysicalWorkOwnershipTests"
"$out/PhysicalWorkOwnershipTests"
