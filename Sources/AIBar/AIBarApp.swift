import SwiftUI
import AppKit

@main
struct AIBarApp: App {
    @StateObject private var manager = UsageManager()

    init() {
        // Dev tool: `AIBar --snapshot <dir>` renders README screenshots with sample data and exits
        guard let flag = CommandLine.arguments.firstIndex(of: "--snapshot") else { return }
        let dir = CommandLine.arguments.dropFirst(flag + 1).first ?? "."
        do {
            for url in try Snapshot.write(to: URL(fileURLWithPath: dir)) { print(url.path) }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(manager)
        } label: {
            let costText = manager.showEstimatedCost && manager.dailyCost.totalCost > 0
                ? String(format: "%.2f", manager.dailyCost.totalCost) : nil
            let img = MenuBarRenderer.render(providers: activeProviders, costLabel: costText)
            Image(nsImage: img)
        }
        .menuBarExtraStyle(.window)

        WindowGroup(id: "service-detail", for: String.self) { $serviceName in
            if let serviceName {
                DetailView(serviceName: serviceName)
                    .environmentObject(manager)
            }
        }
        .defaultSize(width: 520, height: 640)
        .windowResizability(.contentMinSize)

        Window("API Spending", id: "spending") {
            SpendingView()
                .environmentObject(manager)
        }
        .defaultSize(width: 520, height: 820)
        .windowResizability(.contentMinSize)

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(manager)
        }
        .defaultSize(width: 340, height: 300)
        .windowResizability(.contentSize)
    }

    private var activeProviders: [ProviderLabel] {
        var providers: [ProviderLabel] = []
        if manager.claudeEnabled && manager.claudeAvailable {
            providers.append(ProviderLabel(
                iconPath: BrandIcons.claudePath,
                percent: manager.claude.percentInt
            ))
        }
        if manager.codexEnabled && manager.codexAvailable {
            providers.append(ProviderLabel(
                iconPath: BrandIcons.codexPath,
                percent: manager.codex.percentInt
            ))
        }
        return providers
    }
}

struct ProviderLabel {
    let iconPath: String
    let percent: Int
}

enum MenuBarRenderer {
    static func render(providers: [ProviderLabel], costLabel: String? = nil) -> NSImage {
        let height: CGFloat = 18
        // Brand glyphs span ~26 of their 30-unit viewBox; 18.5pt makes them
        // 16pt tall like other menu bar icons (the padding may overhang).
        let iconSize: CGFloat = 18.5
        let spacing: CGFloat = 3
        let gap: CGFloat = 6
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)

        if providers.isEmpty && costLabel == nil {
            let fallback = NSImage(size: NSSize(width: 18, height: height))
            fallback.lockFocus()
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            ("AI" as NSString).draw(at: NSPoint(x: 0, y: (height - font.capHeight) / 2), withAttributes: attrs)
            fallback.unlockFocus()
            fallback.isTemplate = true
            return fallback
        }

        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        var totalWidth: CGFloat = 0
        var segments: [(textSize: NSSize, text: String)] = []

        for (i, p) in providers.enumerated() {
            let text = "\(p.percent)%"
            let size = (text as NSString).size(withAttributes: attrs)
            segments.append((size, text))
            totalWidth += iconSize + spacing + size.width
            if i < providers.count - 1 { totalWidth += gap }
        }

        var costSize = NSSize.zero
        if let costLabel {
            costSize = (costLabel as NSString).size(withAttributes: attrs)
            if !providers.isEmpty { totalWidth += gap }
            totalWidth += iconSize + spacing + costSize.width
        }

        let image = NSImage(size: NSSize(width: ceil(totalWidth), height: height))
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        var x: CGFloat = 0
        let firstTextHeight = segments.first?.textSize.height ?? costSize.height
        let textY = (height - firstTextHeight) / 2

        for (i, p) in providers.enumerated() {
            let iconRect = CGRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
            BrandIcons.drawInContext(ctx, path: p.iconPath, in: iconRect)
            x += iconSize + spacing

            (segments[i].text as NSString).draw(at: NSPoint(x: x, y: textY), withAttributes: attrs)
            x += segments[i].textSize.width + gap
        }

        if let costLabel {
            let dollarRect = CGRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
            BrandIcons.drawInContext(ctx, path: BrandIcons.dollarPath, in: dollarRect)
            x += iconSize + spacing

            (costLabel as NSString).draw(at: NSPoint(x: x, y: textY), withAttributes: attrs)
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
