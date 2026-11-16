import SwiftUI

/// The status strip across the panel's bottom edge.
///
/// It is supporting chrome rather than the panel's primary hierarchy: search
/// and the grouped inbox own the top edge, while freshness and
/// window actions close the panel as one stable full-width footer. CI's totals
/// moved to the right rail's CI section (spec 2026-09-23, D10).
///
/// One line by contract, same as the footer was: every child is lineLimit(1)
/// and fixed-shape, because an overflowing cell in a fixed frame makes SwiftUI
/// wrap character-by-character and balloons the strip into a column of glyphs.
struct PanelFooter: View {
    let store: StatusStore
    var macHealth: MacHealthStore = .shared
    var onMacHealth: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            refreshState
            Spacer(minLength: 8)
            if let chip = macHealth.status.chip {
                MacHealthFooterChip(chip: chip, onOpen: onMacHealth)
            }
            Text("Pultík \(Self.version)")
                .font(Theme.Typo.meta)
                .foregroundStyle(Theme.ink3)
            actions
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 9)
        .lineLimit(1)
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    /// Sync state leads the footer (DESIGN.md §8 StatusFooter): `Synced 15:12`.
    @ViewBuilder
    private var refreshState: some View {
        HStack(spacing: 5) {
            // Still, like every status glyph: some lane is nearly always
            // refreshing, so a spinner here redrew the panel every frame.
            if store.isRefreshing {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9.5))
                Text("Syncing")
            } else {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9.5))
                if let last = store.lastRefresh {
                    Text("Synced \(PultikFormat.clock(last))").monospacedDigit()
                } else {
                    Text("Not synced yet")
                }
            }
        }
        .font(Theme.Typo.meta)
        .foregroundStyle(Theme.ink2)
        // Icon only — error PROSE never renders in the strip (lean and fixed-
        // shape); the text lives in the hover popover.
        if let error = store.globalError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.danger)
                .help(error)
        }
        // A paused breaker is why a rail is missing. Without this the sections
        // just vanish and the app looks broken instead of deliberately quiet.
        if ProbeGate.shared.isPaused {
            Image(systemName: "pause.circle")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.warn)
                .help("Probes paused — refresh to retry now\n\n" + ProbeGate.shared.summary)
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            ChromeButton(symbol: "arrow.clockwise", help: "Refresh now") {
                // The one path that may knock on a host that just refused us:
                // a person clicked. Opening the panel deliberately does NOT
                // clear the breakers — that would poll on every summon.
                ProbeGate.shared.resumeAll()
                Task { await store.refresh() }
            }
            .disabled(store.isRefreshing)
            ChromeButton(symbol: "gearshape", help: "Settings") {
                AppDelegate.shared?.openSettings()
            }
            ChromeButton(symbol: "power", help: "Quit Pultík") {
                AppDelegate.shared?.quit()
            }
        }
    }
}

private struct ChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - Mac health

/// toolkit's Mac health headline, verbatim — only while a fresh report flags
/// something (`MacHealthStatus.chip`); a healthy Mac or a silent watch
/// draws nothing. The hover lists the worst findings, a click opens `.mac`.
struct MacHealthFooterChip: View {
    let chip: MacHealthChip
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 5) {
                Circle()
                    .fill(MacHealthTone.color(chip.severity))
                    .frame(width: 6, height: 6)
                Text(chip.text)
                    .font(.system(size: 9.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(chip.help)
        .accessibilityLabel("Mac health: \(chip.text)")
    }
}
