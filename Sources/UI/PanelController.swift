import AppKit
import SwiftUI

/// Owns the settings window. Lazily creates it on first open, positions it at
/// the top-left of the primary display, then lets the user drag it wherever.
///
/// Uses an explicit outside-click NSEvent monitor to dismiss the panel
/// instead of `hidesOnDeactivate`. Reason: `hidesOnDeactivate` causes a
/// well-known "first click after hide doesn't reopen" bug — clicking the
/// tray icon *activates* the app, and macOS's implementation makes any
/// hidesOnDeactivate window auto-show itself before our button action
/// fires; the action then reads `isVisible == true` and calls
/// `orderOut(nil)`, so the panel bounces closed on the very click that
/// was meant to open it. Second click sees isVisible=false and finally
/// opens it. Owning the outside-click behaviour manually keeps
/// isVisible deterministic across the tray/panel handshake.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let status: Status
    private let controller: DeviceController
    private var window: NSWindow?
    /// Retained handle to the outside-click NSEvent monitor. Installed on
    /// `show`, removed on `hide` — do not leak across shows or macOS
    /// starts firing multiple handlers per click.
    private var outsideClickMonitor: Any?

    init(status: Status, controller: DeviceController) {
        self.status = status
        self.controller = controller
    }

    /// Tray-icon click handler. Always brings the panel to front instead
    /// of toggling closed — the user asked for "if already open, just
    /// surface it, don't close-then-reopen." Dismissal still works: the
    /// outside-click monitor (installed by `show()`) hides the panel
    /// when the user clicks anywhere outside its frame.
    func toggle(anchor button: NSStatusBarButton?) {
        if let w = window, w.isVisible {
            // Already up — just re-front it and reactivate. Skip the
            // repositioning pass so we don't yank the panel back to
            // saved origin if the user just dragged it somewhere.
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        show(anchor: button)
    }

    func show(anchor button: NSStatusBarButton?) {
        if window == nil { window = build() }
        guard let w = window else { return }
        // Suppress windowDidMove persistence for the duration of this
        // programmatic positioning pass. clampOnScreen + setContentSize +
        // setFrameOrigin each fire didMove callbacks async; without this
        // gate they'd stomp the saved user-preferred origin with
        // whatever we just computed here.
        isProgrammaticMove = true
        // Lock content size explicitly. contentMinSize == contentMaxSize
        // means any SwiftUI-driven resize collapses to a no-op, so
        // subsequent frame math uses the intended dimensions.
        let intended = NSSize(width: PanelController.defaultWidth,
                              height: PanelController.defaultHeight)
        w.contentMinSize = intended
        w.contentMaxSize = intended
        w.setContentSize(intended)
        // If the user has previously dragged the panel, restore that
        // origin so their preferred spot becomes the new default. Falls
        // back to the top-right corner of the primary display's visible
        // frame — flush against the corner near the menu-bar tray icon.
        let target: NSPoint
        if let saved = Self.loadSavedOrigin() {
            Log.info("panel show: restoring saved origin (\(saved.x), \(saved.y))")
            target = saved
        } else if let screen = NSScreen.main {
            let f = screen.frame, vis = screen.visibleFrame
            Log.info("panel show: screen.frame=\(f), visibleFrame=\(vis), intended=\(intended)")
            // Use the window's real frame size (which includes titlebar
            // chrome) instead of the intended content size. Otherwise the
            // titlebar's extra ~28 pt of height puts frame.maxY above
            // vis.maxY, clampOnScreen kicks in with its 8 pt safety
            // margin, and the panel opens flush-minus-8 from the top.
            target = NSPoint(
                x: vis.maxX - w.frame.width,
                y: vis.maxY - w.frame.height
            )
            Log.info("panel show: no saved origin — using top-right default (\(target.x), \(target.y))")
        } else {
            target = w.frame.origin
        }
        w.setFrameOrigin(target)
        clampOnScreen()
        Log.info("panel show: final frame after setFrame=\(w.frame)")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("panel show: frame after makeKeyAndOrderFront=\(w.frame)")
        installOutsideClickMonitor()
        // Clear the programmatic-move gate after the runloop has drained
        // any queued didMove notifications from the setFrameOrigin +
        // clampOnScreen calls above.
        DispatchQueue.main.async { [weak self] in
            self?.isProgrammaticMove = false
        }
        controller.setPanelVisible(true)
        Task { await controller.refresh() }
    }

    // Compact popover size — earlier 980×640 filled too much of a laptop
    // screen and let the MouseDiagram card grow into a huge void. These
    // dimensions match Synapse's own panel proportions more closely
    // (roughly the same aspect ratio as Apple's Control Center).
    private static let defaultWidth: CGFloat = 900
    private static let defaultHeight: CGFloat = 580
    /// UserDefaults keys for the persisted panel position. Namespaced so
    /// the value doesn't collide with anything the SwiftUI framework
    /// itself might write.
    // v3 keys: earlier builds computed the default origin from
    // `intended.height` (content size) which excluded titlebar chrome —
    // resulting in an initial position that clampOnScreen would nudge
    // 8 pt down from the visible frame's top. Any origin saved from that
    // window ended up 8 pt off; bumping the key namespace invalidates
    // those stale values so the fixed default (flush 0 pt top-right)
    // takes effect on the next open. Old v2/v1 keys stay in defaults
    // but are ignored.
    private static let originXKey = "bskv3xhs.panel.originX.v3"
    private static let originYKey = "bskv3xhs.panel.originY.v3"

    /// True while `show()` is programmatically positioning the window.
    /// windowDidMove fires for both user drags AND our own setFrameOrigin
    /// / setContentSize / clampOnScreen calls — without this flag the
    /// programmatic side-effects overwrite whatever the user last picked,
    /// which is what drove the "position drifts every launch" bug. Only
    /// user drags should update the persisted origin.
    private var isProgrammaticMove = false

    private static func loadSavedOrigin() -> NSPoint? {
        let d = UserDefaults.standard
        guard let x = d.object(forKey: originXKey) as? Double,
              let y = d.object(forKey: originYKey) as? Double
        else { return nil }
        return NSPoint(x: x, y: y)
    }

    private static func saveOrigin(_ p: NSPoint) {
        let d = UserDefaults.standard
        d.set(Double(p.x), forKey: originXKey)
        d.set(Double(p.y), forKey: originYKey)
    }

    private func hide() {
        window?.orderOut(nil)
        removeOutsideClickMonitor()
        controller.setPanelVisible(false)
    }

    private func clampOnScreen() {
        guard let w = window, let screen = w.screen ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        var f = w.frame
        if f.maxX > vis.maxX { f.origin.x = vis.maxX - f.width - 8 }
        if f.minX < vis.minX { f.origin.x = vis.minX + 8 }
        if f.maxY > vis.maxY { f.origin.y = vis.maxY - f.height - 8 }
        if f.minY < vis.minY { f.origin.y = vis.minY + 8 }
        if f != w.frame { w.setFrame(f, display: false) }
    }

    // MARK: - Outside click

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()  // idempotent — never leak two
        // NSEvent global monitor fires for clicks in OTHER apps. This
        // includes clicks on the menu-bar tray icon (SystemUIServer owns
        // the menu bar, not us) — so a naive "hide on any global click"
        // fights the tray toggle: mouseDown fires the monitor → we hide,
        // mouseUp fires the tray action → toggle sees hidden → re-shows.
        // Net result: many clicks needed to close, or the panel oscillates.
        //
        // Filter: skip hiding when the click landed in the menu bar strip
        // (above the visibleFrame — where the tray icon lives). Menu-bar
        // clicks are the tray toggle's job; the outside-click monitor
        // only handles genuine "clicked in a different app window" cases.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            if Self.clickIsInMenuBar() { return }
            self.hide()
        }
    }

    /// True when the current cursor position is above the primary
    /// screen's `visibleFrame` — i.e. inside the menu bar strip where our
    /// tray icon lives. Uses NSEvent.mouseLocation instead of the event's
    /// own coords because global-monitor events have no window context.
    private static func clickIsInMenuBar() -> Bool {
        guard let screen = NSScreen.main else { return false }
        let loc = NSEvent.mouseLocation                     // screen coords, origin bottom-left
        return loc.y >= screen.visibleFrame.maxY
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Private

    private func build() -> NSWindow {
        let content = MainView().environmentObject(status).environmentObject(controller)
        let host = NSHostingController(rootView: content)
        host.view.wantsLayer = true
        // Minimal chrome — no `.closable / .miniaturizable / .resizable`.
        // The traffic-light zone (even with buttons hidden) reserves a
        // strip of the sidebar column's top when `.closable` is on, so
        // sidebar content ends up visibly lower than the detail
        // column's hero title. Dropping the flag flattens that strip
        // and lets both columns share the same top y.
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PanelController.defaultWidth, height: PanelController.defaultHeight),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.contentViewController = host
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // Content extends behind the titlebar strip (see MainView's
        // .ignoresSafeArea(edges: .top)) and the traffic lights are all
        // hidden — the visible titlebar zone is now just sidebar / detail
        // content. Let the user drag from anywhere in the window body
        // since the usual titlebar drag target no longer reads as one.
        // NOTE: kept OFF. When on, AppKit hit-tests every mouseDown against
        // `mouseDownCanMoveWindow` and any SwiftUI region that isn't backed
        // by an NSControl (including the macOS 26 native Slider, whose
        // hosting layer does *not* opt out on this version) initiates
        // window drag instead of the SwiftUI gesture. Users drag from the
        // (still-present but visually hidden) titlebar strip at the top —
        // matches standard macOS app behavior.
        w.isMovableByWindowBackground = false
        w.isReleasedWhenClosed = false
        // Make the window itself transparent so the SwiftUI `.glassEffect()`
        // in MainView's detail column (and the sidebar's own vibrancy
        // material) can refract the desktop / apps behind, instead of
        // compositing over the default opaque window background. macOS 26
        // Liquid Glass looks flat without this.
        w.isOpaque = false
        w.backgroundColor = .clear
        // Hide all traffic-light buttons — user request. Keep .closable
        // in the styleMask (so Tahoe still renders the floating-sidebar
        // container treatment) but make the buttons themselves invisible.
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        // Do NOT set hidesOnDeactivate — see the class-level note. We
        // dismiss via the outside-click NSEvent monitor instead so the
        // tray → panel handshake stays deterministic.
        w.hidesOnDeactivate = false
        // Follow the user across every Space (like the menu bar tray
        // icon does) so switching desktops doesn't leave the settings
        // window stranded on the Space it was opened from.
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Float above ordinary windows so the settings panel stays
        // available while the user is working in another app — matches
        // Synapse's "utility overlay" feel and the user's request that
        // the panel be permanently on top.
        w.level = .floating
        // Snap open — no zoom / genie animation.
        w.animationBehavior = .none
        w.center()
        w.delegate = self
        return w
    }

    // MARK: - NSWindowDelegate

    /// Standard red-close button also needs to remove the outside monitor.
    func windowWillClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        controller.setPanelVisible(false)
    }

    /// Persist the panel's origin only when the user actually dragged the
    /// window. `isProgrammaticMove` gates this — setFrameOrigin,
    /// setContentSize, and clampOnScreen all fire didMove; before the
    /// gate existed those callbacks would overwrite the user's saved
    /// origin with our computed one and the panel would slowly drift.
    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove else { return }
        guard let w = notification.object as? NSWindow else { return }
        let p = w.frame.origin
        Log.info("panel windowDidMove (user drag): saving origin (\(p.x), \(p.y))")
        Self.saveOrigin(p)
    }

    /// Trace any post-show resize so we can catch a runaway auto-size
    /// blowing the panel past its intended 900×580.
    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        Log.info("panel windowDidResize: frame=\(w.frame)")
    }
}
