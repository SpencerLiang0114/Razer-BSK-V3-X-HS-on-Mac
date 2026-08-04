import XCTest
@testable import BSKV3XHS

/// The low-battery watcher's job: fire a HUD when the reading crosses
/// below the user's threshold (and again on every genuine further
/// drop), engage LED auto-dim on a capped threshold, and NOT fire
/// spurious HUDs when the threshold shifts under a static reading
/// (profile switch) or when we discover an already-low reading after
/// a period we weren't observing (reconnect).
///
/// Every case below drives the pure state machine directly — no HID,
/// no HUD, no SwiftUI — so failures point at watcher logic, not at
/// integration glue.
final class LowBatteryWatcherTests: XCTestCase {

    /// Config helper — the four fields the caller always fills.
    private func cfg(threshold: Int = 15,
                     alert: Bool = true,
                     dim: Bool = true,
                     brightness: Int = 100) -> LowBatteryWatcher.Config {
        .init(alertEnabled: alert, dimEnabled: dim,
              threshold: threshold, currentBrightness: brightness)
    }

    // MARK: - Alert path

    /// First reading below threshold fires exactly one HUD.
    func testFirstCrossFiresHUD() {
        var w = LowBatteryWatcher()
        let events = w.update(pct: 14, config: cfg(threshold: 15))
        XCTAssertEqual(events.filter { if case .showHUD = $0 { return true } else { return false } }.count, 1)
    }

    /// A static reading at-or-below threshold doesn't re-fire the HUD
    /// on every update — the latch holds.
    func testHoldingAtThresholdDoesNotSpam() {
        var w = LowBatteryWatcher()
        _ = w.update(pct: 14, config: cfg(threshold: 15))
        let again = w.update(pct: 14, config: cfg(threshold: 15))
        XCTAssertFalse(again.contains { if case .showHUD = $0 { return true } else { return false } })
    }

    /// Every genuine per-1% drop re-fires. This is the "20 → 15 → 10"
    /// cascade users see when the battery is actively draining.
    func testFurtherDropsRefire() {
        var w = LowBatteryWatcher()
        _ = w.update(pct: 20, config: cfg(threshold: 20))    // first cross
        let e15 = w.update(pct: 15, config: cfg(threshold: 20)).contains { if case .showHUD(15) = $0 { return true } else { return false } }
        let e10 = w.update(pct: 10, config: cfg(threshold: 20)).contains { if case .showHUD(10) = $0 { return true } else { return false } }
        XCTAssertTrue(e15, "drop 20→15 should fire")
        XCTAssertTrue(e10, "drop 15→10 should fire")
    }

    /// Recovering above `threshold + hysteresis` clears the latch so a
    /// subsequent re-drop can fire again — for AA-swap-then-drain
    /// scenarios without a full swap-detection jump.
    func testRecoveryClearsLatch() {
        var w = LowBatteryWatcher()
        _ = w.update(pct: 12, config: cfg(threshold: 15))    // latched
        _ = w.update(pct: 26, config: cfg(threshold: 15))    // above 15+10=25, clears
        let redrop = w.update(pct: 12, config: cfg(threshold: 15))
        XCTAssertTrue(redrop.contains { if case .showHUD = $0 { return true } else { return false } },
                      "after recovery, a fresh drop below threshold should fire again")
    }

    /// Alerts disabled → no HUD ever, even on drops. Dim path is
    /// independent and still runs.
    func testAlertDisabledSuppressesHUD() {
        var w = LowBatteryWatcher()
        let events = w.update(pct: 10, config: cfg(threshold: 15, alert: false, dim: false))
        XCTAssertFalse(events.contains { if case .showHUD = $0 { return true } else { return false } })
    }

    // MARK: - Dim path

    /// Dim engages once when crossing the (capped) dim threshold.
    func testDimEngagesOnce() {
        var w = LowBatteryWatcher()
        let first = w.update(pct: 10, config: cfg(threshold: 15, brightness: 80))
        let dimEmits = first.filter { if case .applyDim = $0 { return true } else { return false } }
        XCTAssertEqual(dimEmits.count, 1, "one dim emit on first cross")

        if case .applyDim(let target) = dimEmits[0] {
            XCTAssertEqual(target, 40, "brightness / 2")
        } else {
            XCTFail("expected .applyDim event")
        }

        // Second update still below — no repeat dim.
        let repeat_ = w.update(pct: 10, config: cfg(threshold: 15, brightness: 80))
        XCTAssertFalse(repeat_.contains { if case .applyDim = $0 { return true } else { return false } })
    }

