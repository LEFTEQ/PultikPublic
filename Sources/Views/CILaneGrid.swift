import SwiftUI

/// One host's Docker pool above its lanes (that host's Semafor admission
/// board): slots and reserved memory against the budget, then the queue's
/// head — the lane that places next — with its repo tier and kind. Hidden
/// when that Semafor did not answer; dimmed when its numbers are older than
/// `CIPoolGlance.staleAfter`.
struct PoolRow: View {
    let pool: CIPool

    var body: some View {
        let glance = CIPoolGlance(pool: pool)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text("pool").foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .leading)
                Text("\(glance.slots) · \(glance.memory)")
                    .foregroundStyle(glance.full ? Color.orange : Color.secondary)
                    .lineLimit(1)
                if glance.stale {
                    Text("stale").foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .help(glance.stale
                ? "This host's CI pool — its Semafor's newest controller reading is over \(Int(CIPoolGlance.staleAfter / 60)) min old"
                : "This host's CI pool (its own Semafor): live jobs / \(pool.slotsMax) slots and reserved / budgeted memory; no lane has a ceiling of its own")
            if let head = glance.head {
                HStack(spacing: 6) {
                    Text("next").foregroundStyle(.tertiary)
                        .frame(width: 30, alignment: .leading)
                    Text(head)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .help("Head of the priority queue (repo tier, then kind ci · build · e2e, then age): the waiter that places next")
            }
        }
        .font(.system(size: 9.5, design: .monospaced))
        .opacity(glance.stale ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}
