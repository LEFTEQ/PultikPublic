import SwiftUI

/// The Settings window's shell (decision D9) — a System-Settings-shaped
/// sidebar + detail split, replacing the single 145-line Form that used to
/// be everything.
struct SettingsWindowView: View {
    let store: StatusStore
    let fanStore: FanStore

    /// Sidebar rows. `nil` selection can't happen (the list starts on
    /// `.general`), but NavigationSplitView insists on Optional anyway.
    enum Pane: String, CaseIterable, Identifiable, Hashable {
        case general, fans, displays, panel, integrations

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .fans: "Fans & Thermals"
            case .displays: "Displays"
            case .panel: "Panel"
            case .integrations: "Integrations"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .fans: "fanblades"
            case .displays: "sun.max"
            case .panel: "rectangle.3.group"
            case .integrations: "link"
            }
        }

        /// The tinted rounded square System Settings puts beside every row.
        var tint: Color {
            switch self {
            case .general: .gray
            case .fans: .blue
            case .displays: .yellow
            case .panel: .indigo
            case .integrations: .orange
            }
        }
    }

    @State private var selection: Pane? = .general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                NavigationLink(value: pane) {
                    Label {
                        Text(pane.title)
                    } icon: {
                        Image(systemName: pane.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            switch selection ?? .general {
            case .general: GeneralPane(store: store)
            case .fans: FansPane(fanStore: fanStore)
            case .displays: DisplaysPane()
            case .panel: PanelPane(store: store)
            case .integrations: IntegrationsPane(store: store)
            }
        }
        .navigationTitle(selection?.title ?? "Settings")
    }
}