    /// Dim clears when the reading climbs back above `dim + hysteresis`
    /// — the LED gets restored.
    func testDimClearsOnRecovery() {
        var w = LowBatteryWatcher()
        _ = w.update(pct: 10, config: cfg(threshold: 15))
        let cleared = w.update(pct: 26, config: cfg(threshold: 15))
        XCTAssertTrue(cleared.contains { if case .restoreBrightness = $0 { return true } else { return false } })
    }

    /// The dim threshold is capped at `dimThresholdCap` (30) so a user
    /// who parked the notification threshold at 100 (per-1% banners
    /// preset) doesn't see the LED go half-dark at 96% battery.
    func testDimThresholdCapAt30() {
        var w = LowBatteryWatcher()
        // Alert threshold = 100, but dim shouldn't fire until pct <= 30.
        let events95 = w.update(pct: 95, config: cfg(threshold: 100))
        XCTAssertFalse(events95.contains { if case .applyDim = $0 { return true } else { return false } },
                       "95% is way above the dim cap — no dim")
        let events25 = w.update(pct: 25, config: cfg(threshold: 100))
        XCTAssertTrue(events25.contains { if case .applyDim = $0 { return true } else { return false } },
                      "25% is under the 30 cap — dim engages")
    }

    /// Dim disabled → no LED writes, even below threshold.
    func testDimDisabledSuppressesLEDWrites() {
        var w = LowBatteryWatcher()
        let events = w.update(pct: 5, config: cfg(threshold: 15, alert: false, dim: false))
        XCTAssertFalse(events.contains { if case .applyDim = $0 { return true } else { return false } })
    }

    /// Turning the auto-dim toggle OFF while the LED is currently dimmed
    /// must restore brightness.
    ///
    /// Regression: both the engage and the clear branch lived inside
    /// `if config.dimEnabled`, so flipping the toggle off skipped the whole
    /// block — no `.restoreBrightness` was ever emitted and `dimLatched`
    /// stayed true. Nothing else re-wrote brightness either: the dim write
    /// goes to RAM and deliberately does NOT update `lastApplied`, so
    /// `apply()` computed `brightChanged == false` (committed brightness
    /// never moved) and issued no HID write. The LED stayed at half
    /// brightness until the user nudged the brightness slider or replugged.
    func testDisablingDimWhileLatchedRestoresBrightness() {
        var w = LowBatteryWatcher()
        // Engage the dim at 10% with the feature on.
        let engaged = w.update(pct: 10, config: cfg(threshold: 15))
        XCTAssertTrue(engaged.contains(.applyDim(brightness: 50)), "precondition: dim engaged")
        // User now switches the feature off. Battery is unchanged.
        let events = w.update(pct: 10, config: cfg(threshold: 15, dim: false))
        XCTAssertTrue(events.contains(.restoreBrightness),
                      "disabling auto-dim must un-dim the LED")
        // And it must not repeat on subsequent readings — the latch is clear.
        let after = w.update(pct: 9, config: cfg(threshold: 15, dim: false))
        XCTAssertFalse(after.contains(.restoreBrightness), "restore fires once")
    }

    /// The disabled path must not emit a spurious restore when the dim was
    /// never engaged in the first place — otherwise every reading with the
    /// feature off would order a pointless HID brightness write.
    func testDisabledDimWithoutLatchEmitsNothing() {
        var w = LowBatteryWatcher()
        let events = w.update(pct: 5, config: cfg(threshold: 15, alert: false, dim: false))
        XCTAssertTrue(events.isEmpty, "no latch → no restore")
    }

    // MARK: - AA-swap rebase

    /// A big upward jump rebases `lastNotifiedPct` so the per-drop
    /// cadence resumes from the new high. Otherwise a swap from 12%
    /// to 78% would leave the "last notified" stuck at 12 and a
    /// later dip to 15 wouldn't re-notify (at high thresholds where
    /// the clear branch never fires).
    func testAASwapRebasesNotificationAnchor() {
        var w = LowBatteryWatcher()
        _ = w.update(pct: 12, config: cfg(threshold: 100))   // latched at 12
        // Swap from 12 → 78 = +66, more than 10 hysteresis away.
        // lastNotifiedPct should rebase to 78.
        _ = w.update(pct: 78, config: cfg(threshold: 100))
        // Now drop back to 76 (which is < 78, a genuine drop).
        let dropped = w.update(pct: 76, config: cfg(threshold: 100))
        XCTAssertTrue(dropped.contains { if case .showHUD(76) = $0 { return true } else { return false } },
                      "after rebase, a 78 → 76 drop should re-notify")
    }

    // MARK: - Reset + seed (the bug fix this test file is really for)

