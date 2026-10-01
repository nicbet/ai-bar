import SwiftUI
import AppKit

/// Renders the popover and spending window with sample data to PNGs, for the README
/// (`AIBar --snapshot <dir>`). Views are hosted in an offscreen window rather than drawn with
/// ImageRenderer, which leaves placeholders for AppKit-backed controls like segmented pickers.
@MainActor
enum Snapshot {
    static func write(to directory: URL, scale: CGFloat = 2) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = sampleManager()
        var urls: [URL] = []
        for (suffix, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let popover = PopoverScene(manager: manager)
            urls.append(try render(popover, scheme: scheme, scale: scale,
                                   to: directory.appendingPathComponent("popover-\(suffix).png")))
            let spending = SpendingScene(manager: manager, history: sampleHistory())
            urls.append(try render(spending, scheme: scheme, scale: scale,
                                   to: directory.appendingPathComponent("spending-\(suffix).png")))
        }
        return urls
    }

    private static func render<V: View>(_ view: V, scheme: ColorScheme, scale: CGFloat, to url: URL) throws -> URL {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let charts and controls finish their first layout pass
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw SnapshotError.renderFailed(url.lastPathComponent) }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:])
        else { throw SnapshotError.renderFailed(url.lastPathComponent) }
        try data.write(to: url)
        return url
    }

    enum SnapshotError: Error { case renderFailed(String) }

    // MARK: - Sample data

    static func sampleManager() -> UsageManager {
        let now = Date()
        let claude = ServiceUsage(utilization: 0.31, resetsAt: now.addingTimeInterval(2 * 3600 + 46 * 60),
                                  windowDuration: 5 * 3600, weeklyUtilization: 0.22,
                                  weeklyResetsAt: now.addingTimeInterval(4 * 86400 + 6 * 3600), lastUpdated: now)
        let codex = ServiceUsage(utilization: 0.63, resetsAt: now.addingTimeInterval(1 * 3600 + 12 * 60),
                                 windowDuration: 5 * 3600, weeklyUtilization: 0.41,
                                 weeklyResetsAt: now.addingTimeInterval(2 * 86400 + 20 * 3600), lastUpdated: now)
        return UsageManager(preview: claude, codex: codex, dailyCost: daySummary(claude: 58.40, haiku: 0.42, codex: 12.15))
    }

    /// 30 days of plausible spend: busier mid-week, quieter weekends, Codex in bursts.
    static func sampleHistory() -> [String: DailyCostSummary] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let claude: [Double] = [42, 88, 120, 64, 12, 0, 96, 140, 210, 132, 78, 8, 4,
                                150, 186, 98, 240, 120, 22, 0, 110, 172, 134, 196, 88, 14, 6, 124, 160]
        let codex: [Double] = [0, 12, 0, 18, 0, 0, 6, 22, 30, 0, 14, 0, 0,
                               8, 26, 44, 12, 0, 0, 0, 16, 0, 38, 20, 6, 0, 0, 18, 24]
        var history: [String: DailyCostSummary] = [:]
        for (i, cost) in claude.enumerated() {
            guard let day = cal.date(byAdding: .day, value: -(claude.count - i), to: today) else { continue }
            history[CostEstimator.dayKey(day)] = daySummary(claude: cost, haiku: cost > 0 ? cost * 0.004 : 0, codex: codex[i])
        }
        return history
    }

    private static func daySummary(claude: Double, haiku: Double, codex: Double) -> DailyCostSummary {
        var s = DailyCostSummary()
        if claude > 0 {
            s.claudeModels.append(entry("claude-opus-5-5", cost: claude, input: 4, output: 20, write: 5, read: 0.2))
        }
        if haiku > 0 {
            s.claudeModels.append(entry("claude-haiku-4-5", cost: haiku, input: 1, output: 5, write: 1.25, read: 0.1))
        }
        if codex > 0 {
            s.codexModels.append(entry("gpt-5.6-sol", cost: codex, input: 4, output: 20, write: 0, read: 0.4))
        }
        return s
    }

    /// Token counts that add up to `cost` at the given per-million prices.
    private static func entry(_ model: String, cost: Double, input: Double, output: Double,
                              write: Double, read: Double) -> ModelCostEntry {
        let shares = write > 0 ? (input: 0.03, output: 0.35, write: 0.17, read: 0.45)
                               : (input: 0.20, output: 0.35, write: 0.0, read: 0.45)
        func tokens(_ share: Double, _ price: Double) -> Int { price > 0 ? Int(cost * share / price * 1_000_000) : 0 }
        return ModelCostEntry(model: model,
                              inputTokens: tokens(shares.input, input), outputTokens: tokens(shares.output, output),
                              cacheWriteTokens: tokens(shares.write, write), cacheReadTokens: tokens(shares.read, read),
                              cost: cost)
    }
}

// MARK: - Scenes

/// A wallpaper-like gradient behind every screenshot.
private struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.20, green: 0.12, blue: 0.40), Color(red: 0.10, green: 0.14, blue: 0.36)]
                : [Color(red: 0.72, green: 0.56, blue: 0.96), Color(red: 0.45, green: 0.52, blue: 0.95)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A slice of the menu bar with AI Bar's item open and the popover hanging below it.
private struct PopoverScene: View {
    let manager: UsageManager
    @Environment(\.colorScheme) private var scheme

    private var label: NSImage {
        MenuBarRenderer.render(
            providers: [ProviderLabel(iconPath: BrandIcons.claudePath, percent: manager.claude.percentInt),
                        ProviderLabel(iconPath: BrandIcons.codexPath, percent: manager.codex.percentInt)],
            costLabel: String(format: "%.2f", manager.dailyCost.totalCost))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            menuBar
            PopoverView()
                .environmentObject(manager)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(scheme == .dark ? 0.15 : 0.5), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
                .padding(.trailing, 128)
        }
        .padding(.bottom, 56)
        .frame(width: 600)
        .background(Backdrop())
    }

    private var menuBar: some View {
        HStack(spacing: 16) {
            Spacer()
            Image(nsImage: label)
                .renderingMode(.template)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.25)))
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("Thu Oct 1  9:41")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(scheme == .dark ? .white : .black)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(scheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.35))
    }
}

/// The spending window in plain window chrome.
private struct SpendingScene: View {
    let manager: UsageManager
    let history: [String: DailyCostSummary]

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            SpendingView(previewHistory: history, range: .month)
                .environmentObject(manager)
                .scrollIndicators(.hidden)
                .frame(width: 560, height: 920)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        .padding(56)
        .background(Backdrop())
    }

    private var titleBar: some View {
        ZStack {
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
                Spacer()
            }
            .frame(height: 12)
            Text("API Spending")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }
}
