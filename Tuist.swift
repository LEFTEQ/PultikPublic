import ProjectDescription

// 26 and 27: Xcode 27.2 replaced 26 on the build Mac on 2026-11-15, and `tuist generate` refused it.
// One app's tests (344) pass under 27.2; the other apps' builds under 27 are unproven.
let tuist = Tuist(project: .tuist(compatibleXcodeVersions: .list([.upToNextMajor("26.0"), .upToNextMajor("27.0")])))
