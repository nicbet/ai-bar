import SwiftUI
import Charts

enum TimeRange: String, CaseIterable, Identifiable {
    case day = "24h"
    case week = "7d"
    case month = "30d"

    var id: String { rawValue }
    var since: Date {
        switch self {
        case .day:   return Calendar.current.date(byAdding: .hour, value: -24, to: Date())!
        case .week:  return Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        }
    }
}

struct DetailView: View {
    let serviceName: String
    @EnvironmentObject var manager: UsageManager
    @State private var timeRange: TimeRange = .day
    @State private var sessionData: [UsageSnapshot] = []
    @State private var weeklyData: [UsageSnapshot] = []

    private var usage: ServiceUsage {
        serviceName == "claude" ? manager.claude : manager.codex
    }

    private var brandColors: (Color, Color) {
        serviceName == "claude" ? (.claudeOrange, .claudeBrown) : (.codexBlue, .codexBlueDark)
    }

    private var displayName: String {
        serviceName == "claude" ? "Claude" : "Codex"
    }

    private var sessionWindowType: String {
        serviceName == "claude" ? "five_hour" : "primary"
    }

    private var weeklyWindowType: String {
        serviceName == "claude" ? "seven_day" : "secondary"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusHeader
                timeRangePicker

                chartSection(title: "Session Usage (5h window)", data: sessionData, color: brandColors.0)

                if !weeklyData.isEmpty {
                    chartSection(title: "Weekly Usage", data: weeklyData, color: brandColors.1)
                }

                if manager.showEstimatedCost {
                    costBreakdownSection
                }
            }
            .padding(24)
        }
        .frame(minWidth: 480, minHeight: 400)
        .background(.regularMaterial)
        .navigationTitle("\(displayName) Usage")
        .onAppear { loadData() }
        .onChange(of: timeRange) { _, _ in loadData() }
    }

    private var statusHeader: some View {
        HStack(spacing: 16) {
            SVGPathShape(pathData: serviceName == "claude" ? BrandIcons.claudePath : BrandIcons.codexPath,
                         viewBox: BrandIcons.viewBox)
                .fill(.primary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.bold)
                if !usage.formattedUsage.isEmpty {
                    Text(usage.formattedUsage)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(usage.percentInt)%")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(brandColors.0)

                    paceLabel
                }

                if let wu = usage.weeklyUtilization {
                    Text("Weekly: \(Int(wu * 100))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    private var paceLabel: some View {
        Group {
            let level = usage.paceLevel
            if level != .unknown {
                let text: String = {
                    switch level {
                    case .underPace:     return "Under pace"
                    case .onPace:        return "On pace"
                    case .slightlyAhead: return "Ahead"
                    case .burningFast:   return "Burning fast"
                    case .unknown:       return ""
                    }
                }()
                Text(text)
                    .font(.system(.caption2, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(level.color.opacity(0.2)))
                    .foregroundStyle(level.color)
            }
        }
    }

    private var timeRangePicker: some View {
        Picker("Time Range", selection: $timeRange) {
            ForEach(TimeRange.allCases) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 200)
    }

    private func chartSection(title: String, data: [UsageSnapshot], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            if data.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "chart.line.downtrend.xyaxis")
                            .font(.system(size: 28))
                            .foregroundStyle(.quaternary)
                        Text("No data yet")
                            .font(.system(.caption))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 40)
                    Spacer()
                }
            } else {
                Chart(data) { snapshot in
                    AreaMark(
                        x: .value("Time", snapshot.timestamp),
                        y: .value("Usage", snapshot.utilization * 100)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.3), color.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Time", snapshot.timestamp),
                        y: .value("Usage", snapshot.utilization * 100)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text("\(v)%")
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                        AxisValueLabel()
                    }
                }
                .frame(height: 180)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
    }

    @ViewBuilder
    private var costBreakdownSection: some View {
        let models = serviceName == "claude" ? manager.dailyCost.claudeModels : manager.dailyCost.codexModels
        let serviceCost = serviceName == "claude" ? manager.dailyCost.claudeCost : manager.dailyCost.codexCost

        VStack(alignment: .leading, spacing: 8) {
            Text("Estimated API Cost (Today)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            if models.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "dollarsign.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(.quaternary)
                        Text("No usage today")
                            .font(.system(.caption))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                ForEach(models) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.model)
                                .font(.system(.caption, design: .monospaced))
                            Text("\(formatTokenCount(entry.inputTokens)) in · \(formatTokenCount(entry.outputTokens)) out")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(formatCost(entry.cost))
                            .font(.system(.body, design: .rounded))
                            .fontWeight(.medium)
                            .foregroundStyle(brandColors.0)
                    }
                }

                Divider()

                HStack {
                    Text("Total")
                        .font(.system(.caption, design: .rounded))
                        .fontWeight(.semibold)
                    Spacer()
                    Text("≈ \(formatCost(serviceCost))")
                        .font(.system(.body, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundStyle(brandColors.0)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
    }

    private func loadData() {
        let since = timeRange.since
        sessionData = HistoryStore.shared.snapshots(
            service: serviceName, windowType: sessionWindowType, since: since)
        weeklyData = HistoryStore.shared.snapshots(
            service: serviceName, windowType: weeklyWindowType, since: since)
    }
}
