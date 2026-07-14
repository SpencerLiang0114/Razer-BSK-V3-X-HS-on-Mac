import Foundation
import CoreGraphics

/// System-side scroll transform inspired by Mos: reverse direction (per-axis)
/// and/or convert discrete line ticks to interpolated pixel scroll. Runs at
/// the CGEventTap layer so it's transport-agnostic — works over dongle AND
/// Bluetooth. Applies only to line-based mouse wheels; the trackpad's
/// continuous scroll passes through untouched.
///
/// Wired into `ButtonMap`'s tap callback rather than owning its own tap so
/// button remaps and scroll transforms share a single event pipeline (order
/// matters and one tap keeps ordering trivially correct).
///
/// Thread model: `handle()` runs on the main thread (that's where the tap's
/// runloop lives); `tick()` runs on `queue`. Shared mutable state
/// (`_settings`, accumulators) is guarded by `lock`. Timer creation and
/// teardown happen only on `queue` so we don't have to lock around the
/// DispatchSourceTimer itself.
final class ScrollTransformer: @unchecked Sendable {
    static let shared = ScrollTransformer()

    // ─── Settings ────────────────────────────────────────────────────
    // Access serialized on `lock`. Read via `settings` getter, write via
    // setter — same pattern as CancelToken in Device.swift.
    private var _settings: ScrollSettings = .init()
    var settings: ScrollSettings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set {
            lock.lock()
            let becameDisabled = !newValue.enabled && _settings.enabled
            _settings = newValue
            if becameDisabled {
                // Drop any in-flight glide so a mid-flight tail doesn't keep
                // scrolling after the user toggled the feature off.
                accumulatorY = 0
                accumulatorX = 0
            }
            lock.unlock()
        }
    }

    // ─── Smoothing engine state ──────────────────────────────────────
    private var accumulatorY: Double = 0
    private var accumulatorX: Double = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "bskv3xhs.scroll", qos: .userInteractive)
    private let lock = NSLock()

    /// 120 Hz drain. Fast enough that pixel steps look smooth; slow enough
    /// that we don't melt a laptop on stray taps.
    private let tickIntervalMs: Int = 8

    /// Approx pixels emitted per line-tick at speed=1.0. Chosen to feel
    /// close to macOS's own line-to-pixel conversion for a mouse wheel with
    /// scroll speed set mid-slider in System Settings.
    private let basePixelsPerLine: Double = 80.0

    // ─── Own-event marker ────────────────────────────────────────────
    // The pixel-scroll events tick() posts also hit our tap. Without a way
    // to identify them we'd smooth our own output and spiral out (each
    // pixel post accumulates into the buffer, drains, re-posts, forever).
    // We tag events by stamping a magic value on the CGEventSource so all
    // events built from it carry the marker in `.eventSourceUserData`.
    static let ownEventMarker: Int64 = 0x4253_4B53_4352_4C00  // "BSKSCRL\0"
    private let source: CGEventSource? = {
        let src = CGEventSource(stateID: .hidSystemState)
        src?.userData = ScrollTransformer.ownEventMarker
        return src
    }()

    // ─── Public API ──────────────────────────────────────────────────

    enum Handling {
        /// Return the event to the tap unchanged.
        case passthrough
        /// The passed-in event was mutated in place; return it as-is.
        case modified
        /// Swallow the event; transformer will post its own via `tick()`.
        case consumed
    }

    /// Called from the CGEventTap callback (main thread) on every
    /// `.scrollWheel` event. Returns how the caller should propagate the
    /// event: pass through, return the mutated event, or drop it.
    func handle(_ event: CGEvent) -> Handling {
        // Our own re-posted pixel events must not re-enter the smoother.
        if event.getIntegerValueField(.eventSourceUserData) == Self.ownEventMarker {
            return .passthrough
        }

        lock.lock()
        let s = _settings
        lock.unlock()
        guard s.enabled else { return .passthrough }

        // If we couldn't build a stamped source at init the smoother's
        // re-injected events wouldn't carry the loop-guard marker — feeding
        // them back into `handle()` would then re-consume them forever
        // (runaway pixel scroll). Fall back to reverse-only in that case;
        // the source is a `let` on the shared instance so this stays stable.
        let sourceReady = (source != nil)

        // Trackpad / Magic Mouse smooth scroll has `IsContinuous` set. Leave
        // it alone — macOS's own physics is already doing the right thing.
        // Field 88 = kCGScrollWheelEventIsContinuous.
        if event.getIntegerValueField(CGEventField(rawValue: 88)!) != 0 {
            return .passthrough
        }

        let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let dx = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        if dy == 0 && dx == 0 { return .passthrough }

        var newDy = dy, newDx = dx
        if s.reverseVertical   { newDy = -newDy }
        if s.reverseHorizontal { newDx = -newDx }

        if !s.smoothingEnabled || !sourceReady {
            // Non-smoothing path — mutate the incoming event with the
            // reversed / scaled deltas and hand it back. This keeps the OS
            // in charge of everything else about the event (phase, source,
            // timestamp) and just changes the payload.
            let pointScale = Int64(max(1.0, basePixelsPerLine * s.speed / 10.0).rounded())
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: newDy)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: newDx)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: newDy * pointScale)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: newDx * pointScale)
            let fixed: Int64 = 0x10000
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: newDy * pointScale * fixed / 10)
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: newDx * pointScale * fixed / 10)
            return .modified
        }

        // Smoothing path — accumulate a pixel budget and let tick() drain it.
        let pixelsPerLine = basePixelsPerLine * s.speed
        lock.lock()
        accumulatorY += Double(newDy) * pixelsPerLine
        accumulatorX += Double(newDx) * pixelsPerLine
        lock.unlock()
        ensureTimer()
        return .consumed
    }

    // ─── Timer plumbing ──────────────────────────────────────────────

    private func ensureTimer() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let interval: DispatchTimeInterval = .milliseconds(self.tickIntervalMs)
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    /// Runs on `queue`. Drains a fraction of the accumulator, posts the
    /// integer-pixel remainder as a synthetic scrollWheel event, and stops
    /// the timer once there's nothing left to emit.
    private func tick() {
        lock.lock()
        let smoothness = _settings.smoothness
        // Exponential decay: after N ticks worth of `durationMs`, ~1% of the
        // original delta remains. That maps to a per-tick release fraction
        // of 1 - 0.01^(1/N). Snappy = 100 ms tail, glide = 400 ms tail.
        let durationMs = 100.0 + smoothness * 300.0
        let ticksInDuration = durationMs / Double(tickIntervalMs)
        let fraction = 1.0 - pow(0.01, 1.0 / max(1.0, ticksInDuration))

        let emitY = accumulatorY * fraction
        let emitX = accumulatorX * fraction
        // Snap to whole pixels for the post; keep the sub-pixel remainder
        // in the accumulator so slow flicks don't get truncated to zero.
        let iy = Int32(emitY.rounded())
        let ix = Int32(emitX.rounded())
        accumulatorY -= Double(iy)
        accumulatorX -= Double(ix)

        let done = abs(accumulatorY) < 0.5 && abs(accumulatorX) < 0.5 && iy == 0 && ix == 0
        if done {
            timer?.cancel()
            timer = nil
            accumulatorY = 0
            accumulatorX = 0
        }
        lock.unlock()

        if iy == 0 && ix == 0 { return }
        // `wheelCount: 2` = both vertical (wheel1) and horizontal (wheel2)
        // axes present. The source carries our ownEventMarker so handle()
        // recognises this event on the way back through and passes it.
        let event = CGEvent(scrollWheelEvent2Source: source,
                            units: .pixel,
                            wheelCount: 2,
                            wheel1: iy, wheel2: ix, wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }
}
