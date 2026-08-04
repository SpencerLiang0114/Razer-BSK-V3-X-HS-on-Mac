import XCTest
@testable import BSKV3XHS

/// Focus on the Codable paths: they carry legacy-file migrations and
/// clamps that silently misbehaving would corrupt existing users' saved
/// profiles. Anything decoded from disk must survive shape changes we've
/// added over time.
final class SettingsCodableTests: XCTestCase {

    // MARK: - AppSettings

    /// Round-trip: encoding then decoding must land on the same object,
    /// with no field dropped.
    func testAppSettingsRoundTrip() throws {
        let original = AppSettings.defaults
        let encoded  = try JSONEncoder().encode(original)
        let decoded  = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    /// Legacy profiles saved before `activeStage` was 1-based used
    /// `activeStage=0`. The decoder must clamp that to 1 (a firmware NAK
    /// on `active: 0` would drop the entire DPI-stages apply on the floor).
    func testAppSettingsClampsLegacyZeroActiveStage() throws {
        let legacyJSON = """
        {
          "dpi": { "activeStage": 0,
                   "stages": [{"x":800,"y":800},{"x":1600,"y":1600}] },
          "pollRateHz": 1000,
          "idleMinutes": 3
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.dpi.activeStage, 1,
                       "0 clamps up to 1 — never let firmware see active=0")
    }

    /// activeStage past the number of stages must clamp down to the last
    /// stage. Simulates a profile where the user deleted a stage
    /// externally and the file still points past the end.
    func testAppSettingsClampsActiveStagePastEnd() throws {
        let legacyJSON = """
        {
          "dpi": { "activeStage": 99,
                   "stages": [{"x":800,"y":800},{"x":1600,"y":1600}] },
          "pollRateHz": 1000,
          "idleMinutes": 3
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.dpi.activeStage, 2)
    }

    /// Profiles saved before `ScrollSettings` / `LowBattery` / hotspots
    /// existed must decode with defaults for the missing fields — a
    /// throw here would quarantine the user's whole settings.json.
    func testAppSettingsAddsDefaultsForMissingFields() throws {
        let veryOldJSON = """
        {
          "dpi": { "activeStage": 1, "stages": [{"x":800,"y":800}] },
          "pollRateHz": 500,
          "idleMinutes": 4
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: veryOldJSON)
        XCTAssertEqual(decoded.scroll, ScrollSettings())
        XCTAssertEqual(decoded.lowBattery, LowBatterySettings())
        XCTAssertTrue(decoded.hotspotOverrides.isEmpty)
        XCTAssertTrue(decoded.calloutOverrides.isEmpty)
    }

    // MARK: - LowBatterySettings clamp

    /// The decoder clamps to 1...100 — the same range the UI slider
    /// now exposes. Anything outside gets pulled to the nearest valid
    /// end so a hand-edited settings.json can't put the mouse into an
    /// unreachable threshold state.
    func testLowBatteryThresholdClampsAboveMax() throws {
        let json = """
        { "alertEnabled": true, "dimLEDEnabled": true, "threshold": 200 }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LowBatterySettings.self, from: json)
        XCTAssertEqual(decoded.threshold, 100, "clamps down to 100")
    }

    func testLowBatteryThresholdClampsBelowMin() throws {
        let json = """
        { "alertEnabled": true, "dimLEDEnabled": true, "threshold": -5 }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LowBatterySettings.self, from: json)
        XCTAssertEqual(decoded.threshold, 1, "clamps up to 1")
    }

    /// Values inside the valid 1...100 range pass through untouched —
    /// including the ones the old test file expected the decoder to
    /// clamp (5 and 80). Range broadened to support the "per-1%
    /// banners" preset (threshold=100).
    func testLowBatteryThresholdPassesThroughInRange() throws {
        for raw in [1, 5, 15, 30, 80, 100] {
            let json = """
            { "alertEnabled": true, "dimLEDEnabled": true, "threshold": \(raw) }
            """.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(LowBatterySettings.self, from: json)
            XCTAssertEqual(decoded.threshold, raw, "raw=\(raw) should pass through")
        }
    }

    // MARK: - DPIConfig xyIndependent

    /// `xyIndependent` is a UI-only flag added after the initial ship,
    /// so old files omit it. Decoder must default to `false`.
    func testDPIConfigMissingXYIndependent() throws {
        let json = """
        { "activeStage": 1, "stages": [{"x":1200,"y":1200}] }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DPIConfig.self, from: json)
        XCTAssertFalse(decoded.xyIndependent)
    }

    // MARK: - LightingEffect

    /// Enum-with-associated-values encoding — used to be a common source
    /// of subtle bugs where a mode's payload got dropped across decode.
    func testLightingEffectStaticRoundTrip() throws {
        let color = RGB(r: 128, g: 200, b: 255)
        let effect: LightingEffect = .static(color)
        let data   = try JSONEncoder().encode(effect)
        let decoded = try JSONDecoder().decode(LightingEffect.self, from: data)
        XCTAssertEqual(decoded, effect)
    }

    func testLightingEffectReactiveRoundTrip() throws {
        let effect: LightingEffect = .reactive(RGB(r: 30, g: 60, b: 90), speed: 3)
        let data   = try JSONEncoder().encode(effect)
        let decoded = try JSONDecoder().decode(LightingEffect.self, from: data)
        XCTAssertEqual(decoded, effect)
    }

    // MARK: - Profile export/import wrapper

    /// The .bskprofile export wrapper carries an app name + version so we
    /// can reject unrelated JSON that happens to match our shape.
    /// Confirm the wrapper's version field decodes as-is.
    func testProfileExportWrapperEncodesVersion() throws {
        let profile = Profile(id: UUID(), name: "Test", settings: AppSettings.defaults)
        let wrapper = SettingsStore.ProfileExport(
            app: SettingsStore.ProfileExport.currentApp,
            version: SettingsStore.ProfileExport.currentVersion,
            profile: profile
        )
        let data = try JSONEncoder().encode(wrapper)
        let decoded = try JSONDecoder().decode(SettingsStore.ProfileExport.self, from: data)
        XCTAssertEqual(decoded.app, SettingsStore.ProfileExport.currentApp)
        XCTAssertEqual(decoded.version, SettingsStore.ProfileExport.currentVersion)
        XCTAssertEqual(decoded.profile.name, profile.name)
    }

    // MARK: - SettingsFile decoding

    /// SettingsFile.defaultID was added after the initial ship — legacy
    /// files omit it; decoder must default to nil (which the auto-switch
    /// watcher reads as "no fallback profile").
    func testSettingsFileLegacyWithoutDefaultID() throws {
        let id = UUID()
        let json = """
        {
          "profiles": [{
            "id": "\(id.uuidString)",
            "name": "Default",
            "settings": {
              "dpi": {"activeStage":1,"stages":[{"x":800,"y":800}]},
              "pollRateHz": 1000,
              "idleMinutes": 3
            }
          }],
          "activeID": "\(id.uuidString)"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SettingsFile.self, from: json)
        XCTAssertEqual(decoded.profiles.count, 1)
        XCTAssertNil(decoded.defaultID)
    }
}
