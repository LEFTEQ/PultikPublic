import SwiftUI

/// What the HUD shows: section visibility and the eve alert lanes.
struct PanelPane: View {
    let store: StatusStore

    private static let sections = [
        ("prod", "Prod issues strip"), ("servers", "Servers rail"),
        ("services", "Services rail"), ("ci", "CI footer"),
        ("alerts", "Eve alerts"), ("fans", "Fan & Mac strip"),
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
