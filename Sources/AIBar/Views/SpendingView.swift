import SwiftUI
import Charts

enum SpendingRange: String, CaseIterable, Identifiable {
    case twoWeeks = "14d"
    case month = "30d"
    case quarter = "90d"

    var id: String { rawValue }
    var days: Int {
        switch self {
        case .twoWeeks: return 14
        case .month:    return 30
        case .quarter:  return 90
        }
    }
}

private struct DailyServiceCost: Identifiable {
    let day: Date
    let service: String
    let cost: Double
    var id: String { "\(CostEstimator.dayKey(day))-\(service)" }
}

struct SpendingView: View {
    @EnvironmentObject var manager: UsageManager
    @State private var range: SpendingRange = .twoWeeks
    @State private var history: [String: DailyCostSummary] = [:]
    @State private var selectedDay: String = CostEstimator.dayKey(Date())
    /// Fixed history for screenshots; when set, the history store is never read
    private let previewHistory: [String: DailyCostSummary]?

    init(previewHistory: [String: DailyCostSummary]? = nil, range: SpendingRange = .twoWeeks, selectedDay: String? = nil) {
        self.previewHistory = previewHistory
        _history = State(initialValue: previewHistory ?? [:])
        _range = State(initialValue: range)
        _selectedDay = State(initialValue: selectedDay ?? CostEstimator.dayKey(Date()))
    }

    private var todayKey: String { CostEstimator.dayKey(Date()) }

    private var startDate: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: -(range.days - 1), to: today) ?? today
    }

    /// Stored history with today's live summary layered on top
    private var summaries: [String: DailyCostSummary] {
        var s = history
        s[todayKey] = manager.dailyCost
        return s
    }

    private var chartData: [DailyServiceCost] {
        summaries.compactMap { key, summary -> [DailyServiceCost]? in
            guard let day = CostEstimator.date(fromDayKey: key), day >= startDate else { return nil }
            return [
                DailyServiceCost(day: day, service: "Claude", cost: summary.claudeCost),
                DailyServiceCost(day: day, service: "Codex", cost: summary.codexCost),
            ].filter { $0.cost > 0 }
        }.flatMap { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statsRow
                chart
                ReceiptView(
                    day: CostEstimator.date(fromDayKey: selectedDay) ?? Date(),
                    summary: summaries[selectedDay] ?? .empty,
                    onPrevious: { shiftSelection(by: -1) },
                    onNext: selectedDay < todayKey ? { shiftSelection(by: 1) } : nil
                )
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
        .frame(minWidth: 480, minHeight: 560)
        .background(.regularMaterial)
        .navigationTitle("API Spending")
        .onAppear {
            guard previewHistory == nil else { return }
            selectedDay = todayKey
            loadHistory()
        }
        .onChange(of: range) { _, _ in loadHistory() }
        .onChange(of: manager.costHistoryRevision) { _, _ in loadHistory() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("API Spending")
                .font(.system(.title2, design: .rounded))
                .fontWeight(.bold)
            Spacer()
            Button("Today") { selectedDay = todayKey }
                .disabled(selectedDay == todayKey)
            Picker("Range", selection: $range) {
                ForEach(SpendingRange.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
        }
    }

    private var statsRow: some View {
        let total = chartData.reduce(0) { $0 + $1.cost }
        let daysWithData = Set(chartData.map(\.day)).count
        return HStack(spacing: 12) {
            StatTile(label: "Total (\(range.rawValue))", value: formatCost(total))
            StatTile(label: "Avg / active day",
                     value: daysWithData > 0 ? formatCost(total / Double(daysWithData)) : "—")
            StatTile(label: "Today", value: formatCost(manager.dailyCost.totalCost))
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily estimated cost · click a day for its receipt")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            if chartData.isEmpty {
                HStack {
                    Spacer()
                    Text("No usage in this range")
                        .font(.system(.caption))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 60)
                    Spacer()
                }
            } else {
                Chart(chartData) { item in
                    BarMark(
                        x: .value("Day", item.day, unit: .day),
                        y: .value("Cost", item.cost)
                    )
                    .foregroundStyle(by: .value("Service", item.service))
                    .opacity(CostEstimator.dayKey(item.day) == selectedDay ? 1 : 0.45)
                }
                .chartForegroundStyleScale(["Claude": Color.claudeOrange, "Codex": Color.codexBlue])
                .chartXScale(domain: startDate...Calendar.current.date(byAdding: .day, value: 1,
                                                                       to: Calendar.current.startOfDay(for: Date()))!)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(v >= 1 ? String(format: "$%.0f", v) : String(format: "$%.2f", v))
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let x = location.x - geo[plotFrame].origin.x
                                if let date: Date = proxy.value(atX: x) {
                                    let key = CostEstimator.dayKey(date)
                                    if key <= todayKey { selectedDay = key }
                                }
                            }
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                    }
                }
                .frame(height: 180)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
    }

    private func shiftSelection(by days: Int) {
        guard let current = CostEstimator.date(fromDayKey: selectedDay),
              let next = Calendar.current.date(byAdding: .day, value: days, to: current) else { return }
        let key = CostEstimator.dayKey(next)
        if key <= todayKey { selectedDay = key }
    }

    private func loadHistory() {
        guard previewHistory == nil else { return }
        let since = CostEstimator.dayKey(Calendar.current.date(
            byAdding: .day, value: -SpendingRange.quarter.days, to: Date()) ?? Date())
        history = HistoryStore.shared.costHistory(since: since)
    }
}

private struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
    }
}

// MARK: - Receipt

struct ReceiptView: View {
    let day: Date
    let summary: DailyCostSummary
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    private let mono = Font.system(size: 11, design: .monospaced)

    var body: some View {
        VStack(spacing: 10) {
            receiptHeader
            DashedRule()

            if summary.totalCost == 0 {
                Text("NO USAGE RECORDED")
                    .font(mono)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                if !summary.claudeModels.isEmpty {
                    section(title: "CLAUDE", entries: summary.claudeModels, subtotal: summary.claudeCost)
                }
                if !summary.codexModels.isEmpty {
                    if !summary.claudeModels.isEmpty { DashedRule() }
                    section(title: "CODEX", entries: summary.codexModels, subtotal: summary.codexCost)
                }
            }

            DoubleRule()
            HStack {
                Text("TOTAL")
                Spacer()
                Text(formatCost(summary.totalCost))
            }
            .font(.system(size: 15, weight: .bold, design: .monospaced))
            DoubleRule()

            VStack(spacing: 2) {
                Text("Estimated at published API list prices.")
                Text("This is not a bill.")
                Text("*** THANK YOU ***").padding(.top, 6)
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(Color(nsColor: .textColor))
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .background(
            ReceiptPaper()
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        )
    }

    private var receiptHeader: some View {
        VStack(spacing: 4) {
            Text("AI BAR")
                .font(.system(size: 16, weight: .heavy, design: .monospaced))
            Text("ESTIMATED API USAGE")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack {
                Button { onPrevious?() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .disabled(onPrevious == nil)
                    .opacity(onPrevious == nil ? 0.2 : 0.6)
                Spacer()
                Text(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()).uppercased())
                    .font(mono)
                Spacer()
                Button { onNext?() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                    .disabled(onNext == nil)
                    .opacity(onNext == nil ? 0.2 : 0.6)
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.top, 4)
        }
    }

    private func section(title: String, entries: [ModelCostEntry], subtotal: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))

            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(entry.model).lineLimit(1)
                        DottedLeader()
                        Text(formatCost(entry.cost))
                    }
                    .font(mono)

                    Text("  @ \(formatTokenCount(entry.totalTokens)) tokens")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("    \(tokenBreakdown(entry))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            HStack {
                Spacer()
                Text("SUBTOTAL  \(formatCost(subtotal))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tokenBreakdown(_ e: ModelCostEntry) -> String {
        var parts = ["in \(formatTokenCount(e.inputTokens))", "out \(formatTokenCount(e.outputTokens))"]
        if e.cacheWriteTokens > 0 { parts.append("c.write \(formatTokenCount(e.cacheWriteTokens))") }
        if e.cacheReadTokens > 0 { parts.append("c.read \(formatTokenCount(e.cacheReadTokens))") }
        return parts.joined(separator: " · ")
    }
}

private struct DottedLeader: View {
    var body: some View {
        Line()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
            .foregroundStyle(.tertiary)
            .frame(height: 1)
    }
}

private struct DashedRule: View {
    var body: some View {
        Line()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(.tertiary)
            .frame(height: 1)
    }
}

private struct DoubleRule: View {
    var body: some View {
        VStack(spacing: 2) {
            Rectangle().frame(height: 1)
            Rectangle().frame(height: 1)
        }
        .foregroundStyle(.secondary)
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// Paper with a torn zigzag bottom edge
private struct ReceiptPaper: Shape {
    var toothWidth: CGFloat = 10
    var toothHeight: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - toothHeight))
        let teeth = max(Int(rect.width / toothWidth), 1)
        let w = rect.width / CGFloat(teeth)
        for i in 0..<teeth {
            let x = rect.maxX - CGFloat(i) * w
            p.addLine(to: CGPoint(x: x - w / 2, y: rect.maxY))
            p.addLine(to: CGPoint(x: x - w, y: rect.maxY - toothHeight))
        }
        p.closeSubpath()
        return p
    }
}
