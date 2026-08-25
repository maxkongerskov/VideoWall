import SwiftUI

// MARK: - VideoWallTheme
// Single brand system for the menu-bar popover and related chrome.

enum VideoWallTheme {
    /// Brand gradient start (indigo).
    static let gradA = Color(red: 0.357, green: 0.302, blue: 1.0)   // #5B4DFF
    /// Brand gradient end (magenta).
    static let gradB = Color(red: 0.690, green: 0.302, blue: 1.0)   // #B04DFF

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [gradA, gradB],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var brandGradientHorizontal: LinearGradient {
        LinearGradient(colors: [gradA, gradB], startPoint: .leading, endPoint: .trailing)
    }

    static let textPrimary   = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary  = Color.white.opacity(0.32)
    static let surface       = Color.white.opacity(0.06)
    static let surfaceRaised = Color.white.opacity(0.10)
    static let hairline      = Color.white.opacity(0.07)

    static let popoverWidth:  CGFloat = 380
    /// Tall enough for Controls with now-playing + Cycle blur visible (no internal scroll).
    /// Library uses the same fixed height.
    static let popoverHeight: CGFloat = 580
}
