import SwiftUI

/// The integrations hub: every outside thing Pultík talks to, one row each,
/// rendered generically from the `IntegrationRegistry`. Statuses come from
/// state the app already holds (ProbeGate, keychain presence, EventKit
/// authorization) — opening this pane never probes anything; Test does, once,
/// through the breaker.
struct IntegrationsPane: View {
    let store: StatusStore

    @State private var registry: IntegrationRegistry?
    @State private var expanded: Set<String> = []

    var body: some View {
        Form {
            Section {
                ForEach((registry?.all ?? []), id: \.id) { integration in
                    IntegrationRow(
                        integration: integration,
                        isExpanded: expanded.contains(integration.id)
                    ) {
                        if expanded.contains(integration.id) {
                            expanded.remove(integration.id)
                        } else {
                            expanded.insert(integration.id)
                        }
                    }
                }
            } footer: {
                Text("Sentry and iCloud secrets live in the login keychain; the eve token is still in settings.json (Onyx keeps the human copies either way). Statuses are passive — the Test buttons are the only thing here that touches the network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if registry == nil { registry = IntegrationRegistry(store: store) }
        }
    }
}

private struct IntegrationRow: View {
    let integration: any Integration
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Test is a SIBLING of the disclosure button, never nested inside
            // it: a control inside a control gives VoiceOver an ambiguous
            // hierarchy and steals keyboard activation from one of the two.
            HStack(spacing: 8) {
                Button(action: onToggle) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Image(systemName: integration.symbol)
                            .font(.system(size: 12))
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text(integration.title)
                            .font(.system(size: 13))
                        Spacer()
                        if integration.status == .testing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle()
                                .fill(integration.status.dotColor)
                                .frame(width: 7, height: 7)
                        }
                        Text(integration.status.line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 260, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(integration.title), \(integration.status.line)")
                .accessibilityHint(isExpanded ? "Collapse details" : "Expand details")
                if integration.canTest {
                    Button("Test") {
                        Task { await integration.test() }
                    }
                    .controlSize(.small)
                    .disabled(integration.status == .testing)
                    .accessibilityLabel("Test \(integration.title)")
                }
            }
            if isExpanded {
                integration.detail
                    .padding(.leading, 43)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 2)
        .animation(.easeOut(duration: 0.15), value: isExpanded)
    }
}