    /// The main scenario the user reported: profile switch fires a
    /// spurious HUD when the reading was already low. `resetAndSeed`
    /// must NOT emit `.showHUD` — the reading didn't move, only the
    /// threshold under it did.
    func testResetAndSeedDoesNotFireHUDAtOrBelowThreshold() {
        var w = LowBatteryWatcher()
        let events = w.resetAndSeed(pct: 12, config: cfg(threshold: 15))
        XCTAssertFalse(events.contains { if case .showHUD = $0 { return true } else { return false } },
                       "seed at low reading must not fire a HUD")
    }

    /// Seed IS allowed to emit `.applyDim` — LED brightness is
    /// hardware state that has to match the new profile immediately.
    /// The suppression is only for the notification path.
    func testResetAndSeedStillEmitsDim() {
        var w = LowBatteryWatcher()
        let events = w.resetAndSeed(pct: 10, config: cfg(threshold: 15, brightness: 80))
        let dims = events.filter { if case .applyDim = $0 { return true } else { return false } }
        XCTAssertEqual(dims.count, 1, "seed at low reading engages LED dim without a HUD")
    }

    /// Seeding into a profile that doesn't want the dim, while the LED is
    /// currently held dim, must restore brightness.
    ///
    /// Regression (profile-switch variant of
    /// `testDisablingDimWhileLatchedRestoresBrightness`): `resetAndSeed`
    /// cleared `dimLatched` unconditionally and only ever re-latched, so
    /// switching from a dim-engaged profile to one with the feature off
    /// made the app forget it had left the LED dark. `apply()` only rescued
    /// it when the two profiles' brightness values happened to differ.
    func testResetAndSeedRestoresWhenNewProfileDropsDim() {
        var w = LowBatteryWatcher()
        XCTAssertTrue(w.update(pct: 10, config: cfg(threshold: 15))
                        .contains(.applyDim(brightness: 50)), "precondition: dim engaged")
        // Switch to a profile with auto-dim off, same reading.
        let events = w.resetAndSeed(pct: 10, config: cfg(threshold: 15, dim: false))
        XCTAssertTrue(events.contains(.restoreBrightness))
    }

    /// The same handoff when the new profile keeps auto-dim on and still
    /// wants the LED dim must NOT emit a restore — that would flash the
    /// LED back to full and immediately dim it again on every switch.
    func testResetAndSeedKeepsDimWithoutRestoreChurn() {
        var w = LowBatteryWatcher()
        _ = w.update(pct: 10, config: cfg(threshold: 15))
        let events = w.resetAndSeed(pct: 10, config: cfg(threshold: 15))
        XCTAssertFalse(events.contains(.restoreBrightness), "still dim → no restore")
        XCTAssertTrue(events.contains(.applyDim(brightness: 50)), "re-latched for the new profile")
    }

    /// After seed, the watcher considers the reading "known low" and
    /// only fires the HUD on a GENUINE drop below that level.
    func testResetAndSeedPrimesForFutureDrops() {
        var w = LowBatteryWatcher()
        _ = w.resetAndSeed(pct: 12, config: cfg(threshold: 15))
        // Static reading at 12 — no new event.
        let same = w.update(pct: 12, config: cfg(threshold: 15))
        XCTAssertFalse(same.contains { if case .showHUD = $0 { return true } else { return false } })
        // A drop to 10 — this IS a real event, HUD fires.
        let dropped = w.update(pct: 10, config: cfg(threshold: 15))
        XCTAssertTrue(dropped.contains { if case .showHUD(10) = $0 { return true } else { return false } })
    }

    /// Seed at a reading ABOVE threshold doesn't latch — subsequent
    /// drops behave like a normal fresh state (first-cross fires).
    func testResetAndSeedAboveThresholdBehavesLikeFresh() {
        var w = LowBatteryWatcher()
        _ = w.resetAndSeed(pct: 50, config: cfg(threshold: 15))
        let events = w.update(pct: 14, config: cfg(threshold: 15))
        XCTAssertTrue(events.contains { if case .showHUD(14) = $0 { return true } else { return false } },
                      "seed above threshold should not suppress a real first-cross")
    }

    /// Sequential seeds (e.g. profile switch → BT reconnect on same
    /// low battery) both stay silent. No accumulated event backlog.
    func testMultipleSeedsStaySilent() {
        var w = LowBatteryWatcher()
        _ = w.resetAndSeed(pct: 10, config: cfg(threshold: 15))
        let secondSeed = w.resetAndSeed(pct: 10, config: cfg(threshold: 15))
        XCTAssertFalse(secondSeed.contains { if case .showHUD = $0 { return true } else { return false } })
    }
}
