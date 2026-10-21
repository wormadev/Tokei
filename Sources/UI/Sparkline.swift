import Charts
import SwiftUI

/// Last 7 days of one window's usage. No axes: it shows the shape, the bar shows the number.
struct Sparkline: View {
    let points: [History.Point]

    var body: some View {
        Chart(points, id: \.date) { point in
            AreaMark(x: .value("Time", point.date), y: .value("Used", point.used))
                .foregroundStyle(Color.primary.opacity(0.12))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", point.date), y: .value("Used", point.used))
                .foregroundStyle(Color.primary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0 ... max(1, points.map(\.used).max() ?? 1))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}
