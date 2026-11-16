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

            GroupBox("Display") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Main ring", selection: Binding(
                        get: { manager.primaryIndicator },
                        set: { manager.setPrimaryIndicator($0) }
                    )) {
                        Text("Auto").tag(PrimaryIndicator.auto)
                        Text("5-hour").tag(PrimaryIndicator.session)
                        Text("Weekly").tag(PrimaryIndicator.weekly)
                    }
                    .pickerStyle(.segmented)
                    Text("Auto shows the 5-hour window when the provider reports one, otherwise weekly")
                        .font(.system(.caption2))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 8)

                    Toggle("Show Estimated API Cost", isOn: Binding(
                        get: { manager.showEstimatedCost },
                        set: { manager.setShowEstimatedCost($0) }
                    ))
                    Text("Based on published API prices, scanned from local transcripts")
                        .font(.system(.caption2))
                        .foregroundStyle(.tertiary)
                }
                .padding(4)
            }

            GroupBox("Pacing") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Simulate 5-hour windows", isOn: Binding(
                        get: { manager.simulateSessions },
                        set: { manager.setSimulateSessions($0) }
                    ))
                    Text("When a provider has no 5-hour limit, open a 5-hour window on first use and pace it against your weekly budget")
                        .font(.system(.caption2))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Text("Windows per day")
                            .fixedSize()
                        Spacer()
                        Picker("", selection: Binding(
                            get: { manager.simulatedWindowsPerDay },
                            set: { manager.setSimulatedWindowsPerDay($0) }
                        )) {
                            ForEach([1.0, 2.0, 3.0, 4.0], id: \.self) { n in
                                Text("\(Int(n))").tag(n)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 112)
                    }
                    .padding(.top, 6)
                    .disabled(!manager.simulateSessions)
                    Text("Each window's budget: weekly headroom left ÷ windows left before the weekly reset")
                        .font(.system(.caption2))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            }

            HStack {
                Text("AI Bar \(AppInfo.version)")
                    .font(.system(.caption))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
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
