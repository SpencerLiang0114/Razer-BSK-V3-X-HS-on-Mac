import SwiftUI
import AppKit

/// A SwiftUI-friendly wrapper around NSVisualEffectView for the frosted-glass
/// window background. macOS's own Settings, Notification Center, and menu bar
/// use these exact materials.
struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    init(_ material: NSVisualEffectView.Material = .sidebar,
         blending: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blending = blending
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}
