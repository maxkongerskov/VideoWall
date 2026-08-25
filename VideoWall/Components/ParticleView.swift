import SwiftUI

// MARK: - ParticleView
/// Generates a field of drifting light particles for the splash screen background.
///
/// Particles are generated once and persisted via `@State` so the random layout
/// survives parent-view refreshes, but the struct itself is never mutated at runtime.

struct ParticleView: View {

    private struct Particle: Identifiable {
        let id      = UUID()
        let x:       CGFloat   // 0…1 normalized position
        let y:       CGFloat   // 0…1 normalized position
        let size:    CGFloat
        let speed:   CGFloat   // upward drift factor
        let color:   Color     // pre-baked so we don't recreate it every frame
    }

    /// Persist the random field across view struct recreations by parent refreshes.
    @State private var particles: [Particle] = Self.makeParticles()

    // MARK: Factory

    private static func makeParticles() -> [Particle] {
        (0..<55).map { _ in
            let hue     = Double.random(in: 0.65...0.82)   // indigo → violet
            let opacity = Double.random(in: 0.08...0.55)
            return Particle(
                x:       CGFloat.random(in: 0...1),
                y:       CGFloat.random(in: 0...1),
                size:    CGFloat.random(in: 1.5...4),
                speed:   CGFloat.random(in: 0.0004...0.0014),
                color:   Color(hue: hue, saturation: 0.7, brightness: 1.0, opacity: opacity)
            )
        }
    }

    // MARK: Helpers

    /// Wraps any real number into the fractional range [0, 1).
    private func wrapFraction(_ value: CGFloat) -> CGFloat {
        let r = value.truncatingRemainder(dividingBy: 1.0)
        return r < 0 ? r + 1 : r
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    let t = CGFloat(timeline.date.timeIntervalSinceReferenceDate)

                    for p in particles {
                        // Slow upward drift + gentle sine wobble
                        let yFrac  = wrapFraction(p.y - t * p.speed)
                        let yPos   = yFrac * size.height

                        let wobble = sin(t * 0.6 + p.x * 10) * 0.02
                        let xPos   = (p.x + wobble) * size.width

                        ctx.fill(
                            Path(ellipseIn: CGRect(x: xPos - p.size / 2,
                                                   y: yPos - p.size / 2,
                                                   width:  p.size,
                                                   height: p.size)),
                            with: .color(p.color)
                        )
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .allowsHitTesting(false)
    }
}

