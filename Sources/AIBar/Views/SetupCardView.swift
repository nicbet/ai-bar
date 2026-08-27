import SwiftUI

struct SetupCardView: View {
    let name: String
    let iconPath: String
    let instruction: String
    let color: Color

    var body: some View {
        VStack(spacing: 10) {
            SVGPathShape(pathData: iconPath, viewBox: BrandIcons.viewBox)
                .fill(color.opacity(0.3))
                .frame(width: 40, height: 40)

            Text(name)
                .font(.system(.headline, design: .rounded))
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Text(instruction)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(color.opacity(0.25))
        )
    }
}
