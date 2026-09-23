import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var manager: UsageManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal)
            cards.padding(.vertical, 16)
            if manager.showEstimatedCost {
                Divider().padding(.horizontal)
                costRow
            }
            Divider().padding(.horizontal)
            footer
        }
        .frame(width: 320)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .foregroundStyle(.secondary)
            Text("AI Usage")
                .font(.system(.headline, design: .rounded))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var cards: some View {
        HStack(alignment: .top, spacing: 12) {
            claudeCard
            codexCard
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var claudeCard: some View {
        if manager.claudeAvailable && manager.claudeEnabled {
            ServiceCardView(
                name: "Claude",
                iconPath: BrandIcons.claudePath,
                usage: manager.claude,
                colors: (Color.claudeOrange, Color.claudeBrown)
            )
        } else if !manager.claudeAvailable {
            SetupCardView(
                name: "Claude",
                iconPath: BrandIcons.claudePath,
                instruction: "Run claude login\nto connect",
                color: .claudeOrange
            )
        }
    }

    @ViewBuilder
    private var codexCard: some View {
        if manager.codexAvailable && manager.codexEnabled {
            ServiceCardView(
                name: "Codex",
                iconPath: BrandIcons.codexPath,
                usage: manager.codex,
                colors: (Color.codexBlue, Color.codexBlueDark)
            )
        } else if !manager.codexAvailable {
            SetupCardView(
                name: "Codex",
                iconPath: BrandIcons.codexPath,
                instruction: "Run codex login\nto connect",
                color: .codexBlue
            )
        }
    }

    private var costRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("Est. API cost today")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer()

            let cost = manager.dailyCost
            if cost.totalCost > 0 {
                HStack(spacing: 8) {
                    if cost.claudeCost > 0 && cost.codexCost > 0 {
                        Text("\(formatCost(cost.claudeCost)) + \(formatCost(cost.codexCost))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Text("≈ \(formatCost(cost.totalCost))")
                        .font(.system(.body, design: .rounded))
                        .fontWeight(.semibold)
                }
            } else {
                Text("—")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @Environment(\.openWindow) private var openWindow

    private var footer: some View {
        HStack {
            FooterButton(label: "Refresh", icon: "arrow.clockwise") {
                manager.pollNow(force: true)
            }
            Spacer()
            FooterButton(label: "Settings", icon: "gear") {
                NSApp.activate()
                openWindow(id: "settings")
            }
            Spacer()
            FooterButton(label: "Quit", icon: "xmark.circle") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct FooterButton: View {
    let label: String
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(.body))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
