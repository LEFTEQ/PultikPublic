import SwiftUI

/// A day as a row of thin hourly bars, scaled to the busiest hour; an hour
/// with none keeps a hairline so the day's length still reads. CI's jobs per
/// hour use the plain form, the prod board its stacked error-over-warning form.
struct HourBars: View {
    struct Stack: Equatable {
        /// Drawn on top, red.
        let error: Int
        /// Drawn beneath, orange.
        let warn: Int
    }

    private let stacks: [Stack]
    private let stacked: Bool
    private let height: CGFloat
    private let barWidth: CGFloat
    private let tint: Color
    private let label: String

    /// Plain counts (CI jobs per hour), in the secondary tone.
    init(values: [Int], height: CGFloat = 10, barWidth: CGFloat = 2.5,
         tint: Color = Color.secondary.opacity(0.7)) {
        stacks = values.map { Stack(error: 0, warn: $0) }
        stacked = false
        self.height = height
        self.barWidth = barWidth
        self.tint = tint
        label = "Jobs per hour: \(values.map(String.init).joined(separator: ", "))"
    }

    /// Errors over warnings per hour (prod log levels).
    init(stacks: [Stack], height: CGFloat = 10, barWidth: CGFloat = 2.5) {
        self.stacks = stacks
        stacked = true
        self.height = height
        self.barWidth = barWidth
        tint = .secondary
        label = "Errors and warnings per hour: "
            + stacks.map { "\($0.error)/\($0.warn)" }.joined(separator: ", ")
    }

    var body: some View {
        let peak = CGFloat(max(stacks.map { $0.error + $0.warn }.max() ?? 0, 1))
        HStack(alignment: .bottom, spacing: barWidth > 4 ? 3 : 1) {
            ForEach(Array(stacks.enumerated()), id: \.offset) { _, stack in
                bar(stack, peak: peak)
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func bar(_ stack: Stack, peak: CGFloat) -> some View {
        let total = stack.error + stack.warn
        if total == 0 {
            RoundedRectangle(cornerRadius: 0.5)
                .fill(stacked ? Color.white.opacity(0.14) : Color.secondary.opacity(0.25))
                .frame(width: barWidth, height: 1)
        } else if !stacked {
            RoundedRectangle(cornerRadius: 0.5)
                .fill(tint)
                .frame(width: barWidth, height: max(1, height * CGFloat(total) / peak))
        } else {
            let full = max(1, height * CGFloat(total) / peak)
            let errors = stack.error == 0 ? 0 : max(1, full * CGFloat(stack.error) / CGFloat(total))
            VStack(spacing: 0) {
                Rectangle().fill(Color.red.opacity(0.92)).frame(height: errors)
                Rectangle().fill(Color.orange.opacity(0.55)).frame(height: max(0, full - errors))
            }
            .frame(width: barWidth, height: full)
            .clipShape(RoundedRectangle(cornerRadius: 0.5))
        }
    }
}

extension HourBars.Stack {
    init(_ hour: HlidacDigest.Hour) {
        self.init(error: hour.error, warn: hour.warn)
    }
}
