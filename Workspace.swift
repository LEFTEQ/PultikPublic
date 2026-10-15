import ProjectDescription

// One workspace over every app (workbench W12): `tuist generate` at the repo root writes
// Pultik.xcworkspace with each app's scheme. Shared manifest code lives in
// Tuist/ProjectDescriptionHelpers. A glob, so the public mirror, which carries Apps/Pultik
// alone, generates from the same manifest.
let workspace = Workspace(
    name: "Pultik",
    projects: ["Apps/*"]
)
