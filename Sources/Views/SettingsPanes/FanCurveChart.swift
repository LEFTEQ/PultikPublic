import Charts
import SwiftUI

/// The fan curve, drawn and editable (decision D5).
///
/// Temperature runs left to right, fan speed bottom to top as a percentage of
/// each fan's own min…max range — the same unit the deck slider uses, so one
/// curve means the same thing on fans with different envelopes.
///
/// Drag a handle to reshape the curve. The drop is what commits: `FanStore`
/// guards the shape, saves it, and re-sends it to the helper if this curve is
/// the one currently driving the fans.
struct FanCurveChart: View {
    let fanStore: FanStore
    let curveID: String

    /// Live shape while a handle is under the cursor. nil = show the store's.
    @State private var working: FanCurve?
    @State private var dragIndex: Int?
    @State private var selection: Int?

    private static let tempRange: ClosedRange<Double> = 30...100

    private var curve: FanCurve {
        working ?? fanStore.curves[curveID] ?? FanCurve.preset(curveID) ?? .balanced
    }

    /// The other presets, drawn faintly behind — the shape you're editing only
    /// means something next to the ones you're not.
    private var ghosts: [FanCurve] {
        FanCurve.presets
            .filter { $0.id != curveID }
            .map { fanStore.curves[$0.id] ?? $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            chart
                .frame(height: 220)
            legend
            controls
        }
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            // The region the guards will not let a curve enter: at 90°C and
            // up, nothing below 60% is allowed to stand (FanCurve.guarded).
            RectangleMark(
                xStart: .value("t", FanCurve.floorTempC),
                xEnd: .value("t", Self.tempRange.upperBound),
                yStart: .value("pct", 0),
                yEnd: .value("pct", FanCurve.floorPct)
            )
            .foregroundStyle(.red.opacity(0.06))

            ForEach(ghosts) { ghost in
                ForEach(sampled(ghost), id: \.tempC) { p in
                    LineMark(
                        x: .value("Temperature", p.tempC),
                        y: .value("Speed", p.pct),
                        series: .value("Curve", ghost.id)
                    )
                    .foregroundStyle(.secondary.opacity(0.22))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }

            ForEach(sampled(curve), id: \.tempC) { p in
                AreaMark(
                    x: .value("Temperature", p.tempC),
                    y: .value("Speed", p.pct)
                )
                .foregroundStyle(.linearGradient(
                    colors: [.accentColor.opacity(0.25), .accentColor.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                ))
                LineMark(
                    x: .value("Temperature", p.tempC),
                    y: .value("Speed", p.pct),
                    series: .value("Curve", curve.id)
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            ForEach(Array(curve.points.enumerated()), id: \.offset) { index, p in
                PointMark(
                    x: .value("Temperature", p.tempC),
                    y: .value("Speed", p.pct)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(selection == index ? 130 : 70)
            }

            // Where this Mac is right now — the whole point of a curve is
            // seeing your own die sitting on it.
            if let temp = fanStore.hottestCelsius {
                RuleMark(x: .value("Now", temp))
                    .foregroundStyle(.orange.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(
                    x: .value("Now", temp),
                    y: .value("Speed", curve.pct(at: temp))
                )
                .foregroundStyle(.orange)
                .symbolSize(90)
                .annotation(position: .topTrailing, spacing: 2) {
                    Text(String(format: "%.0f° → %.0f%%", temp, curve.pct(at: temp) * 100))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }
        }
        .chartXScale(domain: Self.tempRange)
        .chartYScale(domain: 0...1)
        .chartXAxis {
            AxisMarks(values: [30, 40, 50, 60, 70, 80, 90, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let t = value.as(Double.self) {
                        Text("\(Int(t))°")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let p = value.as(Double.self) {
                        Text("\(Int(p * 100))%")
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(proxy: proxy, geo: geo))
            }
        }
        // The drag overlay is mouse-only; the same edits must be reachable
        // by keyboard and assistive tech. Tab focuses the chart, ←/→ pick a
        // handle, ↑/↓ move its speed, ⌥←/⌥→ its temperature — and the
        // selected handle also gets real steppers in the controls row.
        .focusable()
        .onKeyPress { press in handleKey(press) }
        // A handle is selected from the first appearance, so the point
        // steppers below always exist — VoiceOver must never be pointed at
        // controls that require a mouse click to summon.
        .onAppear { if selection == nil, !curve.points.isEmpty { selection = 0 } }
        // Presets carry different point counts (Balanced has 6, Quiet 5) —
        // a surviving selection could index past the new curve's end.
        .onChange(of: curveID) { _, _ in
            working = nil
            dragIndex = nil
            selection = curve.points.isEmpty ? nil : 0
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fan curve editor: \(FanCurve.preset(curveID)?.name ?? curveID)")
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint("Use the point steppers below the chart to reshape the curve")
        // Adjustable: VoiceOver swipe up/down walks the selection through the
        // handles, mirroring ←/→ for keyboard users.
        .accessibilityAdjustableAction { direction in
            let count = curve.points.count
            guard count > 0 else { return }
            let delta = direction == .increment ? 1 : -1
            selection = ((selection ?? 0) + delta + count) % count
        }
    }

    /// The whole shape in words — what VoiceOver reads for the chart.
    private var accessibilitySummary: String {
        curve.points
            .map { "\(Int($0.tempC))° → \(Int($0.pct * 100))%" }
            .joined(separator: ", ")
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let count = curve.points.count
        guard count > 0 else { return .ignored }
        switch press.key {
        case .leftArrow, .rightArrow:
            let delta = press.key == .rightArrow ? 1 : -1
            if press.modifiers.contains(.option) {
                guard let index = selection else { return .ignored }
                nudge(index: index, dTemp: Double(delta), dPct: 0)
            } else if let current = selection {
                selection = (current + delta + count) % count
            } else {
                selection = delta > 0 ? 0 : count - 1
            }
            return .handled
        case .upArrow, .downArrow:
            guard let index = selection else { return .ignored }
            nudge(index: index, dTemp: 0, dPct: press.key == .upArrow ? 0.05 : -0.05)
            return .handled
        default:
            return .ignored
        }
    }

    /// Keyboard/stepper edit of one handle — same commit path as a drag drop
    /// (`updateCurve` guards, saves, re-sends when live), and the same
    /// neighbour clamps as the drag (D7: handles cannot cross).
    private func nudge(index: Int, dTemp: Double, dPct: Double) {
        var shape = curve
        guard shape.points.indices.contains(index) else { return }
        let lower = index > 0
            ? shape.points[index - 1].tempC + 1 : Self.tempRange.lowerBound
        let upper = index < shape.points.count - 1
            ? shape.points[index + 1].tempC - 1 : Self.tempRange.upperBound
        shape.points[index].tempC = min(max(shape.points[index].tempC + dTemp, lower),
                                        max(lower, upper))
        shape.points[index].pct = min(max(shape.points[index].pct + dPct, 0), 1)
        fanStore.updateCurve(shape)
    }

    // MARK: - Editing

    private func dragGesture(proxy: ChartProxy, geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard let plot = proxy.plotFrame else { return }
                let rect = geo[plot]
                var shape = working ?? curve

                // Grab on first change and keep that handle for the whole
                // drag — re-picking the nearest point mid-drag makes a slow
                // drag hop between neighbours.
                if dragIndex == nil {
                    guard let hit = nearestPoint(to: drag.startLocation,
                                                 in: shape, proxy: proxy, rect: rect)
                    else { return }
                    dragIndex = hit
                    selection = hit
                }
                guard let index = dragIndex, shape.points.indices.contains(index) else { return }

                let x = drag.location.x - rect.minX
                let y = drag.location.y - rect.minY
                guard let temp = proxy.value(atX: x, as: Double.self),
                      let pct = proxy.value(atY: y, as: Double.self) else { return }

                // Clamped between the neighbours so a handle can't be dragged
                // through the one beside it; the full guard runs on drop.
                let lower = index > 0 ? shape.points[index - 1].tempC + 1 : Self.tempRange.lowerBound
                let upper = index < shape.points.count - 1
                    ? shape.points[index + 1].tempC - 1 : Self.tempRange.upperBound
                shape.points[index].tempC = min(max(temp, lower), max(lower, upper))
                shape.points[index].pct = min(max(pct, 0), 1)
                working = shape
            }
            .onEnded { _ in
                if let shape = working { fanStore.updateCurve(shape) }
                working = nil
                dragIndex = nil
            }
    }

    /// Index of the handle under `location`, or nil if the click landed on
    /// empty chart. 22pt of slop — these are 8pt dots.
    private func nearestPoint(to location: CGPoint, in shape: FanCurve,
                              proxy: ChartProxy, rect: CGRect) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, p) in shape.points.enumerated() {
            guard let px = proxy.position(forX: p.tempC),
                  let py = proxy.position(forY: p.pct) else { continue }
            let dx = location.x - (px + rect.minX)
            let dy = location.y - (py + rect.minY)
            let distance = sqrt(dx * dx + dy * dy)
            if distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (index, distance)
            }
        }
        guard let best, best.distance <= 22 else { return nil }
        return best.index
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                addPoint()
            } label: {
                Label("Add point", systemImage: "plus")
            }
            .help("Split the widest gap in the curve with a new handle")

            Button {
                removeSelected()
            } label: {
                Label("Remove", systemImage: "minus")
            }
            .disabled(selection == nil || curve.points.count <= 2)
            .help("Delete the selected handle — click one first")

            if let index = selection, curve.points.indices.contains(index) {
                let point = curve.points[index]
                Stepper("\(Int(point.tempC))°",
                        onIncrement: { nudge(index: index, dTemp: 1, dPct: 0) },
                        onDecrement: { nudge(index: index, dTemp: -1, dPct: 0) })
                    .accessibilityLabel("Point \(index + 1) temperature")
                    .accessibilityValue("\(Int(point.tempC)) degrees")
                Stepper("\(Int(point.pct * 100))%",
                        onIncrement: { nudge(index: index, dTemp: 0, dPct: 0.05) },
                        onDecrement: { nudge(index: index, dTemp: 0, dPct: -0.05) })
                    .accessibilityLabel("Point \(index + 1) speed")
                    .accessibilityValue("\(Int(point.pct * 100)) percent")
            }

            Spacer()

            Button("Restore default") {
                fanStore.restoreCurveDefault(curveID)
                working = nil
                selection = nil
            }
            .disabled(!fanStore.curveIsEdited(curveID))
            .help("Throw away your edits to this preset")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(color: .accentColor, text: FanCurve.preset(curveID)?.name ?? curveID)
            legendItem(color: .secondary.opacity(0.4), text: "other presets")
            if fanStore.hottestCelsius != nil {
                legendItem(color: .orange, text: "this Mac now")
            }
            legendItem(color: .red.opacity(0.25),
                       text: "not allowed — ≥\(Int(FanCurve.floorTempC))° holds \(Int(FanCurve.floorPct * 100))%")
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
    }

    /// New handle in the middle of the widest temperature gap, sitting exactly
    /// on the existing line — adding a point should change the shape by nothing
    /// until it's dragged.
    private func addPoint() {
        var shape = curve
        guard shape.points.count >= 2 else { return }
        var widest = (index: 0, span: 0.0)
        for i in 0..<(shape.points.count - 1) {
            let span = shape.points[i + 1].tempC - shape.points[i].tempC
            if span > widest.span { widest = (i, span) }
        }
        guard widest.span >= 4 else { return }
        let temp = shape.points[widest.index].tempC + widest.span / 2
        shape.points.insert(CurvePoint(tempC: temp, pct: shape.pct(at: temp)),
                            at: widest.index + 1)
        fanStore.updateCurve(shape)
        selection = widest.index + 1
    }

    private func removeSelected() {
        guard let index = selection else { return }
        var shape = curve
        guard shape.points.indices.contains(index), shape.points.count > 2 else { return }
        shape.points.remove(at: index)
        fanStore.updateCurve(shape)
        selection = nil
    }

    /// The curve as a dense polyline. Charts interpolates straight between
    /// marks anyway, but sampling keeps the drawn line identical to what
    /// `pct(at:)` returns — including the flat runs outside the end points,
    /// which a 5-mark line would simply not draw.
    private func sampled(_ shape: FanCurve) -> [CurvePoint] {
        stride(from: Self.tempRange.lowerBound, through: Self.tempRange.upperBound, by: 1)
            .map { CurvePoint(tempC: $0, pct: shape.pct(at: $0)) }
    }
}
