#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$root/output/host-job-integration"
mkdir -p "$out/ModuleCache"
/usr/bin/xcrun swiftc -Onone -parse-as-library -swift-version 5 -module-cache-path "$out/ModuleCache" \
 "$root/Sources/Silkwire/PhysicalWorkOwnership.swift" \
 "$root/Sources/Silkwire/BackgroundWork.swift" \
 "$root/Sources/Silkwire/BackgroundWorkStore.swift" \
 "$root/Sources/Silkwire/BackgroundWorkRunner.swift" \
 "$root/Sources/Silkwire/HostLocalExecutionEvidence.swift" \
 "$root/Sources/Silkwire/HostExecutionCoordinator.swift" \
 "$root/Sources/Silkwire/HostBuilderOwnership.swift" \
 "$root/Sources/Silkwire/HostBackgroundExecution.swift" \
 "$root/Sources/Silkwire/BackgroundJobHost.swift" \
 "$root/Sources/Silkwire/BackgroundJobHostRecovery.swift" \
 "$root/Sources/Silkwire/HostBackgroundJobService.swift" \
 "$root/Tests/HostJobIntegrationTests.swift" -o "$out/HostJobIntegrationTests"
"$out/HostJobIntegrationTests"
