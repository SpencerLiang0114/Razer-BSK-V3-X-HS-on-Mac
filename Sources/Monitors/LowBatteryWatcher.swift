import Foundation

/// Pure state machine for the low-battery UX: HUD-on-drop + LED auto-dim
/// with hysteresis. Doesn't touch HID, HUD, or SettingsStore — every
/// side-effect is returned as an `Event` so the caller decides how to
/// execute it. Keeps the notification latch and the dim latch in one
/// place so their reset semantics (on profile switch) can't drift.
///
/// Extracted from DeviceController for the same reason `BatterySmoother`
/// lives on its own: pure logic that's cheap to reason about and easy
/// to test without spinning up the whole HID stack.
struct LowBatteryWatcher {
    /// Snapshot of the user's low-battery settings + current LED state.
    /// Passed to `update` on every reading so the state machine doesn't
    /// need to depend on any shared / actor-isolated store.
    struct Config: Equatable {
        var alertEnabled: Bool
        var dimEnabled: Bool
        /// User's threshold slider (1–100). The alert path fires at
        /// `pct <= threshold`; the dim path caps at `dimThresholdCap`
        /// so a "notify on every 1%" preset doesn't turn the LED
        /// half-dark at 96% battery.
        var threshold: Int
        /// The user's committed LED brightness. Used to compute the
        /// dim target (`brightness / 2`) atomically at decision time
        /// — if the user tweaks brightness between decision and HID
        /// write, we still dim relative to what was live when the
        /// crossing happened.
        var currentBrightness: Int
    }

    /// One side-effect the caller should perform. Order in the returned
    /// array matches the order the events "happened" — alerts before
    /// dim/restore — which matters if a callsite chooses to log them.
    enum Event: Equatable {
        /// Show the per-drop battery HUD. `pct` is the freshly-observed
        /// smoothed reading.
        case showHUD(pct: Int)
        /// Write `brightness` to the LED via a RAM-scoped HID write so
        /// flash wear stays bounded. Caller may skip the write if the
        /// value matches what was already sent (dedup lives with the
        /// HID path, not with the state machine).
        case applyDim(brightness: Int)
        /// Restore the LED to the user's committed brightness. Caller
        /// reads that value at write time — the watcher doesn't cache
        /// it because "current" can move between events.
        case restoreBrightness
    }

    /// Band above `threshold` that a smoothed reading must climb back
    /// through before latches release. Prevents an oscillating value
    /// hovering near the boundary from re-firing the HUD every dip.
    private let hysteresis = 10

    /// Highest user threshold that still drives the LED dim path.
    /// Anything above this leaves the LED alone even if the notification
    /// still fires — user parked their slider at 100 to get per-1%
    /// pings should not see their mouse dim from full battery.
    private let dimThresholdCap = 30

    /// True while the current draining cycle has already fired at least
    /// one HUD alert. Prevents "just crossed 15%" from firing again
    /// as the reading noise-oscillates around the boundary.
    private var alertLatched = false

    /// Percentage at which the most recent HUD alert fired. Used to
    /// gate the "further drop" cadence: 20% → 15% → 10% fires three
    /// HUDs, but 15% → 16% → 15% only fires one. Nil when no alert
    /// has fired this cycle (or after a swap-detection rebase).
    private var lastNotifiedPct: Int? = nil

    /// True while the LED is currently held at the dimmed level. Kept
    /// independent of `alertLatched` because the two paths use
    /// different thresholds (see `dimThresholdCap`).
    private var dimLatched = false

