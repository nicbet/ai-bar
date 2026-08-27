import SwiftUI
import AppKit

@main
struct AIBarApp: App {
    @StateObject private var manager = UsageManager()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(manager)
        } label: {
            let img = MenuBarRenderer.render(
                claudePercent: manager.claude.percentInt,
                codexPercent: manager.codex.percentInt
            )
            Image(nsImage: img)
        }
        .menuBarExtraStyle(.window)
    }
}

enum MenuBarRenderer {
    static func render(claudePercent: Int, codexPercent: Int) -> NSImage {
        let height: CGFloat = 18
        let iconSize: CGFloat = 14
        let spacing: CGFloat = 3
        let gap: CGFloat = 6
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

        let claudeText = "\(claudePercent)%"
        let codexText = "\(codexPercent)%"

        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let claudeTextSize = (claudeText as NSString).size(withAttributes: attrs)
        let codexTextSize = (codexText as NSString).size(withAttributes: attrs)

        let totalWidth = iconSize + spacing + claudeTextSize.width + gap + iconSize + spacing + codexTextSize.width
        let image = NSImage(size: NSSize(width: ceil(totalWidth), height: height))

        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        var x: CGFloat = 0
        let iconY = (height - iconSize) / 2
        let textY = (height - claudeTextSize.height) / 2

        BrandIcons.drawInContext(ctx, path: BrandIcons.claudePath,
                                in: CGRect(x: x, y: iconY, width: iconSize, height: iconSize))
        x += iconSize + spacing

        (claudeText as NSString).draw(at: NSPoint(x: x, y: textY), withAttributes: attrs)
        x += claudeTextSize.width + gap

        BrandIcons.drawInContext(ctx, path: BrandIcons.codexPath,
                                in: CGRect(x: x, y: iconY, width: iconSize, height: iconSize))
        x += iconSize + spacing

        (codexText as NSString).draw(at: NSPoint(x: x, y: textY), withAttributes: attrs)

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
