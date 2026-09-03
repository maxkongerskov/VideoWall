import SwiftUI

// MARK: - PlaybackRateStops
// Click-only 1×…10× rail. No drag. Pause is the Pause button.

struct PlaybackRateStops: View {
    @Binding var rate: Double

    nonisolated static let stops: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

    nonisolated static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return stops.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1
    }

    private let trackHeight: CGFloat = 28
    private let inset: CGFloat = 10

    private var current: Double { Self.clamped(rate) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let selected = current
            let selectedX = x(for: selected, width: w)

            VStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(height: trackHeight)

                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(VideoWallTheme.brandGradientHorizontal)
                        .opacity(0.55)
                        .frame(width: max(0, selectedX), height: trackHeight - 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(VideoWallTheme.gradB.opacity(0.5), lineWidth: 1)
                        )

                    ForEach(Self.stops, id: \.self) { stop in
                        let on = abs(stop - selected) < 0.01
                        Capsule()
                            .fill(Color.white.opacity(on ? 0.55 : 0.18))
                            .frame(width: 2, height: 10)
                            .position(x: x(for: stop, width: w), y: trackHeight / 2)
                    }

                    Capsule()
                        .fill(Color.white)
                        .frame(width: 8, height: trackHeight - 6)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .overlay(
                            Capsule()
                                .stroke(VideoWallTheme.gradB.opacity(0.55), lineWidth: 1)
                        )
                        .position(x: selectedX, y: trackHeight / 2)
                }
                .frame(height: trackHeight)

                ZStack {
                    ForEach(Self.stops, id: \.self) { stop in
                        let on = abs(stop - selected) < 0.01
                        Text("\(Int(stop))")
                            .font(.system(size: 10, weight: on ? .semibold : .medium).monospacedDigit())
                            .foregroundColor(on ? VideoWallTheme.textPrimary : VideoWallTheme.textTertiary)
                            .position(x: x(for: stop, width: w), y: 7)
                    }
                }
                .frame(height: 14)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        // Click location only — ignore drag motion / onChanged.
                        rate = stop(at: value.startLocation.x, width: w)
                    }
            )
        }
        .frame(height: trackHeight + 20)
    }

    private func x(for stop: Double, width: CGFloat) -> CGFloat {
        let usable = max(0, width - inset * 2)
        return inset + CGFloat((stop - 1) / 9) * usable
    }

    private func stop(at locationX: CGFloat, width: CGFloat) -> Double {
        let usable = max(0.0001, width - inset * 2)
        let t = min(max(Double((locationX - inset) / usable), 0), 1)
        return Self.clamped(t * 9 + 1)
    }
}

enum PlaybackRateSlider {
    static func clamped(_ value: Double) -> Double { PlaybackRateStops.clamped(value) }
}
