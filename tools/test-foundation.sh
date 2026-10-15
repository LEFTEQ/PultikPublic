#!/usr/bin/env bash
# The same Foundation contract selection locally and in CI; no native app host.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
app="$repo/Apps/Pultik"
# Stay in Pultík AC 14: only the adapters name GitHub.
bash "$repo/tools/host-neutral-check.sh"
harness=$(mktemp -d "${TMPDIR:-/tmp}/pultik-foundation.XXXXXX")
trap 'rm -rf "$harness"' EXIT
mkdir -p "$harness/Sources/Pultik" "$harness/Tests/PultikTests"
sources=(Sources/Models/Models.swift Sources/Models/OverviewGlance.swift
  Sources/Models/DevboxBoxes.swift Sources/Models/DevboxClear.swift Sources/Models/FiringWatch.swift Sources/API/PollingSession.swift
  Sources/Support/GHToken.swift Sources/Support/ProcessOutput.swift Sources/Support/ProbeGate.swift Sources/Support/DevboxClearWorktree.swift
  Sources/Support/PanelTestDisplay.swift Sources/Support/PultikLink.swift
  Sources/Models/ProdGlance.swift Sources/Models/ProdMatrix.swift Sources/Models/SettingsFile.swift
  Sources/Support/DateAge.swift Sources/Models/ProdTransitions.swift Sources/Models/ProdClaims.swift
  Sources/Models/NotificationContent.swift Sources/Models/PRDigest.swift Sources/Support/PultikFormat.swift
  Sources/Data/QuerySnapshots.swift Sources/Data/QueryRepository.swift Sources/Data/BackendSchedule.swift
  Sources/Views/Shell/PanelModule.swift Sources/Views/Shell/PaletteMode.swift Sources/Views/Shell/ModuleRouter.swift
  Sources/Views/Shell/KeyboardCoordinator.swift Sources/Models/FleetContract.swift
  Sources/Data/GitMirror.swift Sources/Data/WarmSet.swift Sources/Models/RunBadge.swift
  Sources/API/CIStatus/CIStatusSource.swift Sources/Views/Shell/PanelPlace.swift Sources/Views/Shell/ModuleWarmth.swift
  Sources/API/WorkflowGraph.swift Sources/Views/Markdown/Autolink.swift Sources/Views/Modules/PRs/PRVerbCatalogue.swift
  Sources/Code/CodeSearch.swift
  "$app"/Sources/Domain/*.swift "$app"/Sources/API/Hosts/*.swift
  "$app"/Sources/Models/Now/*.swift "$app"/Sources/Models/Now/Adapters/*.swift)
tests=(Tests/DevboxCapacityTests.swift Tests/OverviewGlanceTests.swift Tests/DevboxBoxesTests.swift
  Tests/FiringWatchTests.swift Tests/DevboxClearTests.swift Tests/DevboxClearWorktreeTests.swift
  Tests/PanelTestDisplayTests.swift Tests/PultikLinkTests.swift
  Tests/ProdGlanceTests.swift Tests/SettingsFileTests.swift Tests/ProdTransitionsTests.swift
  Tests/ProdClaimsTests.swift Tests/PRDigestTests.swift Tests/PultikFormatTests.swift Tests/QueryRepositoryTests.swift
  Tests/ModuleRouterTests.swift Tests/NowQueueTests.swift Tests/ObservationLedgerTests.swift Tests/NowAdaptersTests.swift
  Tests/FleetContractTests.swift Tests/BackendScheduleTests.swift
  Tests/HostAdapterTests.swift Tests/GitMirrorTests.swift Tests/WarmSetTests.swift
  Tests/RunBadgeTests.swift Tests/CIWatchTests.swift Tests/WorkflowGraphTests.swift Tests/RunCardTests.swift
  Tests/AutolinkTests.swift Tests/FileTreeTests.swift Tests/CodeSearchTests.swift)
# Golden payloads the contract tests read beside themselves (#filePath).
cp -R "$app/Tests/Fixtures" "$harness/Tests/PultikTests/Fixtures"
for file in "${sources[@]}" "$app"/Sources/API/GitHub*.swift; do
  [[ "$file" = /* ]] || file="$app/$file"
  cp "$file" "$harness/Sources/Pultik/"
done
for file in "${tests[@]}" "$app"/Tests/GitHub*Tests.swift; do
  [[ "$file" = /* ]] || file="$app/$file"
  cp "$file" "$harness/Tests/PultikTests/"
done
cat > "$harness/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PultikFoundationContract", platforms: [.macOS(.v14)], targets: [
    .target(name: "Pultik"),
    .testTarget(name: "PultikTests", dependencies: ["Pultik"], exclude: ["Fixtures"])
])
SWIFT
swift test --package-path "$harness" "$@"
