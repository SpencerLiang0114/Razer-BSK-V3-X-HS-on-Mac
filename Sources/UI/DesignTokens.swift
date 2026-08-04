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

    /// Full-panel Liquid Glass surface for window-sized content areas
    /// (settings panel body, RemapPicker sheet, etc.). Uses a rectangular
    /// shape so the effect covers the whole region without a rounded edge
    /// fighting the window chrome. Falls back to `.regularMaterial` so
    /// pre-26 builds still get a translucent, System-Settings-flavoured
    /// surface instead of a jarring flat fill.
    @ViewBuilder
    func liquidGlassPanel() -> some View {
        if #available(macOS 26.0, *) {
            self.background {
                Rectangle().fill(.clear).glassEffect(.regular, in: Rectangle())
            }
        } else {
            self.background(.regularMaterial)
        }
    }

    /// Sheet-flavoured Liquid Glass — same effect as `.liquidGlassPanel()`
    /// but delivered through `.presentationBackground` so it actually
    /// replaces the sheet's default opaque material instead of stacking
    /// on top of it. Wrap this on the top-level view inside a `.sheet`.
    @ViewBuilder
    func liquidGlassSheet() -> some View {
        self.presentationBackground {
            if #available(macOS 26.0, *) {
                Rectangle().fill(.clear).glassEffect(.regular, in: Rectangle())
            } else {
                Color.clear.background(.regularMaterial)
            }
        }
    }

    /// Show a pointing-hand cursor while the pointer is over the view.
    /// SwiftUI Buttons on macOS default to the arrow cursor; the user
    /// asked for hand cursor on interactive elements so add this to
    /// the specific views that behave like buttons/links.
    func hoverPointer() -> some View {
        self.onHover { inside in
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    /// Subtle hover fill for row/button-shaped views. Complements
    /// `hoverPointer()` (cursor) so users get both an obvious cursor
    /// change and a visible highlight under the pointer.
    ///
    /// Rendered as an extra `.background()` layer behind the caller's
    /// existing content — because `.background(...)` layers stack
    /// inside-out, if you apply this AFTER a selected-state background
    /// (e.g. sidebar rows / profile rows), the hover tint sits BEHIND
    /// the accent fill: selected rows still read as accent, unselected
    /// rows pick up a soft primary wash while hovered.
    ///
    /// `intensity` defaults to 0.06 (System Settings-style whisper).
    /// Bump to 0.10 on darker surfaces where 0.06 gets lost.
    func hoverHighlight(cornerRadius: CGFloat = 8,
                        intensity: Double = 0.06) -> some View {
        modifier(HoverHighlightModifier(cornerRadius: cornerRadius,
                                         intensity: intensity))
    }
}

private struct HoverHighlightModifier: ViewModifier {
    let cornerRadius: CGFloat
    let intensity: Double
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(isHovered ? intensity : 0))
                    .animation(.easeInOut(duration: 0.12), value: isHovered)
            )
            .onHover { hovering in isHovered = hovering }
    }
}
