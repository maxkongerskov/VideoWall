import SwiftUI
import AppKit

// MARK: - AboutView
// "About" section in Settings.

struct AboutView: View {

    private let gradStart = Color(red: 0.35, green: 0.30, blue: 1.00)
    private let gradEnd   = Color(red: 0.75, green: 0.30, blue: 1.00)

    @State private var heartScale: CGFloat  = 1.0
    @State private var heartOpacity: Double = 1.0

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 36)

                // ── Avatar ring ──────────────────────────────────────────────
                ZStack {
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [gradStart, gradEnd, gradStart],
                                center: .center
                            ),
                            lineWidth: 2
                        )
                        .frame(width: 86, height: 86)
                        .blur(radius: 1)

                    Circle()
                        .fill(
                            LinearGradient(colors: [gradStart.opacity(0.25), gradEnd.opacity(0.25)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 76, height: 76)

                    Text("MK")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(colors: [gradStart, gradEnd],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                }

                Spacer().frame(height: 18)

                // ── Name ─────────────────────────────────────────────────────
                Text("Max Køngerskov")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)

                Spacer().frame(height: 4)

                Text("Developer")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.35))

                Spacer().frame(height: 28)

                // ── Bio card ─────────────────────────────────────────────────
                VStack(spacing: 12) {
                    Text("""
                    Hey! 👋

                    VideoWall is a small evening project, born out of the frustration that macOS doesn't ship with a native live wallpaper feature.

                    Built with Swift, SwiftUI, AVFoundation, and a lot of enthusiasm.
                    """)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.65))
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().opacity(0.2)

                    // Built with love
                    HStack(spacing: 6) {
                        Text("Made with")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.35))

                        Image(systemName: "heart.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.pink)
                            .scaleEffect(heartScale)
                            .opacity(heartOpacity)
                            .onAppear { startHeartbeat() }

                        Text("in Denmark")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.35))

                        Spacer()

                        Text(appVersion)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(.white.opacity(0.20))
                    }
                }
                .padding(16)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
                .padding(.horizontal, 24)

                Spacer().frame(height: 24)

                Text("© 2026 Max Køngerskov")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.18))

                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Helpers

    private func startHeartbeat() {
        withAnimation(
            .easeInOut(duration: 0.5)
            .repeatForever(autoreverses: true)
            .delay(1.5)
        ) {
            heartScale = 1.25
            heartOpacity = 0.6
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(v) (\(b))"
    }
}

// MARK: - Preview

#Preview {
    AboutView()
        .frame(width: 370, height: 460)
        .background(Color(red: 0.055, green: 0.055, blue: 0.12))
        .preferredColorScheme(.dark)
}
