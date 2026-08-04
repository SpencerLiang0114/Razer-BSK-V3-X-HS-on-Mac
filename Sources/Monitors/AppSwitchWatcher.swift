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
/// Compound identity for the newly-focused app. `bundleID` is the primary
/// key when it's available; `executableName` (the last path component of
/// `executableURL`) is the fallback we use to identify apps that never
/// register a bundle identifier — most commonly Java-based games opened
/// through a launcher (Minecraft via Prism/MultiMC), Electron apps run
/// straight from source, or anything invoked as `java -jar ...`.
struct FocusedAppIdentity {
    let bundleID: String?
    let executableName: String?
}

final class AppSwitchWatcher {
    /// Delivered on the main queue. Both fields can be nil (e.g. focus
    /// on a helper daemon we can't classify) — DeviceController treats
    /// that as "no trigger match, fall back to defaultID."
    var onFocusChange: ((FocusedAppIdentity) -> Void)?

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
            let identity = Self.identity(for: app)
            if let bid = identity.bundleID, bid == self.excludeBundleID { return }
            self.onFocusChange?(identity)
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
            let identity = Self.identity(for: NSWorkspace.shared.frontmostApplication)
            if let bid = identity.bundleID, bid == self.excludeBundleID { return }
            self.onFocusChange?(identity)
        }

        // Seed with the current frontmost so a profile bound to the app
        // that was already frontmost at launch takes effect immediately.
        // Dispatched to the next runloop tick so DeviceController.start()
        // finishes wiring before the first callback fires — otherwise the
        // seed can race with the on-launch profile push.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let identity = Self.identity(for: NSWorkspace.shared.frontmostApplication)
            if let bid = identity.bundleID, bid == self.excludeBundleID { return }
            self.onFocusChange?(identity)
        }
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        if let observer { nc.removeObserver(observer); self.observer = nil }
        if let terminateObserver { nc.removeObserver(terminateObserver); self.terminateObserver = nil }
    }

    /// Extract the compound identity from an NSRunningApplication. The
    /// executable name is derived from `executableURL.lastPathComponent`
    /// so Java-launched games (bundleID nil, executable=/…/java) still
    /// have something the trigger list can match on.
    private static func identity(for app: NSRunningApplication?) -> FocusedAppIdentity {
        let bid = app?.bundleIdentifier
        let exe = app?.executableURL?.lastPathComponent
        return FocusedAppIdentity(bundleID: bid, executableName: exe)
    }
}
