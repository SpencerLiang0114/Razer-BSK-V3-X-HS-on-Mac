import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` so the UI can bind a Toggle to it. The state
/// is read straight from `SMAppService` on every access — no local shadow —
/// so it stays in sync with System Settings › Login Items even when the user
/// toggles it externally.
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    // Bumped whenever we successfully mutate registration so SwiftUI redraws.
    @Published private var version: Int = 0

    var isEnabled: Bool {
        _ = version   // touch so views subscribe to changes
        return SMAppService.mainApp.status == .enabled
    }

    /// Result of the most recent register/unregister attempt. `nil` = last
    /// call succeeded (or none yet).
    @Published var lastError: String? = nil

    func setEnabled(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
            version &+= 1
        } catch {
            lastError = error.localizedDescription
            version &+= 1
        }
    }
}
