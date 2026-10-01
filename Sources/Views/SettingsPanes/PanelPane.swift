import SwiftUI

/// What the HUD shows: section visibility, firing-alert notifications and
/// the eve alert lanes.
struct PanelPane: View {
    let store: StatusStore

    private static let sections = [
        ("prod", "Prod issues (right rail)"), ("firing", "Firing alerts · Prometheus + Loki"),
        ("servers", "Estate widget · servers"),
        ("services", "Estate widget · services"), ("ci", "CI · GitHub runs"),
        ("alerts", "Eve alerts"), ("fans", "This Mac widget"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Self.sections, id: \.0) { key, label in
                    Toggle(label, isOn: Binding(
                        get: { store.isSectionVisible(key) },
                        set: { store.setSection(key, visible: $0) }
                    ))
                }
            } header: {
                Text("Sections")
            } footer: {
                Text("Hidden sections stop rendering — they keep polling, so switching one back on shows current data straight away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notify when a critical alert fires or resolves", isOn: Binding(
                    get: { store.notifyFiring },
                    set: { store.setNotifyFiring($0) }
                ))
            } header: {
                Text("Firing alerts")
            } footer: {
                Text("Warnings stay in the rail. Muted, criticals still badge the menu-bar icon until the panel shows them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(Preferences.knownAlertLanes, id: \.self) { lane in
                    Toggle(lane, isOn: Binding(
                        get: { store.isAlertLaneVisible(lane) },
                        set: { store.setAlertLane(lane, visible: $0) }
                    ))
                }
            } header: {
                Text("Eve alert lanes")
            } footer: {
                Text("Which lanes reach the panel. The feed stores every lane regardless — this filters the view, not the data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
