import SwiftUI

// MARK: - DualRangeSlider
// Media-style start/end range control (0…1). Minimum span prevents zero-length clips.

struct DualRangeSlider: View {
    @Binding var start: Double
    @Binding var end: Double

    var minimumSpan: Double = 0.05
    var trackHeight: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let startX = CGFloat(start) * w
            let endX   = CGFloat(end) * w

            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(height: trackHeight)

                // Selected range
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(VideoWallTheme.brandGradientHorizontal)
                    .opacity(0.55)
                    .frame(width: max(0, endX - startX), height: trackHeight - 12)
                    .offset(x: startX, y: 0)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(VideoWallTheme.gradB.opacity(0.5), lineWidth: 1)
                            .frame(width: max(0, endX - startX), height: trackHeight - 12)
                            .offset(x: startX)
                    )

                // Start handle
                handle
                    .position(x: startX, y: trackHeight / 2)
                    .gesture(drag(isStart: true, width: w))

                // End handle
                handle
                    .position(x: endX, y: trackHeight / 2)
                    .gesture(drag(isStart: false, width: w))
            }
        }
        .frame(height: trackHeight)
    }

    private var handle: some View {
        Capsule()
            .fill(Color.white)
            .frame(width: 8, height: trackHeight - 6)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }

    private func drag(isStart: Bool, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                let t = Double(value.location.x / width).clamped(to: 0...1)
                if isStart {
                    start = min(t, end - minimumSpan)
                } else {
                    end = max(t, start + minimumSpan)
                }
            }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
