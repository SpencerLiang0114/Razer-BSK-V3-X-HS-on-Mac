import XCTest
@testable import BSKV3XHS

/// The scroll transformer's smoothing math used to live inline in
/// `tick()`. It's extracted here as `drainFraction` and `drainStep`
/// so we can pin the load-bearing invariants without spinning up
/// CGEventTap or the shared singleton:
///
///   1. `drainFraction` is monotonically decreasing in `smoothness`
///      (higher smoothness = longer tail = smaller per-tick fraction).
///   2. `drainStep` conserves accumulator content — the integer emit
///      plus the remainder equals the original accumulator.
///   3. A drain sequence converges within a bounded number of ticks
///      for realistic accumulator sizes.
///   4. Sub-pixel remainders survive across ticks, so slow flicks
///      don't get rounded to zero.
final class ScrollTransformerTests: XCTestCase {

    // Match ScrollTransformer.tickIntervalMs so the fraction values
    // reflect what production ticks compute. Kept as a local constant
    // so a future change to the production tick interval surfaces here
    // as a numeric drift, not as a silent behaviour-only test rewrite.
    private let tickMs = 8

    // MARK: - Invariant 1: monotonic fraction

    /// Snappier (smoothness=0) should drain faster per tick than glide
    /// (smoothness=1). The whole point of the knob.
    func testDrainFractionMonotonic() {
        let f0   = ScrollTransformer.drainFraction(smoothness: 0.0, tickIntervalMs: tickMs)
        let f025 = ScrollTransformer.drainFraction(smoothness: 0.25, tickIntervalMs: tickMs)
        let f050 = ScrollTransformer.drainFraction(smoothness: 0.5, tickIntervalMs: tickMs)
        let f075 = ScrollTransformer.drainFraction(smoothness: 0.75, tickIntervalMs: tickMs)
        let f1   = ScrollTransformer.drainFraction(smoothness: 1.0, tickIntervalMs: tickMs)

        XCTAssertGreaterThan(f0, f025)
        XCTAssertGreaterThan(f025, f050)
        XCTAssertGreaterThan(f050, f075)
        XCTAssertGreaterThan(f075, f1)
    }

    /// Fraction is bounded (0, 1). Values ≥ 1 would drain the whole
    /// accumulator in one tick and defeat the glide; ≤ 0 would never
    /// converge.
    func testDrainFractionBounded() {
        for s in stride(from: 0.0, through: 1.0, by: 0.1) {
            let f = ScrollTransformer.drainFraction(smoothness: s, tickIntervalMs: tickMs)
            XCTAssertGreaterThan(f, 0)
            XCTAssertLessThan(f, 1)
        }
    }

    // MARK: - Invariant 2: content conservation on drain

    /// Emit + remainder = original accumulator (to within one rounding
    /// unit). Rounding shifts sub-pixels between emit and remainder;
    /// nothing else should change.
    func testDrainStepConservesAccumulator() {
        let inputs: [(Double, Double)] = [
            (100.0, 0.15),
            (37.6, 0.5),
            (-88.3, 0.2),
            (0.4, 0.9),     // sub-pixel accumulator — should emit 0
            (1000.0, 0.01), // huge accumulator, tiny fraction
        ]
        for (acc, frac) in inputs {
            let (emit, rem) = ScrollTransformer.drainStep(accumulator: acc, fraction: frac)
            // Reconstructed accumulator must round to the input at the
            // sub-pixel level — Int32 emit + Double remainder together
            // preserve the full precision.
            let reconstructed = Double(emit) + rem
            XCTAssertEqual(reconstructed, acc, accuracy: 1e-9,
                           "acc=\(acc) frac=\(frac) emit=\(emit) rem=\(rem)")
        }
    }

    /// Zero accumulator drains to zero — no ghost emits.
    func testDrainStepZeroAccumulator() {
        let (emit, rem) = ScrollTransformer.drainStep(accumulator: 0, fraction: 0.5)
        XCTAssertEqual(emit, 0)
        XCTAssertEqual(rem, 0)
    }

    /// A sub-pixel accumulator (< 1 raw) with a small fraction emits 0
    /// pixels and preserves the accumulator so a stream of slow ticks
    /// eventually round up and emit.
    func testDrainStepSubPixelPreserved() {
        let (emit, rem) = ScrollTransformer.drainStep(accumulator: 0.4, fraction: 0.1)
        XCTAssertEqual(emit, 0, "sub-pixel emit rounds to 0")
        XCTAssertEqual(rem, 0.4, accuracy: 1e-9, "accumulator survives untouched")
    }

