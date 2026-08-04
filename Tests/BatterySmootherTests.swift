import XCTest
@testable import BSKV3XHS

/// The smoothing rules exist to hide AA voltage recovery — a fresh
/// idle read reports high, a heavy-use read reports low. These tests
/// pin the four invariants that keep the tray pill honest:
///   1. Steady-state reads collapse to the min in-window.
///   2. Voltage-recovery spikes are capped at maxUpwardStep per tick.
///   3. A swap-jump (≥ swapJump above min) flushes and lets the display
///      jump in one read.
///   4. Age-out preserves the newest sample as an anchor.
final class BatterySmootherTests: XCTestCase {
    // Fixture with faster-to-reason-about parameters. Behaviour under
    // the production values is validated in `testProductionDefaults`.
    private func makeSmoother() -> BatterySmoother {
        BatterySmoother(window: 60, swapJump: 10, maxUpwardStep: 2)
    }

    private let t0 = Date(timeIntervalSince1970: 0)
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - Invariant 1: display collapses to min-in-window

    func testDisplayIsMinInWindow() {
        var s = makeSmoother()
        _ = s.smooth(80, at: t(0))
        _ = s.smooth(75, at: t(5))
        _ = s.smooth(78, at: t(10))
        // Min so far is 75 (from t=5). The upward step cap wouldn't
        // apply to a downward direction — the display should read 75.
        XCTAssertEqual(s.smooth(76, at: t(15)), 75)
    }

    // MARK: - Invariant 2: upward step cap

    func testUpwardStepCapDuringVoltageRecovery() {
        var s = makeSmoother()
        // Establish a low-under-load anchor.
        _ = s.smooth(30, at: t(0))
        // A big idle-recovery spike arrives — the smoother must NOT
        // jump the display; instead, cap at prev + maxUpwardStep (2).
        // With swapJump=10, 30+10 is 40, so 45 is >= swap threshold —
        // adjust test to stay under swap.
        let stepped = s.smooth(38, at: t(5))     // +8 from anchor, under swap
        // Expected: display = min(30, 38) = 30, then upward cap
        // still applies against lastDisplayed=30 — but 30 <= 30+2
        // so no cap needed.
        XCTAssertEqual(stepped, 30)
        // Age out t(0) sample by moving to t(70). Fresh read at 38:
        // window empties (anchor preserved = t(5) sample=38), then
        // append (38, t(70)). min=38. But lastDisplayed=30, so cap
        // to 32.
        let capped = s.smooth(38, at: t(70))
        XCTAssertEqual(capped, 32, "upward step capped to prev+maxUpwardStep")
    }

    // MARK: - Invariant 3: swap-jump flushes + bypasses cap

    func testSwapJumpFlushesAndBypassesCap() {
        var s = makeSmoother()
        _ = s.smooth(25, at: t(0))
        _ = s.smooth(28, at: t(1))
        // Real AA swap → 95. That's +70 above min=25, well past swapJump=10.
        // Must flush and display should be 95 immediately — no upward cap.
        XCTAssertEqual(s.smooth(95, at: t(2)), 95)
        // And the new baseline should stick: another read at 94 should
        // display 94 (min in the flushed window is now just 95, then 94).
        XCTAssertEqual(s.smooth(94, at: t(3)), 94)
    }

    // MARK: - Invariant 4: anchor preservation on age-out

    func testAgeOutPreservesAnchor() {
        var s = makeSmoother()
        // Establish multiple in-window samples so the maintenance branch
        // actually runs (it's gated on count > 1).
        _ = s.smooth(40, at: t(0))
        _ = s.smooth(42, at: t(1))
        _ = s.smooth(45, at: t(2))
        // Fast-forward well past the window and read 48. Without anchor
        // preservation, samples would age out entirely and the new
        // reading (48) would become the min → display jerks up. With
        // preservation, the newest pre-purge sample (45) survives as
        // anchor and floors currentMin.
        let stepped = s.smooth(48, at: t(200))
        // currentMin becomes 45 after age-out. 48 < 45 + swapJump(10)
        // so no swap. min-in-window = 45. lastDisplayed=40 (never
        // moved during the pre-purge reads). Cap kicks in: 45 > 40+2=42.
        XCTAssertEqual(stepped, 42, "anchor preserves floor; upward cap protects display")
    }

