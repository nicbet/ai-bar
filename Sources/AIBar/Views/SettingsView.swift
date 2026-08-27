import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var manager: UsageManager

    private let intervals: [(String, TimeInterval)] = [
        ("1m", 60), ("2m", 120), ("5m", 300), ("10m", 600), ("15m", 900)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.system(.title3, design: .rounded))
                .fontWeight(.bold)

            GroupBox("Providers") {
                VStack(spacing: 12) {
                    providerRow(
                        name: "Claude", iconPath: BrandIcons.claudePath,
                        color: .claudeOrange,
                        available: manager.claudeAvailable,
                        enabled: Binding(
                            get: { manager.claudeEnabled },
                            set: { manager.setProviderEnabled("claude", enabled: $0) }
                        )
                    )
                    Divider()
                    providerRow(
                        name: "Codex", iconPath: BrandIcons.codexPath,
                        color: .codexBlue,
                        available: manager.codexAvailable,
                        enabled: Binding(
                            get: { manager.codexEnabled },
                            set: { manager.setProviderEnabled("codex", enabled: $0) }
                        )
                    )
                }
                .padding(4)
            }

            GroupBox("Refresh Interval") {
                Picker("", selection: Binding(
                    get: { manager.pollInterval },
                    set: { manager.updatePollInterval($0) }
                )) {
                    ForEach(intervals, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Check Credentials") {
                    manager.checkCredentials()
                }
                .controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func providerRow(name: String, iconPath: String, color: Color,
                             available: Bool, enabled: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            SVGPathShape(pathData: iconPath, viewBox: BrandIcons.viewBox)
                .fill(.primary)
                .frame(width: 16, height: 16)

            Text(name)
                .font(.system(.body, design: .rounded))
                .fontWeight(.medium)

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(available ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(available ? "Connected" : "Not Found")
                    .font(.system(.caption2))
                    .foregroundStyle(.secondary)
            }

            Toggle("", isOn: enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!available)
        }
    }
}
