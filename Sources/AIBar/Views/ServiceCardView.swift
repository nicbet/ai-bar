import SwiftUI

struct ServiceCardView: View {
    let name: String
    let iconPath: String
    let usage: ServiceUsage
    let colors: (Color, Color)

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            NSApp.activate()
            openWindow(id: "service-detail", value: name.lowercased())
        } label: {
            VStack(spacing: 8) {
                RingProgressView(
                    progress: usage.percentage,
                    colors: colors,
                    size: 96,
                    lineWidth: 9,
                    pacePosition: usage.elapsedFraction
                )

                HStack(spacing: 5) {
                    SVGPathShape(pathData: iconPath, viewBox: BrandIcons.viewBox)
                        .fill(.primary)
                        .frame(width: 14, height: 14)
                    Text(name)
                        .font(.system(.headline, design: .rounded))
                        .fontWeight(.semibold)
                }

                if let err = usage.lastError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9))
                        Text(err)
                            .font(.system(.caption2, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.orange)
                } else if !usage.formattedUsage.isEmpty {
                    Text(usage.formattedUsage)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.tertiary)
                }

                if usage.weeklyUtilization != nil {
                    WeeklyBarView(
                        progress: usage.weeklyPercentage,
                        color: colors.0,
                        resetText: usage.formattedWeeklyReset
                    )
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

#Preview {
    HStack(spacing: 20) {
        ServiceCardView(
            name: "Claude",
            iconPath: BrandIcons.claudePath,
            usage: ServiceUsage(
                utilization: 0.42, resetsAt: Date().addingTimeInterval(3600 * 3),
                windowDuration: 18000, weeklyUtilization: 0.04,
                weeklyResetsAt: Date().addingTimeInterval(86400 * 5)
            ),
            colors: (.claudeOrange, .claudeBrown)
        )
    }
    .padding(30)
}
