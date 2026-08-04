import Foundation

/// AA voltage recovers when the mouse is idle or powered off — a fresh
/// read right after wake often reports much higher than a read taken
/// during heavy use. This smoother hides that jitter so the tray/pill
/// tracks the AA's true state rather than every voltage tick.
///
/// Rules:
///   • Sliding `window` of raw samples; display = min in window.
///   • A single reading ≥ `swapJump` pp above the current min flushes
///     the window (assumed real AA replacement → let display jump up).
///   • Age-out preserves the newest sample as an anchor even past
///     `window`, so a mouse that sat off for an hour doesn't forget
///     its state and let voltage-recovery blast the display to 100%.
///   • Between two consecutive displays the upward step is capped at
///     `maxUpwardStep` — voltage recovery spikes ~10-30 pp above the
///     under-load truth, and we don't want the pill to jerk from
///     25% → 100% just because the mouse sat off for a while. Real
///     fresh batteries still climb there over a few reads.
///
/// Extracted from DeviceController so the rules can be exercised in
/// unit tests without spinning up the full HID stack.
struct BatterySmoother {
    struct Sample: Equatable { let pct: Int; let at: Date }

    let window: TimeInterval
    let swapJump: Int
    let maxUpwardStep: Int

    private(set) var samples: [Sample] = []
    private(set) var lastDisplayed: Int? = nil

    init(window: TimeInterval = 30 * 60,
         swapJump: Int = 15,
         maxUpwardStep: Int = 3) {
        self.window = window
        self.swapJump = swapJump
        self.maxUpwardStep = maxUpwardStep
    }

    /// Ingest a raw reading and return the smoothed display value.
    ///
    /// `at` is exposed so tests can drive the timeline without waiting
    /// for wall-clock; production callers pass `Date()`.
    mutating func smooth(_ pct: Int, at now: Date = Date()) -> Int {
        // Age out samples older than the window, always preserving the
        // newest sample as an anchor. Empty-buffer + voltage-recovery
        // spike would otherwise set a new min at the spike level and
        // ratchet the pill up incorrectly.
        if samples.count > 1 {
            let sorted = samples.sorted { $0.at > $1.at }
            let anchor = sorted[0]
            samples.removeAll { now.timeIntervalSince($0.at) > window }
            if samples.isEmpty { samples.append(anchor) }
        }

        // Fresh-battery heuristic: a large jump upward flushes the
        // window so the display can catch up. Bypasses the upward-step
        // cap for this reading — otherwise a 25% → 95% swap would clip
        // to +3pp per read and take ~15 min for the pill to reflect
        // the new AA, defeating the detection entirely.
        // Baseline for swap detection. Falling back to `lastDisplayed` when
        // the sample buffer is empty is load-bearing: `?? pct` made
        // `swapDetected` compare `pct >= pct + swapJump`, i.e. always false.
        // That silently disabled swap detection on exactly the path
        // `clearSamplesPreservingAnchor` creates (system wake) — where the
        // buffer is empty but `lastDisplayed` still constrains the upward
        // step. Net effect: swap the AA while the Mac is asleep and the pill
        // crawled +maxUpwardStep per read, taking ~24 reads (~18 min at the
        // 45 s battery TTL) to reach the real level, while the same swap
        // without an intervening sleep was detected instantly.
        //
        // `?? pct` remains the final fallback for a genuinely fresh smoother
        // (no samples AND no anchor, e.g. after `reset()`), where the first
        // reading has nothing to be a swap relative to.
        let currentMin = samples.map(\.pct).min() ?? lastDisplayed ?? pct
        let swapDetected = pct >= currentMin + swapJump
        if swapDetected {
            samples.removeAll()
        }
        samples.append(Sample(pct: pct, at: now))

        var display = samples.map(\.pct).min() ?? pct
        if !swapDetected, let prev = lastDisplayed, display > prev + maxUpwardStep {
            display = prev + maxUpwardStep
        }
        lastDisplayed = display
        return display
    }

    /// Drop all samples + reset the anchor. Called on hotplug `.none`
    /// or transitions where the physical battery might have changed
    /// (dongle re-enumeration after a longer absence).
    mutating func reset() {
        samples.removeAll()
        lastDisplayed = nil
    }

    /// Drop samples but keep the last displayed value as the upward-step
    /// anchor. Called on system wake, where we don't know if the battery
    /// physically changed — preserving `lastDisplayed` guards against a
    /// post-wake voltage-recovery spike blowing the pill upward before
    /// the smoothing window has a chance to gather fresh samples.
    /// A real replacement is caught by the swap-jump detection either
    /// way, so we don't need to be conservative in both directions.
    mutating func clearSamplesPreservingAnchor() {
        samples.removeAll()
    }
}
