import Foundation
import AppKit

/// Watches which app has the frontmost focus and fires `onFocusChange`
/// with the newly-active bundle ID (or `nil` when we can't tell — e.g.
/// launchd services, some Electron helpers without a proper Info.plist).
///
/// This is the signal that drives per-profile auto-switch: DeviceController
/// looks up the bundle ID in each profile's `triggerBundleIDs` and, if it
/// finds a match, calls `SettingsStore.setActive(...)`. When nothing
/// matches, DeviceController falls back to `SettingsFile.defaultID` (if
/// the user has set one).
///
/// **Suppression**: our own bundle ID is filtered out at the source so
/// opening the panel or right-clicking the tray icon doesn't count as a
/// focus change. Otherwise every panel open would revert to the default
/// profile — meaning users could never see the auto-switch actually work.
///
/// The observer lives on `.main` because it publishes into `Status` /
/// `SettingsStore` (both @MainActor). `didActivateApplicationNotification`
/// fires on the main queue by default, but binding it explicitly keeps
/// the intent obvious.
final class AppSwitchWatcher {
    /// Delivered on the main queue. `bundleID` is nil when the newly-focused
    /// process has no discoverable bundle identifier.
    var onFocusChange: ((_ bundleID: String?) -> Void)?

    private let excludeBundleID: String?
    private var observer: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    /// - Parameter excludeBundleID: bundle ID to filter out (our own —
    ///   otherwise opening the panel triggers a spurious focus change).
    init(excludeBundleID: String?) {
        self.excludeBundleID = excludeBundleID
    }

    deinit { stop() }

    func start() {
        stop()   // idempotent
        let nc = NSWorkspace.shared.notificationCenter
        observer = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bid = app?.bundleIdentifier
            // Ignore self-activation so opening the panel / clicking the
            // tray doesn't revert an app-triggered profile switch.
            if let bid, bid == self.excludeBundleID { return }
            self.onFocusChange?(bid)
        }

        // Also listen for launch/terminate so the watcher can seed the
        // initial state and (crucially) fire when the user closes an app
        // whose profile is currently active. Terminating an app doesn't
        // guarantee a didActivateApplication follow-up on every macOS
        // build — some times focus falls to a hidden Finder window that
        // doesn't post its activation. Querying the frontmost after a
        // terminate is the belt-and-suspenders play.
        terminateObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if let bid, bid == self.excludeBundleID { return }
            self.onFocusChange?(bid)
        }

        // Seed with the current frontmost so a profile bound to the app
        // that was already frontmost at launch takes effect immediately.
        // Dispatched to the next runloop tick so DeviceController.start()
        // finishes wiring before the first callback fires — otherwise the
        // seed can race with the on-launch profile push.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if let bid, bid == self.excludeBundleID { return }
            self.onFocusChange?(bid)
        }
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        if let observer { nc.removeObserver(observer); self.observer = nil }
        if let terminateObserver { nc.removeObserver(terminateObserver); self.terminateObserver = nil }
    }
}
