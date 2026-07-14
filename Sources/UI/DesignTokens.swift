import SwiftUI
import AppKit

// Shared design tokens so every pane picks up the same rhythm. If we want
// to retune spacing / radius / typography, change it here — not in each pane.

enum DS {
    // Spacing scale.
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20

    // Corner radii.
    static let rMedium: CGFloat = 8
    static let rLarge: CGFloat  = 12

    // Font sizes.
    static let fCaption: CGFloat    = 11
    static let fBody: CGFloat       = 12
    static let fMediumBody: CGFloat = 13
    static let fSubtitle: CGFloat   = 15

    // Palette (all through NSColor semantic names so light/dark modes track).
    static let cardFill: Color           = Color(nsColor: .textBackgroundColor)
    static let mutedFill: Color          = Color(nsColor: .quaternarySystemFill)
    static let border: Color             = Color(nsColor: .separatorColor).opacity(0.4)
    static let accentFillSubtle: Color   = Color.accentColor.opacity(0.10)
    static let accentBorderSubtle: Color = Color.accentColor.opacity(0.4)
}

// ─── Liquid Glass adapters ───────────────────────────────────────────
//
// macOS 26 Tahoe introduced `.glassEffect()`. Wrapping it in `@available`
// so this build still runs on macOS 14+ if we ever ship the binary
// elsewhere; on 26+ the floating chrome (banner, footer, pills) picks up
// the refractive glass look automatically.

extension View {
    /// Rounded-rect background. `tint` is applied as a subtle color wash
    /// through the glass; nil = neutral.
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            // Pre-26 fallback: the same regularMaterial the app used
            // before, so the visual rhythm doesn't shift on older macOS.
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(DS.border, lineWidth: 0.5))
        }
    }

}
