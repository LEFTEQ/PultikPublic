import SwiftUI

/// Settings ▸ Modules (stay in Pultík D4, N1): the nine modules in the
/// strip's order — drag to reorder (the strip and ⌘1–9 follow, Home stays
/// first) — each with keep hot and its refresh speed while visible.
struct ModulesPane: View {
    let store: StatusStore

    var body: some View {
        Form {
            Section {
                List {
                    ForEach(store.moduleSettings) { setting in
                        if let module = setting.module { row(module, setting) }
                    }
                    .onMove(perform: move)
                }
                .frame(minHeight: 330)
            } header: {
                Text("Modules")
            } footer: {
                Text("Drag to reorder: the strip and ⌘1–9 follow, Home stays first. A hot module stays built while the panel is open, so switching to it is instant; the last three you visited are warm anyway. Refresh speed applies while the module is on screen — hidden modules keep the shared 30 s / 90 s cadence, and GitHub is never polled faster than every 30 s.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ module: PanelModule, _ setting: ModuleSetting) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: "⌘\(module.number(in: store.moduleOrder))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            Image(systemName: module.symbol)
                .frame(width: 18)
            Text(module.title)
            Spacer()
            Toggle("Keep hot", isOn: Binding(
                get: { setting.keepHot },
                set: { hot in update(module) { $0.keepHot = hot } }
            ))
            .toggleStyle(.checkbox)
            Picker("Refresh", selection: Binding(
                get: { setting.visibleRefresh },
                set: { speed in update(module) { $0.visibleRefresh = speed } }
            )) {
                ForEach(ModuleSetting.Refresh.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
            .disabled(StatusStore.moduleLanes[module]?.isEmpty ?? true)
        }
        .moveDisabled(module == .home)
    }

    private func update(_ module: PanelModule, _ change: (inout ModuleSetting) -> Void) {
        var settings = store.moduleSettings
        guard let index = settings.firstIndex(where: { $0.module == module }) else { return }
        change(&settings[index])
        store.setModuleSettings(settings)
    }

    private func move(_ from: IndexSet, _ to: Int) {
        var settings = store.moduleSettings
        settings.move(fromOffsets: from, toOffset: max(to, 1))
        store.setModuleSettings(settings)
    }
}
