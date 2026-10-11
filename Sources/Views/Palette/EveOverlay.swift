import SwiftUI

// MARK: - Eve reply overlay

/// Floats over the dashboard (dim scrim behind), grows with the reply, and
/// expands to near-full panel height on demand — the inbox never squeezes.
struct EveOverlay: View {
    let prompt: String
    let reply: String
    let done: Bool
    let error: String?
    @Binding var expanded: Bool
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            // Scrim: click to collapse/dismiss, dims the dashboard below.
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("✦").foregroundStyle(Theme.eve)
                    Text("eve")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .kerning(1.3)
                        .foregroundStyle(.secondary)
                    Text("· \(prompt)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    if !done {
                        ProgressView().controlSize(.mini)
                    }
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help(expanded ? "Collapse" : "Expand")
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help("Dismiss (Esc)")
                }

                if let error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                } else if reply.isEmpty {
                    Text(done ? "no answer" : "thinking…")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        Text(LocalizedStringKey(reply))
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: expanded ? 520 : 240)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .background(Theme.eveSoft, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.eve.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }
}
