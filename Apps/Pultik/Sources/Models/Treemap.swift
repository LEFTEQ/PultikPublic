import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing, van Wijk 2000): tiles whose
/// areas are proportional to their values, laid in rows along the free
/// rectangle's shorter side, each row grown only while that keeps its worst
/// aspect ratio improving. Pure — the Mac health page draws whatever this
/// returns.
enum Treemap {
    /// One rect per value, in the input's order. Zero and negative values get
    /// `.zero`; the rest tile `rect` exactly, without overlap.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: values.count)
        let order = values.indices.filter { values[$0] > 0 }.sorted { values[$0] > values[$1] }
        let total = order.reduce(0) { $0 + values[$1] }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }

        let scale = Double(rect.width * rect.height) / total
        let areas = order.map { values[$0] * scale }
        var free = rect
        var start = 0
        while start < areas.count {
            let side = Double(min(free.width, free.height))
            var end = start + 1
            var best = worst(areas[start..<end], side: side)
            while end < areas.count {
                let next = worst(areas[start...end], side: side)
                if next > best { break }
                best = next
                end += 1
            }
            let row = areas[start..<end]
            let rowArea = row.reduce(0, +)
            // The last row takes whatever is left, so rounding never leaves
            // a sliver uncovered at the far edge.
            let last = end == areas.count
            if free.width >= free.height {
                // A column against the left edge, tiles stacked downwards.
                let width = last ? Double(free.width) : rowArea / Double(free.height)
                var y = Double(free.minY)
                for (offset, area) in row.enumerated() {
                    let height = area / width
                    result[order[start + offset]] = CGRect(x: Double(free.minX), y: y, width: width, height: height)
                    y += height
                }
                free = CGRect(x: free.minX + width, y: free.minY,
                              width: max(0, free.width - width), height: free.height)
            } else {
                // A row along the top edge, tiles laid rightwards.
                let height = last ? Double(free.height) : rowArea / Double(free.width)
                var x = Double(free.minX)
                for (offset, area) in row.enumerated() {
                    let width = area / height
                    result[order[start + offset]] = CGRect(x: x, y: Double(free.minY), width: width, height: height)
                    x += width
                }
                free = CGRect(x: free.minX, y: free.minY + height,
                              width: free.width, height: max(0, free.height - height))
            }
            start = end
        }
        return result
    }

    /// The row's worst aspect ratio when laid along a side of this length.
    private static func worst(_ row: ArraySlice<Double>, side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard let largest = row.max(), let smallest = row.min(), sum > 0, smallest > 0 else { return .infinity }
        let side2 = side * side
        let sum2 = sum * sum
        return max(side2 * largest / sum2, sum2 / (side2 * smallest))
    }
}