    // MARK: - Reset semantics

    func testFullResetClearsSamplesAndAnchor() {
        var s = makeSmoother()
        _ = s.smooth(30, at: t(0))
        _ = s.smooth(50, at: t(1))
        s.reset()
        XCTAssertEqual(s.samples.count, 0)
        XCTAssertNil(s.lastDisplayed)
        // A fresh read after reset stands entirely on its own.
        XCTAssertEqual(s.smooth(80, at: t(2)), 80)
    }

    /// clearSamplesPreservingAnchor keeps the display anchor so that a
    /// post-wake voltage spike still triggers the upward cap.
    func testClearSamplesPreservingAnchor() {
        var s = makeSmoother()
        _ = s.smooth(40, at: t(0))
        s.clearSamplesPreservingAnchor()
        XCTAssertEqual(s.samples.count, 0)
        XCTAssertEqual(s.lastDisplayed, 40, "anchor preserved")
        // First post-wake read at 46 — display = 46, but cap against
        // lastDisplayed(40) + 2 = 42.
        XCTAssertEqual(s.smooth(46, at: t(1)), 42)
    }

    /// A real AA swap performed while the Mac was asleep must still be
    /// detected on the first post-wake read.
    ///
    /// Regression: swap detection compared `pct` against
    /// `samples.min() ?? pct`, so with the buffer emptied by
    /// `clearSamplesPreservingAnchor` the test was `pct >= pct + swapJump`
    /// — never true. The upward-step cap still applied (it reads
    /// `lastDisplayed`, which survives), so the display crawled up
    /// maxUpwardStep at a time: ~24 reads / ~18 min at production values,
    /// versus an instant jump for the identical swap with no sleep in
    /// between. Baseline now falls back to `lastDisplayed`.
    func testSwapDetectedOnFirstReadAfterWake() {
        var s = makeSmoother()
        _ = s.smooth(25, at: t(0))
        s.clearSamplesPreservingAnchor()
        // 25 → 95 is far beyond swapJump(10): flush and show it at once,
        // NOT 25 + maxUpwardStep(2) = 27.
        XCTAssertEqual(s.smooth(95, at: t(1)), 95,
                       "AA swapped during sleep must land in one read")
    }

    /// The empty-buffer fallback must not fire on a genuinely fresh
    /// smoother: with no samples AND no anchor there is nothing for a
    /// reading to be a swap relative to, so the first value passes
    /// through untouched.
    func testFirstEverReadHasNoSwapBaseline() {
        var s = makeSmoother()
        XCTAssertEqual(s.smooth(80, at: t(0)), 80)
        // Same after a full reset, which clears the anchor too.
        s.reset()
        XCTAssertEqual(s.smooth(12, at: t(1)), 12,
                       "post-reset read is unconstrained in both directions")
    }

    // MARK: - Boundary: single-sample smoother

    /// The maintenance branch only runs when `count > 1`, so a smoother
    /// with a single stale sample must still work — the append happens
    /// unconditionally and the min falls back to the freshly-passed
    /// value.
    func testSingleSampleAcrossWindow() {
        var s = makeSmoother()
        _ = s.smooth(75, at: t(0))
        // Second read a long time later — the maintenance branch's
        // `count > 1` gate keeps the old sample regardless of age;
        // the append then adds the new one. Both are in-window because
        // maintenance didn't age-out. min = min(75, 60) = 60.
        XCTAssertEqual(s.smooth(60, at: t(500)), 60)
    }

    // MARK: - Sanity check: production defaults

    /// A quick smoke test with the production parameter set (window=30
    /// min, swapJump=15, maxUpwardStep=3) to confirm the default
    /// constructor emits real behaviour, not a struct with all-zero
    /// tunables that quietly no-ops.
    func testProductionDefaults() {
        var s = BatterySmoother()
        XCTAssertEqual(s.window, 30 * 60)
        XCTAssertEqual(s.swapJump, 15)
        XCTAssertEqual(s.maxUpwardStep, 3)
        _ = s.smooth(20, at: t(0))
        _ = s.smooth(23, at: t(10))
        // display collapses to the min-in-window (20).
        XCTAssertEqual(s.lastDisplayed, 20)
    }
}