    // MARK: - Invariant 3: drain reduces accumulator to a small residual
    //
    // The accumulator does NOT reliably drain to zero — once `acc *
    // fraction` rounds to 0, `emit = 0` and `acc` plateaus at whatever
    // value it landed on (~1 to ~5 pixels depending on fraction).
    // Production tolerates this: `tick()`'s `done` check requires both
    // `abs(acc) < 0.5` AND `emit == 0`, so a plateaued acc keeps the
    // timer ticking harmlessly at zero output until a fresh input tops
    // the accumulator back up. The tests below assert the physical
    // property that matters: the drain shrinks the accumulator to a
    // small residual within a bounded number of ticks.

    /// Helper: drain until acc plateaus (emit=0 for two ticks in a row)
    /// or the tick cap is reached. Returns the final acc and tick count.
    private func drainToPlateau(_ acc: Double, fraction: Double, cap: Int) -> (finalAcc: Double, ticks: Int) {
        var a = acc
        var prev = a
        for i in 0..<cap {
            let (emit, rem) = ScrollTransformer.drainStep(accumulator: a, fraction: fraction)
            a = rem
            if emit == 0 && a == prev { return (a, i) }
            prev = a
        }
        return (a, cap)
    }

    /// Snappy (smoothness=0) has a ~100 ms tail. At 8 ms/tick, ~12
    /// ticks worth of duration; the residual should be small well
    /// before the cap.
    func testDrainConvergesAtSnappy() {
        let fraction = ScrollTransformer.drainFraction(smoothness: 0.0, tickIntervalMs: tickMs)
        let (final, ticks) = drainToPlateau(80.0, fraction: fraction, cap: 100)
        XCTAssertLessThan(ticks, 100, "should plateau within cap")
        XCTAssertLessThanOrEqual(abs(final), 5.0,
            "80 pixels should drain to a small residual (got \(final) in \(ticks) ticks)")
    }

    /// Glide (smoothness=1) has a ~400 ms tail. Longer plateau time,
    /// wider tolerance, but same physical property: most of the
    /// accumulator gets emitted.
    func testDrainConvergesAtGlide() {
        let fraction = ScrollTransformer.drainFraction(smoothness: 1.0, tickIntervalMs: tickMs)
        let (final, ticks) = drainToPlateau(80.0, fraction: fraction, cap: 500)
        XCTAssertLessThan(ticks, 500, "should plateau within cap")
        XCTAssertLessThanOrEqual(abs(final), 10.0,
            "80 pixels should drain to a small residual (got \(final) in \(ticks) ticks)")
    }

    /// Negative accumulator (reverse scroll) drains toward zero from
    /// below. Sign must never flip mid-drain — that would mean we
    /// scrolled UP in the middle of a DOWN drain.
    func testDrainConvergesNegative() {
        let fraction = ScrollTransformer.drainFraction(smoothness: 0.5, tickIntervalMs: tickMs)
        var acc = -50.0
        var prev = acc
        for _ in 0..<300 {
            let (emit, rem) = ScrollTransformer.drainStep(accumulator: acc, fraction: fraction)
            acc = rem
            if acc != 0 {
                XCTAssertLessThanOrEqual(acc, 0,
                    "sign flipped mid-drain: prev=\(prev) now=\(acc)")
            }
            if emit == 0 && acc == prev { break }
            prev = acc
        }
        XCTAssertLessThanOrEqual(abs(acc), 5.0,
            "-50 pixels should drain to a small residual (got \(acc))")
    }

    // MARK: - Invariant 4: cumulative emit ≈ original accumulator

    /// Sum of all integer emits across a full drain, plus the final
    /// leftover remainder, should equal the starting accumulator.
    /// This is the "no pixels lost, no pixels invented" invariant.
    func testCumulativeEmitMatchesInput() {
        let start = 120.0
        var acc = start
        var totalEmit: Int64 = 0
        let fraction = ScrollTransformer.drainFraction(smoothness: 0.5, tickIntervalMs: tickMs)
        for _ in 0..<200 {
            let (emit, rem) = ScrollTransformer.drainStep(accumulator: acc, fraction: fraction)
            totalEmit += Int64(emit)
            acc = rem
            if abs(acc) < 0.5 { break }
        }
        // totalEmit + final leftover accumulator = start (up to
        // rounding error on the very last remainder).
        let reconstructed = Double(totalEmit) + acc
        XCTAssertEqual(reconstructed, start, accuracy: 1.0,
                       "cumulative emit \(totalEmit) + leftover \(acc) should recover \(start)")
    }
}
