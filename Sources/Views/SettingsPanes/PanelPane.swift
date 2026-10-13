import SwiftUI

/// What the HUD shows: Home's style, section visibility, firing-alert
/// notifications and the eve alert lanes.
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
                Picker("Home style", selection: Binding(
                    get: { store.homeStyle },
                    set: { store.setHomeStyle($0) }
                )) {
                    Text("The Now Line").tag(HomeStyle.nowLine)
                    Text("Now first, tiles below").tag(HomeStyle.nowFirst)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Home")
            } footer: {
                Text("What ⌥Space opens on while nothing is typed. Both draw the same Now queue: the Now Line runs every need as a bar into now, in four lanes, beside the ranked list; Now first leads with the ranked table and keeps the module tiles below it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Return to the last place for", selection: Binding(
                    get: { Int(store.homeAfter / 60) },
                    set: { store.setHomeAfterMinutes($0) }
                )) {
                    ForEach([5, 15, 30, 60, 240], id: \.self) { Text("\($0) min").tag($0) }
                }
            } header: {
                Text("Summon")
            } footer: {
                Text("⌥Space opens where you last rested for a moment — a PR's detail, a run card, a module — even after an Esc run out of it. Hidden longer than this, it opens on Home.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                Text("Hidden sections stop rendering. Eve alerts and firing alerts — and runners and devbox, hidden with /hide — also stop polling and fill again on the next refresh; the rest keep polling, so switching one back on shows current data straight away.")
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
