import XCTest
@testable import BSKV3XHS

/// Unit tests for the pure-logic parts of `Razer` — the frame builder,
/// CRC computation, response parser, and command factories. These
/// exchange no I/O, so any regression here is a straight code bug.
final class RazerProtocolTests: XCTestCase {

    // MARK: - Frame builder

    func testFrameBuilderShapeAndDefaults() {
        let f = Razer.frame(class: 0x07, id: 0x80, args: [0x00, 0x00])
        XCTAssertEqual(f.count, Razer.reportLen, "report is always 90 bytes")
        XCTAssertEqual(f[0], 0x00, "leading status byte is zero for outbound")
        XCTAssertEqual(f[1], Razer.transactionID, "transaction id 0x1F (HyperSpeed dongle)")
        XCTAssertEqual(f[5], 0x02, "arg count byte reflects payload length")
        XCTAssertEqual(f[6], 0x07, "class byte")
        XCTAssertEqual(f[7], 0x80, "cmd byte")
        XCTAssertEqual(f[8], 0x00, "first arg")
        XCTAssertEqual(f[9], 0x00, "second arg")
    }

    func testFrameBuilderComputesCRC() {
        let f = Razer.frame(class: 0x07, id: 0x80, args: [0x00, 0x00])
        // CRC lives at byte 88, and equals XOR of bytes [2, 87].
        var xor: UInt8 = 0
        for i in 2..<88 { xor ^= f[i] }
        XCTAssertEqual(f[88], xor, "CRC byte at offset 88")
        XCTAssertEqual(f[88], Razer.crc(f), "helper returns matching value")
    }

    // MARK: - Response parser

    /// Round-trip: build a frame, mutate its status byte to simulate a
    /// response, feed to `parse` — CRC must validate, class/id must echo.
    func testParseRoundTrip() {
        var f = Razer.frame(class: 0x00, id: 0x81, args: [1, 2])
        f[0] = Razer.ResponseStatus.success.rawValue        // pretend the mouse answered
        f[88] = Razer.crc(f)                                // recompute after status flip
        let parsed = Razer.parse(f)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.status, Razer.ResponseStatus.success.rawValue)
        XCTAssertEqual(parsed?.cls, 0x00)
        XCTAssertEqual(parsed?.id, 0x81)
        XCTAssertEqual(parsed?.args.count, 80, "args slice is always 80 bytes")
        XCTAssertEqual(parsed?.args[0], 1)
        XCTAssertEqual(parsed?.args[1], 2)
        XCTAssertTrue(parsed?.crcOK == true, "CRC verifies")
    }

    /// Some HID stacks prepend a 0x00 report-id byte — parse must accept
    /// both 90-byte and 91-byte inputs and land on the same frame.
    func testParseAcceptsPrependedReportID() {
        let base = Razer.frame(class: 0x00, id: 0x82, args: [])
        var with91 = [UInt8](repeating: 0, count: Razer.reportLen + 1)
        with91[0] = 0                                       // report-id byte
        for i in 0..<Razer.reportLen { with91[i + 1] = base[i] }
        let parsed = Razer.parse(with91)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.cls, 0x00)
        XCTAssertEqual(parsed?.id, 0x82)
    }

    /// A CRC-bad response must still parse (so callers can log
    /// diagnostics), but `crcOK` must reflect the tamper.
    func testParseDetectsBadCRC() {
        var f = Razer.frame(class: 0x00, id: 0x81)
        f[88] &+= 1                                         // flip the CRC
        let parsed = Razer.parse(f)
        XCTAssertNotNil(parsed)
        XCTAssertFalse(parsed?.crcOK == true, "corrupted CRC must NOT verify")
    }

    /// A too-short buffer must return nil rather than trap on subscript.
    func testParseRejectsShortBuffer() {
        XCTAssertNil(Razer.parse([UInt8](repeating: 0, count: 32)))
    }

    // MARK: - Poll rate mapping

    func testPollRateWireByteRoundTrip() {
        for hz in [125, 500, 1000] {
            let frame = Razer.pollRateWrite(hz)
            let wireByte = frame[8]                         // args[0]
            XCTAssertEqual(Razer.pollRateFromByte(wireByte), hz)
        }
    }

    func testPollRateUnknownByte() {
        XCTAssertNil(Razer.pollRateFromByte(0xFF))
    }

    // MARK: - DPI stage builder clamps

    func testDPIStagesWriteClampsToRange() {
        // Values below 100 and above 45000 must clamp — the mouse's
        // sensor range on this device is roughly 100–18000 but the wire
        // protocol accepts up to 45000; we still refuse zero / negatives.
        let f = Razer.dpiStagesWrite(active: 1, stages: [(x: 50, y: 60000)])
        // args[0]=store 0x01, args[1]=active=1, args[2]=count=1
        // args[3]=index=1, args[4..5]=x-high/low, args[6..7]=y-high/low
        let xHi = f[8 + 4], xLo = f[8 + 5]
        let yHi = f[8 + 6], yLo = f[8 + 7]
        let x = (Int(xHi) << 8) | Int(xLo)
        let y = (Int(yHi) << 8) | Int(yLo)
        XCTAssertEqual(x, 100, "50 clamps up to 100")
        XCTAssertEqual(y, 45000, "60000 clamps down to 45000")
    }

    // MARK: - Idle-minutes builder

    func testIdleTimeWriteBigEndianMinutes() {
        // 5 minutes = 300 seconds = 0x012C.
        let f = Razer.idleTimeWrite(minutes: 5)
        XCTAssertEqual(f[8], 0x01, "seconds high byte")
        XCTAssertEqual(f[9], 0x2C, "seconds low byte")
    }

    func testIdleTimeWriteClampsRange() {
        // Firmware accepts 1..15; anything outside must clamp.
        let below = Razer.idleTimeWrite(minutes: 0)
        let above = Razer.idleTimeWrite(minutes: 60)
        // 1 minute → 60 s → 0x003C, 15 minutes → 900 s → 0x0384.
        XCTAssertEqual(below[8], 0x00); XCTAssertEqual(below[9], 0x3C)
        XCTAssertEqual(above[8], 0x03); XCTAssertEqual(above[9], 0x84)
    }

    // MARK: - Lighting builders

    /// The wave direction byte matches OpenRazer's clamp: left→right
    /// encodes as 0x02, right→left as 0x01.
    func testLightingWaveDirectionByte() {
        let ltr = Razer.lightingWave(direction: .leftToRight)
        let rtl = Razer.lightingWave(direction: .rightToLeft)
        // args[0]=store, args[1]=scrollLED, args[2]=effect, args[3]=direction
        XCTAssertEqual(ltr[8 + 3], 0x02)
        XCTAssertEqual(rtl[8 + 3], 0x01)
    }

    /// Reactive speed must clamp into 1..4 regardless of caller input.
    func testLightingReactiveSpeedClamps() {
        let low  = Razer.lightingReactive(r: 0, g: 0, b: 0, speed: 0)
        let high = Razer.lightingReactive(r: 0, g: 0, b: 0, speed: 99)
        XCTAssertEqual(low[8 + 4],  1)
        XCTAssertEqual(high[8 + 4], 4)
    }

    /// Brightness helper accepts 0..255 on the wire; the Service layer
    /// converts 0..100 percent → 0..255 before calling this. Confirm the
    /// raw byte lands unchanged in the frame.
    func testBrightnessWirePayload() {
        let f = Razer.brightnessWrite(0x80)
        XCTAssertEqual(f[8 + 2], 0x80)
    }
}
