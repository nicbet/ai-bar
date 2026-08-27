import SwiftUI

struct RingProgressView: View {
    let progress: Double
    let colors: (Color, Color)
    let size: CGFloat
    let lineWidth: CGFloat
    var pacePosition: Double? = nil

    init(progress: Double, colors: (Color, Color), size: CGFloat = 100, lineWidth: CGFloat = 10,
         pacePosition: Double? = nil) {
        self.progress = progress
        self.colors = colors
        self.size = size
        self.lineWidth = lineWidth
        self.pacePosition = pacePosition
    }

    private var displayProgress: Double { min(max(progress, 0), 1.0) }

    private var gradient: LinearGradient {
        LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: displayProgress)
                .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: displayProgress)

            if displayProgress > 0 {
                Circle()
                    .trim(from: 0, to: displayProgress)
                    .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth + 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .blur(radius: 6)
                    .opacity(0.3)
                    .animation(.easeInOut(duration: 0.6), value: displayProgress)
            }

            if let pace = pacePosition, pace > 0.01 {
                PaceMarkerDot(position: pace, ringSize: size, lineWidth: lineWidth)
            }

            Text("\(Int(progress * 100))%")
                .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.4), value: Int(progress * 100))
        }
        .frame(width: size, height: size)
    }
}

private struct PaceMarkerDot: View {
    let position: Double
    let ringSize: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        let angle = Angle.degrees(position * 360 - 90)
        let innerRadius = (ringSize - lineWidth) / 2 - lineWidth * 0.4
        let outerRadius = (ringSize - lineWidth) / 2 + lineWidth * 0.4
        let ix = innerRadius * cos(angle.radians)
        let iy = innerRadius * sin(angle.radians)
        let ox = outerRadius * cos(angle.radians)
        let oy = outerRadius * sin(angle.radians)

        Path { path in
            path.move(to: CGPoint(x: ringSize / 2 + ix, y: ringSize / 2 + iy))
            path.addLine(to: CGPoint(x: ringSize / 2 + ox, y: ringSize / 2 + oy))
        }
        .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .animation(.easeInOut(duration: 0.6), value: position)
    }
}

#Preview {
    HStack(spacing: 30) {
        RingProgressView(progress: 0.42, colors: (.indigo, .purple), pacePosition: 0.3)
        RingProgressView(progress: 0.15, colors: (.green, .mint), pacePosition: 0.5)
    }
    .padding(40)
}
