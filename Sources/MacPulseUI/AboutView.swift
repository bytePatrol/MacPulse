import SwiftUI
import MacPulseCore

public struct AboutView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            // App Symbol
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                    .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)

                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 8)

            // App Name & Version
            VStack(spacing: 4) {
                Text(MacPulseInfo.appName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                Text("Version \(MacPulseInfo.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // One-line description
            Text("Real-time native system monitor for Apple Silicon macOS.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)

            Spacer(minLength: 4)

            Text("© 2026 MacPulse Team")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 320, height: 260)
        .background(.regularMaterial)
    }
}

#if DEBUG
#Preview {
    AboutView()
}
#endif
