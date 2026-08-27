import SwiftUI

struct WeeklyBarView: View {
    let progress: Double
    let color: Color
    let resetText: String

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(color.opacity(0.7))
                        .frame(width: max(geo.size.width * min(max(progress, 0), 1), 3))
                        .animation(.easeInOut(duration: 0.4), value: progress)
                }
            }
            .frame(height: 5)
            .clipShape(Capsule())

            HStack(spacing: 3) {
                Text("Weekly \(Int(progress * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                if !resetText.isEmpty {
                    Text("· \(resetText)")
                        .font(.system(size: 10, design: .rounded))
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}
