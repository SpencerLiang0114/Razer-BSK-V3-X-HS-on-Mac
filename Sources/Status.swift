import Foundation
import Combine

/// How the mouse is reachable right now. Vendor-command features
/// (DPI/lighting/poll rate/battery/idle) go through the 2.4 GHz dongle only
/// — over Bluetooth the mouse enumerates under a different VID/PID and the
/// Razer transaction protocol is not exposed. Software-side features
/// (button remap, scroll transform) work identically on both transports.
enum ConnectionKind: String, Codable {
    case none, dongle, bluetooth
}

/// Pure observable state for the connected mouse. UI-agnostic — presentation
/// formatters live in the views/controllers that consume this.
@MainActor
final class Status: ObservableObject {
    // Only DeviceController is intended to write these. Kept `var` because
    // Swift's `private(set)` / `fileprivate(set)` would block cross-file
    // access from DeviceController, and a single-module app doesn't have a
    // narrower visibility scope that would help. The invariant is by
    // convention — if you're editing a view and reaching for `status.foo =
    // …`, you almost certainly want to route the change through
    // DeviceController instead.
    @Published var present: Bool = false      // any transport enumerated
    @Published var connection: ConnectionKind = .none
    @Published var awake: Bool = false        // mouse is responding right now
    @Published var battery: Int? = nil        // 0-100, last-known
    @Published var firmware: String? = nil
    @Published var serial: String? = nil
    /// The mouse's actual reported idle-sleep time (minutes) — read back from
    /// hardware after a write, used to detect when the firmware silently
    /// ignores our value.
    @Published var idleActual: Int? = nil
    @Published var error: String? = nil       // last non-transient failure
    @Published var settings: AppSettings = SettingsStore.shared.current
}
