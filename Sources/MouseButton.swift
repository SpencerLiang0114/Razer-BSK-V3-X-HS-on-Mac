import Foundation

/// Physical buttons on the Basilisk V3 X HyperSpeed. Core domain type —
/// referenced by ButtonMap (remapping), Settings (persistence), the
/// DeviceController (DPI cycle), the tray menu, and the diagram view.
enum MouseButton: String, CaseIterable, Identifiable {
    case leftClick, rightClick
    case scrollClick, scrollUp, scrollDown
    case mouseButton4, mouseButton5
    case dpiCycle

    var id: String { rawValue }

    /// Labels match Razer Synapse exactly so muscle memory transfers between
    /// the two apps.
    var label: String {
        switch self {
        case .leftClick:    return "Left Click"
        case .rightClick:   return "Right Click"
        case .scrollClick:  return "Scroll Click"
        case .scrollUp:     return "Scroll Up"
        case .scrollDown:   return "Scroll Down"
        case .mouseButton4: return "Mouse Button 4"
        case .mouseButton5: return "Mouse Button 5"
        case .dpiCycle:     return "Cycle Up Sensitivity Stages"
        }
    }

    /// Left Click stays locked to its OS default to avoid bricking basic
    /// clicking. Sensitivity-cycle is firmware-driven and never emits a HID
    /// event we can intercept.
    var remappable: Bool {
        switch self {
        case .leftClick, .dpiCycle: return false
        default: return true
        }
    }
}
