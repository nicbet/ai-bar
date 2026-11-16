import SwiftUI

/// The thin bar under the ring: the window the ring doesn't show, with a pace tick.
struct GaugeBarView: View {
    let gauge: UsageGauge
    let color: Color

    private var progress: Double { min(max(gauge.utilization, 0), 1) }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.1))
                        Capsule()
                            .fill(color.opacity(0.7))
                            .frame(width: max(geo.size.width * progress, 3))
                            .animation(.easeInOut(duration: 0.4), value: progress)
                    }
                    .frame(height: 5)
                    .clipShape(Capsule())

                    // Where usage would be if spread evenly over the window
                    if let pace = gauge.elapsedFraction, pace > 0.01 {
                        Capsule()
                            .fill(Color.primary.opacity(0.5))
                            .frame(width: 1.5, height: 9)
                            .offset(x: min(max(geo.size.width * pace - 0.75, 0), geo.size.width - 1.5))
                            .animation(.easeInOut(duration: 0.6), value: pace)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: 9)

            HStack(spacing: 3) {
                Text(gauge.idle ? "\(gauge.shortLabel) idle" : "\(gauge.shortLabel) \(gauge.percentText)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                if !gauge.remainingText.isEmpty {
                    Text("· \(gauge.remainingText)")
                        .font(.system(size: 10, design: .rounded))
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}