    /// Feed a fresh smoothed battery reading. Returns the events the
    /// caller should execute (HUD, dim write, restore write). Empty
    /// return = no state change worth acting on.
    mutating func update(pct: Int, config: Config) -> [Event] {
        var events: [Event] = []
        let threshold = max(1, min(100, config.threshold))
        let clearAt = min(100, threshold + hysteresis)

        // Big upward jump = AA replacement (or an unrelated reading reset).
        // Rebase the "last notified" high-water mark to the new level so
        // subsequent drops re-notify from here. Without this, a swap from
        // 12% → 78% would leave `lastNotifiedPct = 12` stuck; a later
        // dip to 15% would then compute `dropped = false` at high
        // thresholds where the clear branch below doesn't fire (e.g.
        // threshold = 100).
        if let last = lastNotifiedPct, pct >= last + hysteresis {
            lastNotifiedPct = pct
        }

        // ── Alert path ────────────────────────────────────────────────
        if pct <= threshold {
            let firstCross = !alertLatched
            let dropped = lastNotifiedPct.map { pct < $0 } ?? true
            if config.alertEnabled && (firstCross || dropped) {
                events.append(.showHUD(pct: pct))
                lastNotifiedPct = pct
            }
            if firstCross { alertLatched = true }
        } else if alertLatched && pct >= clearAt {
            alertLatched = false
            lastNotifiedPct = nil
        }

        // ── Dim path ──────────────────────────────────────────────────
        // Independent latch: engages / clears against a possibly-lower
        // threshold (capped at `dimThresholdCap`) so a high notification
        // preset doesn't drag the LED dark.
        if config.dimEnabled {
            let dimThreshold = min(threshold, dimThresholdCap)
            let dimClearAt = min(100, dimThreshold + hysteresis)
            if pct <= dimThreshold && !dimLatched {
                dimLatched = true
                let target = max(0, config.currentBrightness / 2)
                events.append(.applyDim(brightness: target))
            } else if dimLatched && pct >= dimClearAt {
                dimLatched = false
                events.append(.restoreBrightness)
            }
        } else if dimLatched {
            // Feature switched off while the LED was actively held dim.
            // This branch used not to exist, so the whole dim block was
            // skipped and the latch stayed set with no restore emitted —
            // and nothing downstream repaired it, because the dim write is
            // RAM-scoped and deliberately doesn't move `lastApplied`, so
            // `apply()` saw `brightChanged == false` and wrote nothing.
            // The LED stayed at half brightness until the user happened to
            // touch the brightness slider or replug the dongle.
            dimLatched = false
            events.append(.restoreBrightness)
        }

        return events
    }

    /// Clear every latch so the next `update` re-evaluates from scratch.
    /// Only use this when we've genuinely lost the battery reading (e.g.
    /// mouse disconnected). For profile switches and reconnects where the
    /// battery is known, prefer `resetAndSeed(pct:config:)` — that
    /// version primes the latches to match `pct` silently so a static
    /// low-battery reading doesn't re-fire the HUD every time the
    /// user changes profiles or plugs the dongle back in.
    mutating func resetLatches() {
        alertLatched = false
        lastNotifiedPct = nil
        dimLatched = false
    }

    /// Clear latches AND prime them to the given `pct` under `config`
    /// without firing the alert HUD. Used at two moments where the
    /// battery reading was already low BEFORE the caller became
    /// responsible for it, so the "you just dropped below threshold"
    /// narrative would be a lie:
    ///
    ///   1. Auto-switch profile change — the reading didn't move,
    ///      only the threshold under it did. Firing a fresh HUD every
    ///      time the user swaps back to the default profile at low
    ///      battery is spammy noise.
    ///   2. Transport connect / hotplug — the mouse might have been
    ///      drained during a period we couldn't observe, and the
    ///      first fresh reading after plug-in shouldn't read as a
    ///      "drop" event.
    ///
    /// The dim path is NOT suppressed — LED brightness is hardware
    /// state that has to match the new profile's setting immediately,
    /// not a notification the user has to acknowledge. Emit
    /// `.applyDim` if the reading warrants it.
    mutating func resetAndSeed(pct: Int, config: Config) -> [Event] {
        // Remember whether the LED was being held dim BEFORE we clear the
        // latches — if the profile we're seeding into won't re-engage the
        // dim, the hardware needs an explicit restore. Clearing the latch
        // alone just makes the app forget it left the LED dark.
        let wasDimmed = dimLatched

        alertLatched = false
        lastNotifiedPct = nil
        dimLatched = false

        var events: [Event] = []
        let threshold = max(1, min(100, config.threshold))
        if pct <= threshold {
            // Latch silently — the current reading is below threshold
            // but the user hasn't experienced a drop. `update()` will
            // fire the HUD if a subsequent reading is genuinely lower.
            alertLatched = true
            lastNotifiedPct = pct
        }
        if config.dimEnabled {
            let dimThreshold = min(threshold, dimThresholdCap)
            if pct <= dimThreshold {
                dimLatched = true
                let target = max(0, config.currentBrightness / 2)
                events.append(.applyDim(brightness: target))
            }
        }
        // Dim was engaged under the previous config and the new one doesn't
        // want it (feature off, or a threshold this reading now sits above).
        // Same reasoning as the `update()` path: brightness is hardware
        // state, and the RAM-scoped dim write doesn't move `lastApplied`, so
        // `apply()` won't repair it on its own whenever the two profiles
        // happen to share a brightness value.
        if wasDimmed && !dimLatched {
            events.append(.restoreBrightness)
        }
        return events
    }
}
