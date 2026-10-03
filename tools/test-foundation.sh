#!/usr/bin/env bash
# The same Foundation contract selection locally and in CI; no native app host.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
harness=$(mktemp -d "${TMPDIR:-/tmp}/pultik-foundation.XXXXXX")
trap 'rm -rf "$harness"' EXIT
mkdir -p "$harness/Sources/Pultik" "$harness/Tests/PultikTests"
sources=(Sources/Models/Models.swift Sources/Models/OverviewGlance.swift
  Sources/Models/DevboxBoxes.swift Sources/Models/DevboxClear.swift Sources/Models/FiringWatch.swift Sources/API/PollingSession.swift
  Sources/Support/GHToken.swift Sources/Support/ProbeGate.swift Sources/Support/DevboxClearWorktree.swift
  Sources/Support/PanelTestDisplay.swift)
tests=(Tests/DevboxCapacityTests.swift Tests/OverviewGlanceTests.swift Tests/DevboxBoxesTests.swift
  Tests/FiringWatchTests.swift Tests/DevboxClearTests.swift Tests/DevboxClearWorktreeTests.swift
  Tests/PanelTestDisplayTests.swift)
for file in "${sources[@]}" "$repo"/Sources/API/GitHub*.swift; do
  [[ "$file" = /* ]] || file="$repo/$file"
  cp "$file" "$harness/Sources/Pultik/"
done
for file in "${tests[@]}" "$repo"/Tests/GitHub*Tests.swift; do
  [[ "$file" = /* ]] || file="$repo/$file"
  cp "$file" "$harness/Tests/PultikTests/"
done
cat > "$harness/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PultikFoundationContract", platforms: [.macOS(.v14)], targets: [
    .target(name: "Pultik"),
    .testTarget(name: "PultikTests", dependencies: ["Pultik"])
])
SWIFT
swift test --package-path "$harness" "$@"
