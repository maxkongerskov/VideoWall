import SwiftUI
import AppKit

// MARK: - VisualEffectView
/// Bridges NSVisualEffectView into SwiftUI for frosted-glass panels.

struct VisualEffectView: NSViewRepresentable {
    var material:     NSVisualEffectView.Material    = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state:        NSVisualEffectView.State        = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material     = material
        v.blendingMode = blendingMode
        v.state        = state
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material     = material
        v.blendingMode = blendingMode
        v.state        = state
    }
}

// MARK: - GlassCard
/// A reusable frosted-glass card surface with subtle border.
///
/// Usage:
///   GlassCard {
///       Text("Hello")
///       Button("Action") { }
///   }

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 12

    private let content: () -> Content

    init(cornerRadius: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.content      = content
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)

            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - ThinDivider

struct ThinDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
    }
}

