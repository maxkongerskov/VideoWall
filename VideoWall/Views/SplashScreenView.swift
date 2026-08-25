import SwiftUI

// MARK: - SplashScreenView
// Shown on first launch / major update. Animates in, then calls onDismiss after ~3s.

struct SplashScreenView: View {
    let onDismiss: () -> Void

    // Animation state
    @State private var bgOpacity:      Double  = 0
    @State private var logoScale:      CGFloat = 0.6
    @State private var logoOpacity:    Double  = 0
    @State private var titleOpacity:   Double  = 0
    @State private var taglineOpacity: Double  = 0
    @State private var barProgress:    CGFloat = 0
    @State private var ringRotation:   Double  = 0
    @State private var isLeaving:      Bool    = false

    // Palette
    private let gradStart = Color(red: 0.35, green: 0.30, blue: 1.00)
    private let gradEnd   = Color(red: 0.75, green: 0.30, blue: 1.00)
    private let bg        = Color(red: 0.055, green: 0.055, blue: 0.12)

    var body: some View {
        ZStack {
            // ── Background ──────────────────────────────────────────────────
            bg.ignoresSafeArea()

            // Radial glow behind logo
            RadialGradient(
                gradient: Gradient(colors: [
                    gradStart.opacity(0.22),
                    Color.clear
                ]),
                center: .center,
                startRadius: 0,
                endRadius: 220
            )

            // Drifting particles
            ParticleView()

            // ── Main content ─────────────────────────────────────────────────
            VStack(spacing: 0) {

                // Logo ring + icon
                ZStack {
                    // Outer spinning dashed ring
                    Circle()
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    gradStart.opacity(0.7),
                                    gradEnd.opacity(0.0),
                                    gradStart.opacity(0.7)
                                ]),
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 6])
                        )
                        .frame(width: 120, height: 120)
                        .rotationEffect(.degrees(ringRotation))

                    // Inner frosted circle
                    Circle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 96, height: 96)

                    Circle()
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        .frame(width: 96, height: 96)

                    // App icon glyph
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [gradStart, gradEnd],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .scaleEffect(logoScale)
                .opacity(logoOpacity)

                Spacer().frame(height: 32)

                // App name
                Text("VideoWall")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .opacity(titleOpacity)

                Spacer().frame(height: 6)

                // Tagline
                Text("Your desktop, alive.")
                    .font(.system(size: 14, weight: .regular))
                    .tracking(2.5)
                    .foregroundColor(.white.opacity(0.38))
                    .opacity(taglineOpacity)

                Spacer().frame(height: 44)

                // Progress bar
                VStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 180, height: 3)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [gradStart, gradEnd],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 180 * barProgress, height: 3)
                    }
                    .frame(width: 180)

                    Text("Loading…")
                        .font(.system(size: 11, weight: .regular))
                        .tracking(1.2)
                        .foregroundColor(.white.opacity(0.20))
                }
                .opacity(taglineOpacity)
            }
            .padding(.vertical, 48)
        }
        .frame(width: 620, height: 420)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .opacity(isLeaving ? 0 : bgOpacity)
        .scaleEffect(isLeaving ? 1.04 : 1.0)
        .onAppear(perform: runSequence)
    }

    // MARK: - Animation sequence

    private func runSequence() {
        // 1. Fade in background
        withAnimation(.easeOut(duration: 0.45)) {
            bgOpacity = 1
        }

        // 2. Logo pops in
        withAnimation(.spring(response: 0.55, dampingFraction: 0.68).delay(0.15)) {
            logoScale   = 1
            logoOpacity = 1
        }

        // 3. Ring starts spinning (continuous)
        withAnimation(.linear(duration: 12).repeatForever(autoreverses: false).delay(0.15)) {
            ringRotation = 360
        }

        // 4. Title + tagline fade in
        withAnimation(.easeOut(duration: 0.5).delay(0.45)) {
            titleOpacity   = 1
            taglineOpacity = 1
        }

        // 5. Progress bar sweeps across
        withAnimation(.easeInOut(duration: 1.9).delay(0.55)) {
            barProgress = 1
        }

        // 6. Dismiss after bar completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.9) {
            withAnimation(.easeIn(duration: 0.38)) {
                isLeaving = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                onDismiss()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SplashScreenView {}
        .frame(width: 620, height: 420)
}

