import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var manager: UsageManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal)
            cards.padding(.vertical, 16)
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
            ServiceCardView(
                name: "Claude",
                iconPath: BrandIcons.claudePath,
                usage: manager.claude,
                colors: (Color.claudeOrange, Color.claudeBrown)
            )
            ServiceCardView(
                name: "Codex",
                iconPath: BrandIcons.codexPath,
                usage: manager.codex,
                colors: (Color.codexBlue, Color.codexBlueDark)
            )
        }
        .padding(.horizontal, 16)
    }

    private var footer: some View {
        HStack {
            Button {
                manager.pollNow(force: true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(.caption))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "xmark.circle")
                    .font(.system(.caption))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

#Preview {
    PopoverView()
        .environmentObject(UsageManager())
}
