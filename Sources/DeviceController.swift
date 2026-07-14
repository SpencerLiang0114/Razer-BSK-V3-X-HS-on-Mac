import Foundation
import Combine
import AppKit
@preconcurrency import UserNotifications

// ─── DeviceController ────────────────────────────────────────────────
// The orchestrator. Owns transport + monitors + published status. All
// side-effectful HID work goes through here so the UI layer stays passive.

@MainActor
final class DeviceController: ObservableObject {
    let status = Status()

    private let device: Device
    private let service: Service
    private let hotplug: Hotplug
    private let input: InputActivity
    /// CoreBluetooth GATT Battery Service reader — Strategy 0, before the
    /// IORegistry/IOPowerSources fallbacks. macOS's HID stack doesn't
    /// always copy the mouse's GATT battery value into IORegistry, and
    /// on this specific Mac none of the four registry paths work.
    /// Reading GATT directly is what Apple's System Settings itself does.
    private let gattBattery: GATTBattery
    /// Watches focused-app changes so we can auto-switch profiles when
    /// the user opens one that's bound to a specific profile.
    private let appSwitchWatcher: AppSwitchWatcher

    private var awakeDecayTask: Task<Void, Never>?
    private var probeInFlight = false
    /// Latch so a stream of skipped probes only prints one line, not one
    /// per input event during a long in-flight probe. Cleared when the
    /// next probe actually runs.
    private var probeSkipLogged = false
    private var lastActivity: Date = .distantPast
    private var lastBatteryReadAt: Date = .distantPast
    private let batteryTTL: TimeInterval = 45
    /// When the most recent probe threw. Used to space opportunistic probes
    /// so a stream of input events during an unreachable window doesn't
    /// stack retries (each of which fails after several hundred ms).
    private var lastProbeFailedAt: Date = .distantPast
    private let probeFailureCooldown: TimeInterval = 10
    /// If the user's input arrived within this window, we treat the mouse
    /// as definitively awake even if a background probe times out. Feature-
    /// report exchange competes with the mouse's active HID input traffic
    /// on the same radio, so short-profile probes commonly time out during
    /// bursts of movement — flipping `awake=false` there is what makes the
    /// tray icon flicker between states while the user is actually using
    /// the mouse.
    private let recentInputGrace: TimeInterval = 6
    /// Cadence for reconciling the active DPI stage against hardware — picks
    /// up firmware-driven changes made by the physical DPI cycle button on
    /// the mouse itself, which we have no other way to observe.
    private var lastStageReadAt: Date = .distantPast
    private let stageReadTTL: TimeInterval = 10
    /// One-in-flight guard for `reconcileActiveStage`. Foreground fast-poll
    /// (1 s) and input-activity taps can both queue reconciles, and the
    /// Device queue serializes them — so without this flag, a mouse that's
    /// slow to answer builds a growing backlog of stale reads that all
    /// arrive back at once and repeatedly hammer the mouse.
    private var reconcileInFlight = false

    /// The current debounced-auto-apply task. Kept on the controller (not the
    /// view) so it can be cancelled from device-lifecycle callbacks — e.g.
    /// we cancel it the moment the dongle goes away, so we don't try to
    /// finish writing to a mouse that's no longer there.
    var autoApplyTask: Task<Void, Never>? = nil

    /// Interactive lighting task — writes to `.ram` on the mouse so the LED
    /// updates instantly without touching onboard flash. Rebuilt on every
    /// mid-drag change; cancelled on hotplug or when the flash-commit path
    /// takes over.
    var lightingRAMTask: Task<Void, Never>? = nil

    /// Delayed onboard-flash commit for the current lighting state. Fires
    /// ~500 ms after the last mid-drag edit. Cancelled and re-armed on every
    /// mid-drag change so a long slow drag results in exactly one flash
    /// write per drag session.
    var lightingFlashTask: Task<Void, Never>? = nil

    /// Last lighting state actually shipped to `.ram`. Used to dedupe
    /// no-op RAM writes during a rapid ColorPicker drag — sending the same
    /// effect frame twice restarts the mouse's effect timer.
    private var lastRAMLighting: LightingSettings? = nil

    /// True while `apply()` is actively running (between HID writes). Guards
    /// background reconcile paths from stomping on state we're about to
    /// overwrite anyway — e.g. `reconcileActiveStage` reading the mouse's
    /// pre-apply DPI stage and writing it back to disk while apply is still
    /// committing new stages.
    private var applyInFlight = false

    /// Untracked hotplug-probe Task. Stored so `.none` / `.bluetooth`
    /// transitions can cancel it — otherwise a rapid dongle→away→back cycle
    /// (Parallels / VMware claiming the device) leaves probes running
    /// against a state the controller has already cleaned up.
    private var hotplugProbeTask: Task<Void, Never>? = nil

    // ─── Unified periodic pump ───────────────────────────────────────
    // One Task replaces what used to be four overlapping timers:
    //   • pollTimer                  (15 s dongle keep-alive)
    //   • btBatteryTask              (30 s BT battery re-read loop)
    //   • foregroundReconcileTask    (1.5 s DPI-stage reconcile while
    //                                 the settings panel is visible)
    //   • GATTBattery.refreshTimer   (120 s explicit GATT re-read)
    //
    // Cadence flips with panel visibility (see `pumpInterval`): fast
    // while the user is watching the panel and connected via the
    // dongle, background otherwise. Per-work-item TTLs
    // (`dongleKeepaliveTTL`, `btBatteryPollTTL`, `stageReconcileTTL`,
    // `gattRereadTTL`) decide what actually runs inside a given tick —
    // most ticks are no-ops, matching what the old separate timers did
    // in aggregate.
    //
    // Calling `startPump()` re-cancels any in-flight sleep, so cadence
    // changes (panel toggle, hotplug, wake-from-sleep) take effect on
    // the very next tick instead of waiting out a stale interval.
    private var pumpTask: Task<Void, Never>? = nil
    private var lastDonglePollAt: Date = .distantPast
    private var lastBTBatteryPollAt: Date = .distantPast
    /// Last time we asked GATT to re-read the battery-level characteristic
    /// on an already-connected peripheral. Separate from `lastBTBatteryPollAt`
    /// because IORegistry polling (30 s) and GATT explicit re-read (120 s)
    /// are complementary — one goes through Apple's cached HID stack, the
    /// other kicks the mouse directly. GATT push handles most updates on
    /// its own; the 120 s tick is only a safety net for firmwares that
    /// stop pushing after a radio nap.
    private var lastGATTReadAt: Date = .distantPast
    private let pumpForegroundInterval: TimeInterval = 1.5
    private let pumpBackgroundInterval: TimeInterval = 15
    private let dongleKeepaliveTTL: TimeInterval = 15
    private let stageReconcileTTL: TimeInterval = 1.5
    private let btBatteryPollTTL: TimeInterval = 30
    private let gattRereadTTL: TimeInterval = 120

    /// Foreground/background split — see `pumpInterval`. The pump uses
    /// this to decide cadence; PanelController tells us via
    /// `setPanelVisible`.
    private var panelVisible = false

    /// Last state we successfully pushed to the mouse. `apply()` skips any
    /// field that matches this snapshot so an unrelated slider tweak doesn't
    /// re-write DPI stages, poll rate, and idle time on every debounced fire.
    /// Cleared on hotplug so a reconnected mouse gets a fresh full apply.
    private var lastApplied: AppSettings? = nil

    /// Combine subscriptions owned by the controller — currently the
    /// SettingsStore activeID watcher that drives profile switches.
    private var cancellables = Set<AnyCancellable>()

    /// How long after the last input event we treat the mouse as "asleep"
    /// in the UI. Matched to the mouse's own onboard idle-sleep setting
    /// (plus a small buffer for the transition) so the tray icon dimming
    /// coincides with the mouse's actual radio power-down.
    ///
    /// Was a flat 8 s when pollTimer probed every 3 s (probes kept
    /// `lastActivity` fresh and this window never expired in practice).
    /// After the energy pass killed the polling, the tray started dimming
    /// after 8 s of no motion even though the mouse's own idle timer is
    /// several minutes — this reads the user's chosen idle-minutes
    /// setting so we stay in sync with what the hardware is doing.
    private var awakeTimeout: TimeInterval {
        let minutes = max(1, status.settings.idleMinutes)
        return TimeInterval(minutes * 60 + 30)
    }

    init() {
        device  = Device()
        service = Service(device: device)
        hotplug = Hotplug()
        input   = InputActivity()
        gattBattery = GATTBattery()
        appSwitchWatcher = AppSwitchWatcher(
            excludeBundleID: Bundle.main.bundleIdentifier
        )
    }

    // MARK: - Public

    func start() {
        wireHotplug()
        wireInput()
        wireSleepWake()
        startPump()
        requestNotificationAuthorizationOnLaunch()
        // GATT feeds smoothed battery on every peripheral update, on any
        // transport (dongle mode still gets updates if the mouse's BLE
        // stack is paired in the background — harmless duplication with
        // the vendor-protocol read; both call setSmoothedBattery which
        // dedupes identical values).
        gattBattery.onBattery = { [weak self] pct in
            guard let self else { return }
            self.setSmoothedBattery(pct)
        }
        // Firmware / serial coming from GATT's Device Information
        // Service. Only populate when the vendor-protocol read didn't
        // supply them (dongle mode wins because its values are
        // authoritative for the current session). Also skip when the
        // dongle is present — the vendor value is fresher.
        gattBattery.onFirmware = { [weak self] fw in
            guard let self else { return }
            guard self.status.connection == .bluetooth else { return }
            if self.status.firmware == nil { self.status.firmware = fw }
        }
        gattBattery.onSerial = { [weak self] sn in
            guard let self else { return }
            guard self.status.connection == .bluetooth else { return }
            if self.status.serial == nil { self.status.serial = sn }
        }
        // Push persisted button map to CGEventTap on launch. Runs over any
        // transport (BT included) — the tap is OS-level, not HID-level.
        let current = SettingsStore.shared.current
        ButtonMap.shared.apply(current.buttons)
        // Same for the scroll transformer. Also transport-agnostic — its
        // input comes from the same OS event tap ButtonMap owns.
        ScrollTransformer.shared.settings = current.scroll
        ButtonMap.shared.scrollSettingsChanged()
        // Wire sensitivity-cycle actions so buttons mapped to
        // "Cycle DPI stage" can reach the mouse via us.
        ButtonMap.shared.onSensitivity = { [weak self] action in
            guard let self else { return }
            Task { @MainActor [weak self] in await self?.cycleStage(action) }
        }
        status.connection = hotplug.kind
        status.present = hotplug.present
        // Kick off transport-appropriate one-shot reads on launch. wireHotplug
        // handles later transitions — this handles the initial state, since
        // the hotplug callback doesn't fire for an already-connected device.
        // The pump (started above) then takes over for the recurring reads.
        switch status.connection {
        case .dongle:    Task { await self.probe(profile: .short) }
        case .bluetooth:
            pollBluetoothBattery()
            lastBTBatteryPollAt = Date()
            gattBattery.refresh()
        case .none:      break
        }

        // Profile switching. Store stays a pure data layer — the controller
        // owns the side-effects (HID push, button-map, scroll-transformer,
        // low-battery latch reset). Filtered to activeID transitions so a
        // slider edit inside a profile (which also publishes `$file`)
        // doesn't get treated as a switch. `dropFirst` skips the initial
        // value at subscription time so launch doesn't fire a spurious
        // apply on top of the sync-from-hardware path.
        SettingsStore.shared.$file
            .map(\.activeID)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applyActiveProfile(reason: "profile switch")
                }
            }
            .store(in: &cancellables)

        // Auto-switch: when the frontmost app changes, look up whether any
        // profile lists that bundle ID in its `triggerBundleIDs`. If yes,
        // activate that profile. If not, fall back to the user's chosen
        // default profile (if any). No default → no change.
        appSwitchWatcher.onFocusChange = { [weak self] bundleID in
            Task { @MainActor [weak self] in
                self?.handleFocusedApp(bundleID)
            }
        }
        appSwitchWatcher.start()
    }

    /// Auto-switch driver. Called from `AppSwitchWatcher` on every focused-
    /// app change. Chooses the target profile:
    ///
    ///   • If some profile's `triggerBundleIDs` contains the focused app's
    ///     bundle ID, that profile wins. Multiple matches → the first one
    ///     in `file.profiles` (list order is stable and user-visible).
    ///   • Otherwise, fall back to `file.defaultID` if set. This is what
    ///     "打开时切换，关掉时切回去" reduces to: when focus leaves the
    ///     triggering app for any app that has no rule, we revert.
    ///   • If no default is set and no rule matched, keep the current
    ///     profile. Users who don't use auto-switch shouldn't see their
    ///     profile changed by focus events.
    ///
    /// Returning early when the target equals the currently-active profile
    /// keeps a tight ⌘⇥ loop between mapped and unmapped apps from firing
    /// pointless `setActive` writes.
    private func handleFocusedApp(_ bundleID: String?) {
        let file = SettingsStore.shared.file
        let matched: UUID? = {
            guard let bid = bundleID else { return nil }
            return file.profiles.first { $0.triggerBundleIDs.contains(bid) }?.id
        }()
        let target = matched ?? file.defaultID
        guard let target, target != file.activeID else { return }
        Log.info("auto-switch: focused=\(bundleID ?? "nil") → profile \(target.uuidString.prefix(8))")
        SettingsStore.shared.setActive(target)
    }

    /// Re-align the mouse + software layers with the currently-active profile.
    ///
    /// Called on two triggers:
    ///  • Profile switch (SettingsStore.activeID change) — user picked a
    ///    different profile from the sidebar or tray menu.
    ///  • Hotplug into `.dongle` — the vendor protocol only works over the
    ///    2.4 GHz dongle, so a profile switch that happened while we were on
    ///    BT (or offline) couldn't push DPI/poll/idle/lighting. This is the
    ///    make-up call: push whatever the app-side profile says now that the
    ///    dongle is back.
    ///
    /// Software-side fields (buttons/scroll/status.settings/low-battery
    /// watcher) apply synchronously — they have no failure path and belong
    /// to the new profile immediately regardless of transport. Vendor writes
    /// go through the same debounced `autoApplyTask` slot the panel uses so
    /// a user tweak arriving right after (or during) a switch cleanly
    /// supersedes rather than races.
    private func applyActiveProfile(reason: String) {
        let new = SettingsStore.shared.current
        Log.info("applyActiveProfile: \(reason) → aligning software + hardware")

        // Cancel in-flight tasks tied to the previous profile — their target
        // settings are stale the moment activeID flipped.
        autoApplyTask?.cancel();     autoApplyTask = nil
        lightingRAMTask?.cancel();   lightingRAMTask = nil
        lightingFlashTask?.cancel(); lightingFlashTask = nil

        // OS-level features (event tap) — cheap, always safe, transport-agnostic.
        ButtonMap.shared.apply(new.buttons)
        ScrollTransformer.shared.settings = new.scroll
        ButtonMap.shared.scrollSettingsChanged()

        // status.settings drives idle-timeout, cycle-stage bounds, and the
        // low-battery watcher — flip it right away so those behaviors don't
        // lag the switch even if the HID push below is deferred by BT / a
        // sleeping mouse.
        status.settings = new

        // Low-battery latches are keyed to the previous profile's threshold.
        // Reset them so the new profile's threshold re-evaluates against the
        // current battery reading (e.g., switching from a 15% profile latched
        // at 12% to a 25% profile with battery at 20% should immediately
        // fire the new profile's alert / dim).
        lowBatteryLatched = false
        lastNotifiedBatteryPct = nil
        lastDimmedBrightness = nil
        if let pct = status.battery { checkLowBatteryEvent(pct) }

        // HID push. `apply()` is delta-based against `lastApplied` — when
        // hardware already matches the new profile (typical after a switch
        // between two profiles that happen to share DPI, or after a hotplug
        // where the mouse's onboard state was already the target), no HID
        // writes actually fire. Over BT, `apply()` commits software-side and
        // no-ops the vendor writes.
        autoApplyTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.apply(new)
            } catch is CancellationError {
                // Superseded by a newer switch or panel edit — the successor
                // task will do the push. Nothing to report.
            } catch {
                Log.warn("applyActiveProfile push failed: \(error)")
            }
        }
    }

    private func cycleStage(_ action: SensitivityAction) async {
        let s = status.settings
        let n = s.dpi.stages.count
        guard n > 0 else { return }
        let cur = min(max(1, s.dpi.activeStage), n)
        let next: Int
        switch action {
        case .nextStage:            next = cur == n ? 1 : cur + 1
        case .previousStage:        next = cur == 1 ? n : cur - 1
        case .specificStage(let i): next = min(max(1, i), n)
        }
        try? await setActiveStage(next)
    }

    /// User-initiated refresh. First read uses the full profile so a
    /// deeply-asleep mouse gets time to wake; if it fails, we bail out
    /// immediately (a mouse that couldn't wake in 5 s isn't going to
    /// answer any of the follow-up reads either, and grinding through
    /// 6 × 5 s of retries makes the button feel broken). Once the first
    /// read confirms the mouse is alive, subsequent reads use `.short`
    /// so the whole sequence completes in about a second, not 30.
    ///
    /// Deliberately bypasses the `probeInFlight` guard and the
    /// `syncedFromMouse` latch — the point of Refresh is to force a
    /// visible re-read regardless of what background probes have done.
    func refresh() async {
        // Bluetooth: no vendor protocol, but battery is available in the
        // IORegistry — refresh means "re-read whatever we can." Runs on the
        // main actor, cheap (a few IOKit calls), safe to call from the UI.
        if status.connection == .bluetooth {
            if let pct = BluetoothBattery.read() {
                // Same smoothing window as the dongle path — AA voltage
                // recovery is a property of the cell, not the transport.
                setSmoothedBattery(pct)
                status.error = nil
            }
            return
        }
        guard status.connection == .dongle else { return }
        do {
            // First read: use .full so a sleeping mouse has time to wake.
            // If this fails, treat the mouse as unreachable and bail —
            // don't spend 30 s on serial+battery+DPI+poll+idle when we
            // already know it's not answering.
            status.firmware = try await service.firmware(profile: .full).string
            // Confirmed alive — everything below uses .short.
            if status.serial == nil {
                status.serial = try? await service.serial(profile: .short)
            }
            let pct = try await service.batteryPercent(profile: .short)
            setSmoothedBattery(pct)
            lastBatteryReadAt = Date()
            status.error = nil
            markAlive()
        } catch let e as DeviceError {
            handleProbeError(e, profile: .full)
            // Bail — no point continuing to syncFromHardware if the mouse
            // is unreachable; that would just stack another ~15 s of
            // retries onto an already-frustrating no-op.
            return
        } catch {
            status.error = String(describing: error)
            Log.error("refresh error: \(error)")
            return
        }
        await syncFromHardware(profile: .short)
        lastStageReadAt = Date()
    }

    /// Called by `PanelController` on show/hide. Flips the pump between the
    /// foreground fast cadence (panel visible + dongle → 1.5 s so
    /// physical DPI-cycle button presses reflect live) and the background
    /// baseline (panel closed → 15 s keep-alive only). Idempotent —
    /// repeated calls with the same value are no-ops.
    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        Log.info("panel visibility: \(visible ? "visible (foreground fast-poll)" : "hidden (background)")")
        startPump()
    }

    /// Fast-path lighting write. Skips the full profile pipeline so tweaking
    /// color / effect / brightness lands on the mouse without also re-writing
    /// DPI, poll rate, and idle time (which can restart the LED's effect
    /// timer and make spectrum/wave visibly stutter).
    ///
    /// - Parameter commitToFlash: When `true` (default) writes go to onboard
    ///   flash so the state survives sleep / re-plug. When `false` writes
    ///   go to RAM only — the LED updates immediately but no onboard-memory
    ///   cell is touched. Use `false` for interactive drags (ColorPicker
    ///   thumb frames, brightness slider) to protect flash wear budget;
    ///   the caller schedules a single trailing `commitToFlash: true` call
    ///   after the user has settled on a value.
    func applyLighting(_ lighting: LightingSettings, commitToFlash: Bool = true) async throws {
        // Bluetooth: vendor commands don't reach the mouse. Commit to disk
        // only on the final flash commit — mid-drag RAM ticks stay
        // ephemeral so a paused-mid-drag user doesn't end up with a
        // random-intermediate color persisted to disk. The LED will pick
        // up the settled state on the next dongle write.
        guard status.connection == .dongle else {
            if commitToFlash {
                SettingsStore.shared.updateActive { $0.lighting = lighting }
                status.settings.lighting = lighting
            }
            return
        }

        if commitToFlash {
            // Only push what changed since the last flash commit. Sending
            // an identical effect frame restarts the mouse's effect timer,
            // so spectrum/wave stutter every time you drag the brightness
            // slider. Also folds RAM state back into flash: if a prior RAM
            // write already put this exact effect on the LED, the flash
            // write is still required (state must survive replug) but we
            // don't need to double-write brightness if it hasn't moved.
            let prev = lastApplied?.lighting
            if prev?.effect != lighting.effect {
                try await service.setLightingEffect(lighting.effect, storage: .onboard)
                lastApplied?.lighting.effect = lighting.effect
            }
            if prev?.brightness != lighting.brightness {
                try await service.setBrightnessPercent(lighting.brightness, storage: .onboard)
                lastApplied?.lighting.brightness = lighting.brightness
            }
            // RAM state is now consistent with flash — clear the cache so
            // any subsequent interactive drag can dedupe against a clean
            // baseline.
            lastRAMLighting = lighting
            // Publish to disk + status only on the flash commit — the
            // apply() invariant is that disk mirrors what's actually
            // persisted on the mouse.
            SettingsStore.shared.updateActive { $0.lighting = lighting }
            status.settings.lighting = lighting
        } else {
            // Interactive path — write to RAM only. Delta-check against the
            // last RAM state so a rapid ColorPicker drag that lands twice
            // on the same intermediate color doesn't hit the radio twice.
            let prev = lastRAMLighting ?? lastApplied?.lighting
            if prev?.effect != lighting.effect {
                try await service.setLightingEffect(lighting.effect, storage: .ram)
            }
            if prev?.brightness != lighting.brightness {
                try await service.setBrightnessPercent(lighting.brightness, storage: .ram)
            }
            lastRAMLighting = lighting
        }
        markAlive()
    }

    /// Instantly switch the active DPI stage on the mouse. Used when the user
    /// clicks a stage badge in the UI — no Apply required. Same disk-follows-
    /// hardware discipline as `apply()`: optimistic UI update, HID first,
    /// commit to disk only when the mouse confirms. If the write fails we
    /// roll the UI back to what actually landed.
    func setActiveStage(_ index: Int) async throws {
        let previous = status.settings
        guard previous.dpi.stages.indices.contains(index - 1) else { return }
        // Vendor protocol is dongle-only. Refuse over BT (or fully offline)
        // rather than firing a HID transaction that would throw `.notPresent`
        // and roll the UI back — the sidebar and tray menu already hide the
        // DPI controls in that case, so this is defence in depth for any
        // programmatic caller (e.g. a bound button action arriving over BT).
        guard status.connection == .dongle else { throw DeviceError.notPresent }
        let previousActive = previous.dpi.activeStage
        // Optimistic UI so the badge highlights instantly. Targeted write —
        // full-replace would clobber any concurrent lighting edit landing
        // via applyLighting's fast path.
        status.settings.dpi.activeStage = index
        do {
            try await service.setDPIStages(active: index, stages: previous.dpi.stages.map { ($0.x, $0.y) })
        } catch {
            // Hardware never changed — roll the UI back so the badge doesn't
            // lie about what the mouse is doing.
            status.settings.dpi.activeStage = previousActive
            throw error
        }
        SettingsStore.shared.updateActive { $0.dpi.activeStage = index }
        lastApplied?.dpi.activeStage = index
        // Push the reconcile TTL forward so the opportunistic hardware read
        // doesn't fire in the next 10 s and re-check something we just wrote.
        lastStageReadAt = Date()
        markAlive()
    }

    /// Apply settings to onboard memory. Writes are delta-based — each field
    /// is pushed only if it differs from what we last committed to the mouse.
    /// Matches Synapse's live-apply behavior: tweaking one setting should
    /// only touch that one HID register, not re-write the full profile.
    ///
    /// Disk persistence follows the mouse, not the UI: SettingsStore only
    /// takes on a field's new value after that field's HID write succeeded.
    /// This prevents the old bug where a failed write (mouse asleep, retry
    /// exhausted) left disk claiming values the hardware never received —
    /// on the next re-plug syncFromHardware would then "correct" disk back
    /// to the mouse's real state, silently discarding the user's edit.
    func apply(_ settings: AppSettings) async throws {
        // No optimistic top-set of status.settings: publishing the debounced
        // snapshot mid-drag lets .onReceive in MainView reset draft under
        // the user's finger and the slider snaps backward. status.settings
        // only advances on the success path with the actually-committed
        // value; on error it stays at whatever was last known-good.
        applyInFlight = true
        defer { applyInFlight = false }
        // Software-side features first — no HID to fail, safe to commit
        // immediately. They also work over Bluetooth (the tap is OS-level).
        ButtonMap.shared.apply(settings.buttons)
        ScrollTransformer.shared.settings = settings.scroll
        ButtonMap.shared.scrollSettingsChanged()

        // Vendor writes only reach the mouse via the dongle. Over BT (or
        // fully disconnected) commit the software-side fields to disk and
        // stop — no HID transactions will succeed and we shouldn't stage
        // partial "committed" state as if they had. Lighting is committed
        // via applyLighting's own path (which also works over BT for the
        // disk-persistence half of the write), so we skip it here to
        // avoid clobbering a concurrent lighting edit.
        guard status.connection == .dongle else {
            mergeNonLighting(from: settings)
            status.error = nil
            return
        }

        let prev = lastApplied
        let dpiChanged   = prev?.dpi != settings.dpi
        let pollChanged  = prev?.pollRateHz != settings.pollRateHz
        let idleChanged  = prev?.idleMinutes != settings.idleMinutes
        let lightChanged = prev?.lighting.effect != settings.lighting.effect
        let brightChanged = prev?.lighting.brightness != settings.lighting.brightness
        Log.info("apply Δ dpi=\(dpiChanged) poll=\(pollChanged) idle=\(idleChanged) light=\(lightChanged) bright=\(brightChanged)")

        // Start committed from `lastApplied` — our record of what's actually
        // on the mouse right now — not from disk. Disk can lag behind
        // hardware after a prior partial-failure that didn't get written.
        // Falling back to disk is only correct for the first apply after
        // syncFromHardware seeded it. Non-HID fields (buttons, scroll,
        // hotspot / callout overrides) merge in unconditionally — they have
        // no failure path to survive.
        var committed = lastApplied ?? SettingsStore.shared.current
        committed.buttons = settings.buttons
        committed.scroll = settings.scroll
        committed.hotspotOverrides = settings.hotspotOverrides
        committed.calloutOverrides = settings.calloutOverrides

        do {
            // Lighting first — LED effect timer restarts on each write, so
            // any restart happens before we serialize DPI/poll/idle.
            // Interactive lighting changes normally bypass this path entirely
            // via MainView.scheduleLightingApply → applyLighting.
            if lightChanged {
                try await service.setLightingEffect(settings.lighting.effect)
                committed.lighting.effect = settings.lighting.effect
            }
            if brightChanged {
                try await service.setBrightnessPercent(settings.lighting.brightness)
                committed.lighting.brightness = settings.lighting.brightness
            }
            if lightChanged || brightChanged { try await Task.sleep(nanoseconds: 200_000_000) }
            if dpiChanged {
                try await service.setDPIStages(active: settings.dpi.activeStage,
                                               stages: settings.dpi.stages.map { ($0.x, $0.y) })
                committed.dpi = settings.dpi
                // Push the reconcile TTL forward so an input-driven stage
                // read that queues behind us can't return the pre-write
                // stages and get written back to disk (dropping the user's
                // edit). The applyInFlight guard also covers this — belt
                // and suspenders.
                lastStageReadAt = Date()
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if pollChanged {
                try await service.setPollRate(settings.pollRateHz)
                committed.pollRateHz = settings.pollRateHz
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if idleChanged {
                try await service.setIdleMinutes(settings.idleMinutes)
                committed.idleMinutes = settings.idleMinutes
                // Verify — some Razer firmwares silently drop idle writes.
                if let readBack = try? await service.idleMinutes() {
                    status.idleActual = readBack
                }
            }
            // Targeted commit: only write the fields THIS apply is
            // responsible for. Lighting fields are written by applyLighting
            // via its own fast path — if the user made a lighting edit
            // during our HID-write suspension window, the fast path may
            // have already committed the fresh value. A full `$0 = committed`
            // would then clobber that fresh value with our (stale)
            // captured snapshot. Same reasoning for `status.settings`
            // and `lastApplied`.
            mergeNonLighting(from: committed)
            if lightChanged {
                SettingsStore.shared.updateActive { $0.lighting.effect = committed.lighting.effect }
                status.settings.lighting.effect = committed.lighting.effect
            }
            if brightChanged {
                SettingsStore.shared.updateActive { $0.lighting.brightness = committed.lighting.brightness }
                status.settings.lighting.brightness = committed.lighting.brightness
            }
            mergeLastApplied(from: committed,
                             lightChanged: lightChanged, brightChanged: brightChanged)
            status.error = nil
            markAlive()
        } catch is CancellationError {
            // Cancelled by a newer draft: the next scheduleAutoApply is
            // already queued with the fresh intent — don't flash a
            // "CancellationError()" in the footer while the user is
            // actively dragging. Still push partial progress into
            // lastApplied so the next apply's delta is correct.
            mergeLastApplied(from: committed,
                             lightChanged: lightChanged, brightChanged: brightChanged)
            throw CancellationError()
        } catch {
            // Do NOT overwrite `status.settings` or disk here. `lastApplied`
            // still tracks whatever partially reached the mouse so a retry
            // computes the correct delta; the successful partial fields on
            // hardware get re-persisted to disk on the next successful
            // apply (or on relaunch when syncFromHardware re-reads them).
            mergeLastApplied(from: committed,
                             lightChanged: lightChanged, brightChanged: brightChanged)
            status.error = String(describing: error)
            Log.error("apply failed at partial commit: \(error)")
            throw error
        }
        // Only re-probe when something actually shipped — otherwise the
        // battery-percent readout ticks needlessly and can wake the mouse.
        if dpiChanged || pollChanged || idleChanged || lightChanged || brightChanged {
            await probe(profile: .short)
        }
    }

    /// Merge every non-lighting field from `src` into disk + status.
    /// Used by `apply()` on success — keeping the field list in one place
    /// so a future new field doesn't get lost between two call sites.
    /// Lighting is written separately when the calling apply actually
    /// touched it; otherwise applyLighting's fast-path value on disk /
    /// status stays intact.
    private func mergeNonLighting(from src: AppSettings) {
        SettingsStore.shared.updateActive { s in
            s.dpi = src.dpi
            s.pollRateHz = src.pollRateHz
            s.idleMinutes = src.idleMinutes
            s.buttons = src.buttons
            s.scroll = src.scroll
            s.hotspotOverrides = src.hotspotOverrides
            s.calloutOverrides = src.calloutOverrides
            s.lowBattery = src.lowBattery
        }
        status.settings.dpi = src.dpi
        status.settings.pollRateHz = src.pollRateHz
        status.settings.idleMinutes = src.idleMinutes
        status.settings.buttons = src.buttons
        status.settings.scroll = src.scroll
        status.settings.hotspotOverrides = src.hotspotOverrides
        status.settings.calloutOverrides = src.calloutOverrides
        status.settings.lowBattery = src.lowBattery
    }

    /// Same targeted-merge discipline for `lastApplied`. On both the
    /// success and error paths we want `lastApplied` to reflect whatever
    /// this apply managed to ship, WITHOUT clobbering lighting fields
    /// that a concurrent `applyLighting` fast-path may have updated on
    /// `lastApplied` during our HID-write suspension window.
    private func mergeLastApplied(from src: AppSettings,
                                  lightChanged: Bool, brightChanged: Bool) {
        if lastApplied == nil {
            // First-time seed: nothing to preserve, take the whole snapshot.
            lastApplied = src
            return
        }
        lastApplied?.dpi = src.dpi
        lastApplied?.pollRateHz = src.pollRateHz
        lastApplied?.idleMinutes = src.idleMinutes
        lastApplied?.buttons = src.buttons
        lastApplied?.scroll = src.scroll
        lastApplied?.hotspotOverrides = src.hotspotOverrides
        lastApplied?.calloutOverrides = src.calloutOverrides
        lastApplied?.lowBattery = src.lowBattery
        if lightChanged { lastApplied?.lighting.effect = src.lighting.effect }
        if brightChanged { lastApplied?.lighting.brightness = src.lighting.brightness }
    }

    // MARK: - Wiring

    private func wireHotplug() {
        hotplug.onChange = { [weak self] kind in
            guard let self else { return }
            Log.info("hotplug → \(kind.rawValue)")
            self.status.connection = kind
            self.status.present = (kind != .none)
            switch kind {
            case .dongle:
                self.status.error = nil
                // Entering .dongle after a period of absence — cached
                // awake/battery from the previous transport (or previous
                // session before the mouse was toggled off) is untrustworthy.
                // Clear until the probe below confirms fresh state, so the
                // tray shows "Idle" instead of a stale "awake + last known
                // 87%" while the mouse might actually be powered off.
                self.status.awake = false
                self.status.battery = nil
                self.batterySmoother.reset()
                // Disk is authoritative once we've done the initial import.
                // Do NOT clear `syncedFromMouse` — that would let the next
                // probe silently overwrite the Mac profile with whatever the
                // mouse currently holds (which may be what Windows Synapse
                // last wrote, or a factory-reset default).
                // Clear `lastApplied` so the next user edit pushes every
                // field fresh, ensuring the mouse ends up matching disk even
                // if it drifted while unplugged. The user can also hit
                // Refresh explicitly to import hardware state on purpose.
                self.lastApplied = nil
                // Onboard RAM state resets when the mouse loses power to the
                // dongle radio, so a lastRAMLighting anchor from the previous
                // dongle session is stale. Drop it so the next mid-drag RAM
                // write actually reaches the wire instead of dedupe-skipping.
                self.lastRAMLighting = nil
                // Cancel any prior hotplug-probe Task before spawning a new
                // one — rapid dongle-cycling (VMware/Parallels claiming and
                // releasing the device) would otherwise queue multiple
                // sleeping Tasks and each would probe against whatever
                // state the controller has moved to by the time they wake.
                self.hotplugProbeTask?.cancel()
                self.hotplugProbeTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if Task.isCancelled { return }
                    await self?.probe(profile: .short)
                    if Task.isCancelled { return }
                    // Make-up push for any profile switch that happened while
                    // we were on BT / offline — vendor writes weren't reachable
                    // then, so hardware is stuck on the previous profile's
                    // onboard values. apply() is delta-based against
                    // lastApplied (cleared above), so first-plug scenarios where
                    // syncFromHardware just imported hw into the active profile
                    // become an all-zero-diff noop.
                    self?.applyActiveProfile(reason: "hotplug → dongle")
                }
                // Pump cadence depends on connection + panelVisible — the
                // .dongle switch may promote us from background (15 s) to
                // foreground (1.5 s) if the panel is open.
                self.startPump()
            case .bluetooth:
                // Firmware / serial come from Razer's vendor protocol and
                // aren't reachable over BT — clear them. Battery *is*
                // reachable: macOS exposes it in the IORegistry (populated
                // from the device's HID battery report / GATT Battery
                // Service), so we start a periodic reader below.
                self.status.firmware = nil
                self.status.serial = nil
                self.status.error = nil
                self.autoApplyTask?.cancel()
                self.autoApplyTask = nil
                self.lightingRAMTask?.cancel(); self.lightingRAMTask = nil
                self.lightingFlashTask?.cancel(); self.lightingFlashTask = nil
                self.hotplugProbeTask?.cancel()
                self.hotplugProbeTask = nil
                // Don't reset battery smoothing — the same window still
                // makes sense over BT (AA voltage recovery is a property
                // of the cell, not the transport).
                // Immediate first read: pump handles the recurring 30 s
                // cadence, but the user shouldn't have to wait a full
                // interval to see the pill light up on hotplug.
                self.pollBluetoothBattery()
                self.lastBTBatteryPollAt = Date()
                // Kick GATT to (re)discover the peripheral — subscription
                // survives most session transitions but a paired-off/on
                // toggle can drop it, so a refresh on every BT entry is
                // the belt-and-suspenders play.
                self.gattBattery.refresh()
                // BT → 15 s background pump. Also cancels any leftover
                // sleep from the previous transport.
                self.startPump()
            case .none:
                self.status.awake = false
                self.status.battery = nil
                self.status.firmware = nil
                self.status.serial = nil
                self.status.error = "Mouse disconnected"
                // Cancel any pending debounced write — the mouse is gone.
                self.autoApplyTask?.cancel()
                self.autoApplyTask = nil
                self.lightingRAMTask?.cancel(); self.lightingRAMTask = nil
                self.lightingFlashTask?.cancel(); self.lightingFlashTask = nil
                self.hotplugProbeTask?.cancel()
                self.hotplugProbeTask = nil
                self.awakeDecayTask?.cancel()
                self.awakeDecayTask = nil
                // Reset battery smoothing window AND the anchor so a
                // replaced battery reads fresh instead of being clamped to
                // the previous minimum + upward-step cap.
                self.batterySmoother.reset()
                // Mouse is unreachable — cached RAM anchor is meaningless.
                self.lastRAMLighting = nil
                // Pump keeps running (it self-idles when connection == .none)
                // but a restart flushes any in-flight sleep so it takes the
                // background cadence immediately.
                self.startPump()
            }
        }
    }

    private func wireInput() {
        input.onActivity = { [weak self] in
            guard let self else { return }
            let waking = self.markAlive()
            switch self.status.connection {
            case .dongle:
                // Wake transition (asleep → awake) — mouse's radio has just
                // come back. Fire a `.full` probe so the retry ceiling
                // covers the wake-up window; a `.short` probe times out
                // during transition and the caller then wrongly flips
                // `awake=false`, which drove the "tray icon flickers on
                // wake and battery never updates" bug.
                if waking {
                    Task { await self.probe(profile: .full) }
                    return
                }
                let now = Date()
                // Steady-state background refresh — only when battery is
                // stale AND we're not still recovering from a recent probe
                // failure (avoid stacking retries onto a busy HID stack
                // while the user is actively using the mouse).
                if now.timeIntervalSince(self.lastBatteryReadAt) > self.batteryTTL
                   && now.timeIntervalSince(self.lastProbeFailedAt) > self.probeFailureCooldown {
                    Task { await self.probe(profile: .short) }
                }
                // Pick up hardware-initiated DPI changes (physical DPI
                // cycle button on the mouse) without needing the user to
                // hit Refresh. Throttled — one read every stageReadTTL of
                // active use.
                if now.timeIntervalSince(self.lastStageReadAt) > self.stageReadTTL {
                    Task { await self.reconcileActiveStage() }
                }
            case .bluetooth:
                // BT: no vendor protocol, but a fresh IORegistry read on
                // wake reflects the current AA level much faster than
                // waiting for the 30 s periodic loop.
                if waking {
                    self.pollBluetoothBattery()
                    // Also re-attempt GATT discovery — the initial
                    // hotplug-time refresh might have missed the
                    // peripheral if it was still asleep at that moment.
                    self.gattBattery.refresh()
                }
            case .none:
                break
            }
        }
    }

    /// Wake / sleep hook. When the Mac sleeps, the mouse's radio may
    /// nap or the user may physically turn it off — either way, any
    /// cached `awake=true` / battery reading is untrustworthy on wake.
    /// On wake we flip awake=false + clear the battery pill so the tray
    /// tells the truth ("Idle") until the next probe / GATT reading
    /// actually confirms the mouse is answering. Also drops obsolete
    /// in-flight tasks so we don't hammer the mouse the instant we wake.
    private func wireSleepWake() {
        // Notification queue is `.main`, so these blocks run on the main
        // thread — but Swift concurrency can't infer that from an
        // OperationQueue reference, so we hop through a MainActor Task
        // explicitly to satisfy isolation.
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                Log.info("workspace willSleep — cancelling in-flight tasks")
                self.autoApplyTask?.cancel();      self.autoApplyTask = nil
                self.lightingRAMTask?.cancel();    self.lightingRAMTask = nil
                self.lightingFlashTask?.cancel();  self.lightingFlashTask = nil
                // Pump would otherwise sit inside its sleep the whole time
                // the Mac naps and then fire immediately on wake against
                // stale state — didWake restarts it explicitly.
                self.stopPump()
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                Log.info("workspace didWake — invalidating cached awake/battery, re-probing")
                // Cached truth is stale — mouse could have been powered
                // off during sleep, dongle radio state is unknown. Clear
                // until fresh data lands.
                self.status.awake = false
                self.status.battery = nil
                self.batterySmoother.clearSamplesPreservingAnchor()
                self.lastActivity = .distantPast
                self.lastBatteryReadAt = .distantPast
                switch self.status.connection {
                case .dongle:    Task { await self.probe(profile: .short) }
                case .bluetooth:
                    self.pollBluetoothBattery()
                    self.lastBTBatteryPollAt = Date()
                    self.gattBattery.refresh()
                case .none:      break
                }
                // Pump was stopped on willSleep — restart with the
                // post-wake cadence for the current transport / panel state.
                self.startPump()
            }
        }
    }

    /// Read the mouse's current active DPI stage and, if it differs from
    /// what we have in `status.settings`, reconcile. Called opportunistically
    /// from input-activity — silent on error since this is a convenience
    /// path, not a critical read.
    private func reconcileActiveStage() async {
        guard status.connection == .dongle, !applyInFlight, !reconcileInFlight else { return }
        reconcileInFlight = true
        // Advance the timestamp up-front so the foreground/input paths gate
        // on when we STARTED, not when we finished — a slow mouse would
        // otherwise let a queue-of-one form during the 500 ms+ read.
        lastStageReadAt = Date()
        defer { reconcileInFlight = false }
        // Snapshot the intended stage BEFORE we suspend. Between our read
        // enqueuing and returning, the user may have clicked a stage badge
        // — that write goes on the same Device queue behind us, so our
        // read returns the pre-click hardware value. If we then wrote it
        // back to disk we'd undo the user's click within a fraction of a
        // second. Only apply the reconcile if `activeStage` is unchanged
        // since the snapshot; otherwise the user (or apply()) is the
        // source of truth and reconcile is stale by definition.
        let intendedActive = status.settings.dpi.activeStage
        do {
            let hw = try await service.dpiStages(profile: .short)
            lastStageReadAt = Date()
            guard !hw.stages.isEmpty else { return }
            guard status.settings.dpi.activeStage == intendedActive else {
                Log.info("reconcile: skipping stale read (user changed stage while awaiting)")
                return
            }
            let active = max(1, hw.active)
            if intendedActive != active {
                Log.info("mouse-initiated DPI cycle → stage \(active)")
                var s = status.settings
                s.dpi.activeStage = active
                SettingsStore.shared.updateActive { $0 = s }
                status.settings = s
            }
        } catch {
            // Silent — regular probes will surface real errors. lastStageReadAt
            // was already advanced pre-await so a failing read still delays
            // the next attempt by stageReadTTL / foregroundReconcileInterval.
        }
    }

    // ─── Unified periodic pump ───────────────────────────────────────
    //
    // Single Task that replaces the old pollTimer (15 s dongle keepalive),
    // btBatteryTask (30 s BT battery loop), foregroundReconcileTask
    // (1.5 s panel-visible stage reconcile), and GATTBattery.refreshTimer
    // (120 s explicit BLE battery re-read). Cadence is picked from
    // `pumpInterval` — 1.5 s while the panel is open on the dongle,
    // 15 s otherwise (BT, disconnected, or panel closed).
    //
    // Each tick dispatches based on connection + per-work-item TTL. This
    // means most ticks are no-ops (matching the aggregate of what the old
    // separate timers used to do): a foreground tick fires stage-reconcile
    // every 1.5 s but only fires the dongle keepalive once every 10 ticks.

    /// Chosen cadence for the current state. Panel-visible + dongle is the
    /// only path that benefits from the fast cadence — BT with the panel
    /// open would just wake the CPU every 1.5 s to no-op on stage reconcile
    /// (BT has no vendor protocol) so we keep it at background too.
    private var pumpInterval: TimeInterval {
        (panelVisible && status.connection == .dongle)
            ? pumpForegroundInterval
            : pumpBackgroundInterval
    }

    private func startPump() {
        pumpTask?.cancel()
        pumpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.pumpTick()
                let ns = UInt64(self.pumpInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    private func stopPump() {
        pumpTask?.cancel()
        pumpTask = nil
    }

    /// One pump tick. Cheap and mostly no-op — the TTL guards inside each
    /// branch match what the old separate timers enforced.
    private func pumpTick() {
        let now = Date()
        switch status.connection {
        case .dongle:
            // Fast-cadence path: reconcile the active DPI stage while the
            // panel is open, so the physical DPI-cycle button on the mouse
            // reflects in the stage badges within a beat. reconcileActiveStage
            // stamps `lastStageReadAt` at the *start* of the read so a slow
            // HID answer doesn't queue a second read on top.
            if panelVisible && !applyInFlight && !reconcileInFlight
               && now.timeIntervalSince(lastStageReadAt) >= stageReconcileTTL {
                Task { await self.reconcileActiveStage() }
            }
            // Background keep-alive probe. Skips while the mouse is being
            // actively used (IOHID input keeps state fresh) and once we
            // already know the mouse is asleep (probing would just wake the
            // radio for no gain — IOHID wakes us on the user's next input).
            // Catches switch-off / out-of-range, both silent from IOHID's
            // side; without this the UI would stay stale until the idle
            // decay fires.
            if status.awake
               && now.timeIntervalSince(lastActivity) >= dongleKeepaliveTTL
               && now.timeIntervalSince(lastDonglePollAt) >= dongleKeepaliveTTL {
                lastDonglePollAt = now
                Task { await self.probe(profile: .short) }
            }
        case .bluetooth:
            // macOS updates the parsed HID battery property asynchronously
            // (typically every couple of minutes), so we sample at
            // `btBatteryPollTTL` to stay reasonably fresh without waking
            // the radio. GATT push takes over when it can — poking GATT
            // here is only for cases where a paired-off/on toggle dropped
            // the subscription.
            if now.timeIntervalSince(lastBTBatteryPollAt) >= btBatteryPollTTL {
                lastBTBatteryPollAt = now
                pollBluetoothBattery()
                if status.battery == nil { gattBattery.refresh() }
            }
            // GATT safety-net re-read (was a standalone 120 s Timer in
            // GATTBattery; folded here so all periodic tasks live in one
            // place). No-op if no peripheral is connected — the previous
            // branch handles reconnection.
            if now.timeIntervalSince(lastGATTReadAt) >= gattRereadTTL {
                lastGATTReadAt = now
                gattBattery.rereadBatteryLevel()
            }
        case .none:
            break                              // pump idles at the background cadence
        }
    }

    /// Fires once, `awakeTimeout` seconds after the most recent markAlive().
    /// Cancelled and re-armed on every markAlive() so a continuously-active
    /// mouse never trips the sleep transition. Replaces the old 1s repeating
    /// timer so the main thread can idle out under App Nap.
    ///
    /// If the idle-timer setting changes between arm and fire (e.g. user
    /// bumps idleMinutes from 3 to 10), the sleep-check uses the *new*
    /// awakeTimeout — a check that would previously exit without
    /// rescheduling and leave the tray stuck "Connected" until the next
    /// input event. The reschedule branch below covers that.
    private func armAwakeDecay() {
        awakeDecayTask?.cancel()
        let timeoutNs = UInt64(awakeTimeout * 1_000_000_000)
        awakeDecayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNs)
            guard let self, !Task.isCancelled else { return }
            // Runs for both dongle and Bluetooth — InputActivity fires on
            // both transports, so both drive awake/asleep semantics.
            guard self.status.present, self.status.awake else { return }
            if Date().timeIntervalSince(self.lastActivity) >= self.awakeTimeout {
                self.status.awake = false
            } else {
                // Not yet at the (possibly newly-longer) timeout — reschedule
                // ourselves. Cheap and self-healing.
                self.armAwakeDecay()
            }
        }
    }

    // MARK: - Probe

    /// Returns `true` when this call flipped `awake` from false → true (the
    /// mouse just woke). Callers use that to schedule a full-profile probe
    /// once per wake so battery / DPI actually get read before the mouse
    /// slips back into radio sleep. Steady-state activity returns `false`.
    @discardableResult
    private func markAlive() -> Bool {
        lastActivity = Date()
        let waking = !status.awake
        if waking { status.awake = true }
        armAwakeDecay()
        return waking
    }

    /// Whether we've already synced settings.json from the mouse this session.
    /// After the first successful sync, the user's edits in the UI become the
    /// source of truth (until Apply writes them back and we re-sync).
    private var syncedFromMouse = false

    // MARK: - Bluetooth battery

    private func pollBluetoothBattery() {
        guard status.connection == .bluetooth else { return }
        // While the BT device stays enumerated by macOS, the pairing is
        // active and the OS believes the mouse is reachable. Treat every
        // poll tick as a wake signal regardless of whether we successfully
        // pulled a battery number — otherwise the tray drifts to the
        // sleep icon whenever the battery property is momentarily missing
        // (right after pair, quiet browsing sessions with no clicks, etc)
        // even though the mouse itself is fine. Hotplug's `.none`
        // transition is what actually flips awake off when the mouse
        // truly disconnects.
        markAlive()
        if let pct = BluetoothBattery.read() {
            setSmoothedBattery(pct)
        }
    }

    private func probe(profile requestedProfile: RetryProfile) async {
        guard status.connection == .dongle, !probeInFlight else {
            // Suppress the log during a stream of skips — a busy period
            // (input activity + slow HID answer) can otherwise print
            // "probe: skip" many times a second and drown the log. Only
            // log the first skip in a burst.
            if !probeSkipLogged {
                probeSkipLogged = true
                Log.info("probe: skip (conn=\(status.connection.rawValue) inFlight=\(probeInFlight))")
            }
            return
        }
        probeSkipLogged = false
        probeInFlight = true
        defer { probeInFlight = false }
        // Cold-start override: when nothing has been read from the mouse
        // yet (fresh launch, fresh dongle-plug) the mouse's radio is
        // often napping. Short profile (6 × 120 ms = 720 ms) doesn't
        // outlast a nap, so battery reads silently timed out every
        // launch. Escalate to .full (~5 s ceiling) on the very first
        // read so we ride out the nap and populate the UI.
        let profile: RetryProfile = (status.firmware == nil) ? .full : requestedProfile
        Log.info("probe: begin (profile=\(profile.attempts) attempts, requested=\(requestedProfile.attempts))")
        do {
            if status.firmware == nil {
                let fw = try await service.firmware(profile: profile).string
                status.firmware = fw
                Log.info("probe: firmware=\(fw)")
            }
            if status.serial == nil {
                status.serial = try? await service.serial(profile: profile)
                Log.info("probe: serial=\(status.serial ?? "?")")
            }
            if Date().timeIntervalSince(lastBatteryReadAt) > batteryTTL || status.battery == nil {
                let pct = try await service.batteryPercent(profile: profile)
                Log.info("probe: batteryPercent raw=\(pct)")
                setSmoothedBattery(pct)
                lastBatteryReadAt = Date()
            }
            // First successful probe: pull the mouse's actual onboard state
            // into the UI so users see their real settings, not our defaults.
            if !syncedFromMouse {
                await syncFromHardware(profile: profile)
                syncedFromMouse = true
            }
            status.error = nil
            // Cooldown resets on any successful probe — the mouse is
            // reachable, so we don't need to space out follow-up requests.
            lastProbeFailedAt = .distantPast
            markAlive()
            Log.info("probe: done (battery=\(status.battery.map { "\($0)%" } ?? "nil"))")
        } catch let e as DeviceError {
            handleProbeError(e, profile: profile)
        } catch {
            status.error = String(describing: error)
            lastProbeFailedAt = Date()
            Log.error("probe error: \(error)")
        }
    }

    /// Read hardware state (DPI stages, poll rate, idle time) and overwrite
    /// the persisted settings so the UI reflects what's on the mouse rather
    /// than whatever the JSON defaults were.
    ///
    /// **Never runs while a user edit is pending or in-flight** — otherwise
    /// the hardware reads (which take a couple hundred ms) return values
    /// that predate the user's edit, and we silently revert the edit right
    /// after the apply lands. The old code did exactly that: user drags
    /// slider → apply(new) queues → first probe finishes → syncFromHardware
    /// reads OLD value from mouse → writes OLD back to disk. Phantom
    /// snap-back on first launch after cold plug.
    private func syncFromHardware(profile: RetryProfile) async {
        // Any pending or in-flight user edit blocks the sync — pick it up
        // on the next probe once the user has settled.
        guard autoApplyTask == nil, !applyInFlight else {
            Log.info("syncFromHardware: skipping — user edit in flight")
            return
        }
        do {
            let hwStages = try await service.dpiStages(profile: profile)
            let hwPoll   = try await service.pollRate(profile: profile)
            let hwIdle   = try? await service.idleMinutes(profile: profile)

            // Second guard *after* the reads: the user may have started
            // editing while we were awaiting hardware. Committing now
            // would still land right on top of that edit.
            guard autoApplyTask == nil, !applyInFlight else {
                Log.info("syncFromHardware: skipping commit — user began editing during read")
                return
            }

            // Only overlay the specific fields we actually read, using an
            // atomic updateActive block. Everything else on disk survives
            // untouched — if any other field was mutated during the read
            // window (e.g. profile switch), we don't clobber it.
            let previousIdle = SettingsStore.shared.current.idleMinutes
            var newIdle = previousIdle
            SettingsStore.shared.updateActive { s in
                if !hwStages.stages.isEmpty {
                    s.dpi = DPIConfig(
                        activeStage: max(1, min(hwStages.stages.count, hwStages.active)),
                        stages: hwStages.stages.map { DPIStageValue(x: $0.x, y: $0.y) }
                    )
                }
                s.pollRateHz = hwPoll
                if let idle = hwIdle {
                    s.idleMinutes = idle
                    newIdle = idle
                }
            }
            if let idle = hwIdle { status.idleActual = idle }
            status.settings = SettingsStore.shared.current
            // `awakeTimeout` is derived from `idleMinutes`. If it just
            // changed and we already have a decay task in flight, re-arm
            // it so it uses the new window — otherwise a task scheduled
            // against the old (smaller) timeout can fire, decide it's
            // still within the new (larger) window, and exit without
            // rescheduling, leaving the tray stuck in "Connected" state
            // until the next input event.
            if newIdle != previousIdle && status.awake {
                armAwakeDecay()
            }
            let s = status.settings
            Log.info("synced settings from mouse: active=\(s.dpi.activeStage) count=\(s.dpi.stages.count) poll=\(s.pollRateHz)Hz idle=\(s.idleMinutes)m")
        } catch {
            Log.warn("syncFromHardware failed: \(error)")
        }
    }

    /// Battery smoothing lives in its own struct so the AA-voltage /
    /// swap-jump / upward-step-cap logic can be exercised in unit
    /// tests without spinning up the whole HID stack. See
    /// `BatterySmoother` for the rule set.
    private var batterySmoother = BatterySmoother()
    private func smoothBattery(_ pct: Int) -> Int {
        batterySmoother.smooth(pct)
    }

    // ─── Low-battery watcher ─────────────────────────────────────────
    //
    // Latch so the notification only fires once per drain cycle. Cleared
    // when smoothed battery climbs back above `threshold + hysteresis` —
    // that band prevents a smoothed reading oscillating around the
    // boundary from firing the notification on every dip. `swapDetected`
    // inside `smoothBattery` handles the AA-replacement case: the samples
    // buffer flushes, the display jumps, and the watcher naturally clears
    // its latch on the next high reading.
    private var lowBatteryLatched = false
    /// Percentage at which the most recent low-battery notification
    /// fired. We only re-notify on genuine drops (`pct < lastNotified`)
    /// so a smoothed reading that hovers near the threshold doesn't
    /// spam Notification Center, but a real 20% → 15% → 10% slide
    /// posts three banners.
    private var lastNotifiedBatteryPct: Int? = nil
    /// Cached last brightness written to the mouse RAM while dimming. Lets
    /// us skip a redundant HID write when the user's committed brightness
    /// has already been dimmed (or when nothing about the dim state has
    /// changed) — matters because pollBluetoothBattery + probe fire this
    /// path every 30-45 s.
    private var lastDimmedBrightness: Int? = nil
    private let lowBatteryHysteresis: Int = 10

    /// Batched smooth + threshold check. Every caller that would have
    /// written `status.battery = smoothBattery(pct)` routes through here
    /// so the alert / auto-dim behaviour rides on one code path.
    private func setSmoothedBattery(_ raw: Int) {
        let display = smoothBattery(raw)
        if status.battery != display {
            Log.info("battery: \(status.battery.map { "\($0)%" } ?? "nil") → \(display)% (raw=\(raw)%)")
            status.battery = display
        }
        checkLowBatteryEvent(display)
    }

    private func checkLowBatteryEvent(_ pct: Int) {
        let cfg = status.settings.lowBattery
        let threshold = max(1, min(100, cfg.threshold))
        let clearAt = min(100, threshold + lowBatteryHysteresis)
        if pct <= threshold {
            // Fire on the initial crossing, then again on every further
            // drop below the last-notified level. Hysteresis / recovery
            // still lives on `lowBatteryLatched` so LED dim fires once
            // and clears once — only the notification cadence changed.
            let firstCross = !lowBatteryLatched
            let dropped   = lastNotifiedBatteryPct.map { pct < $0 } ?? true
            if cfg.alertEnabled && (firstCross || dropped) {
                postLowBatteryNotification(pct)
                lastNotifiedBatteryPct = pct
            }
            if firstCross {
                lowBatteryLatched = true
                if cfg.dimLEDEnabled { Task { await self.applyLowBatteryDim() } }
                Log.info("low-battery threshold crossed at \(pct)% (threshold=\(threshold))")
            } else if dropped {
                Log.info("low-battery further drop at \(pct)% — re-notified")
            }
        } else if lowBatteryLatched && pct >= clearAt {
            lowBatteryLatched = false
            lastNotifiedBatteryPct = nil
            lastDimmedBrightness = nil
            if cfg.dimLEDEnabled { Task { await self.restoreLightingAfterLowBattery() } }
            Log.info("low-battery cleared at \(pct)% (clear=\(clearAt))")
        }
    }

    /// Cut brightness in half via a RAM write — no flash, safe on repeat.
    /// If lighting is already off, do nothing (halving 0 is still 0).
    private func applyLowBatteryDim() async {
        guard status.connection == .dongle else { return }
        let target = max(0, status.settings.lighting.brightness / 2)
        if lastDimmedBrightness == target { return }
        do {
            try await service.setBrightnessPercent(target, storage: .ram)
            lastDimmedBrightness = target
            Log.info("low-battery: dimmed LED to \(target)% (RAM)")
        } catch {
            Log.warn("low-battery: dim write failed: \(error)")
        }
    }

    /// Restore LED to the user's committed brightness. RAM write so we
    /// don't spam flash — the value already lives on the mouse's onboard
    /// state; this just repaints the RAM copy.
    private func restoreLightingAfterLowBattery() async {
        guard status.connection == .dongle else { return }
        let target = status.settings.lighting.brightness
        do {
            try await service.setBrightnessPercent(target, storage: .ram)
            Log.info("low-battery cleared: restored LED to \(target)% (RAM)")
        } catch {
            Log.warn("low-battery: restore write failed: \(error)")
        }
    }

    /// Ask for Notifications permission at launch. Ad-hoc / self-signed
    /// bundles can silently fail the lazy path (macOS refuses to prompt
    /// for a bundle it doesn't recognize), and the user is then stuck
    /// wondering why they never got asked. Doing it eagerly at launch
    /// forces the outcome — grant, deny, or silent-fail — into the log
    /// on the very first run so it can be diagnosed.
    private func requestNotificationAuthorizationOnLaunch() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            Log.info("notifications: current status = \(Self.authName(settings.authorizationStatus))")
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, err in
                    if let err {
                        Log.warn("notifications: requestAuthorization error: \(err)")
                    }
                    Log.info("notifications: requestAuthorization → granted=\(granted)")
                }
            case .denied:
                Log.info("notifications: user has declined — low-battery banners will be suppressed. Enable in System Settings → Notifications → BSK V3 X HS.")
            case .authorized, .provisional, .ephemeral:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated private static func authName(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        case .provisional:   return "provisional"
        case .ephemeral:     return "ephemeral"
        @unknown default:    return "?"
        }
    }

    private func postLowBatteryNotification(_ pct: Int) {
        let center = UNUserNotificationCenter.current()
        // Auth is normally requested on launch (see
        // requestNotificationAuthorizationOnLaunch). Re-check here in
        // case the user changed the toggle in System Settings after
        // launch, or the launch-time request was still notDetermined
        // by the time the first low-battery event fired.
        center.getNotificationSettings { settings in
            let content = UNMutableNotificationContent()
            content.title = String(localized: "BSK V3 X HS")
            // Format string with %% escape so the literal % lands as-is
            // in the rendered body regardless of locale.
            let bodyFormat = NSLocalizedString(
                "Battery at %lld%% — replace the AA soon.",
                comment: "low-battery notification body"
            )
            content.body = String(format: bodyFormat, pct)
            content.sound = .default
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                let req = UNNotificationRequest(
                    identifier: "bskv3xhs.lowBattery",
                    content: content, trigger: nil
                )
                center.add(req) { err in
                    if let err { Log.warn("low-battery notification add failed: \(err)") }
                }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, err in
                    if let err { Log.warn("notification auth error: \(err)") }
                    guard granted else { return }
                    let req = UNNotificationRequest(
                        identifier: "bskv3xhs.lowBattery",
                        content: content, trigger: nil
                    )
                    center.add(req) { err in
                        if let err { Log.warn("low-battery notification add failed: \(err)") }
                    }
                }
            case .denied:
                Log.info("low-battery notification suppressed — user has declined Notifications for this app")
            @unknown default:
                break
            }
        }
    }

    private func handleProbeError(_ e: DeviceError, profile: RetryProfile) {
        lastProbeFailedAt = Date()
        // Fresh input activity is authoritative — the mouse is definitely
        // alive if events are landing right now. Feature-report timeouts
        // during that window are radio contention, not a sleep signal.
        let recentInput = Date().timeIntervalSince(lastActivity) < recentInputGrace
        switch e {
        case .noResponse:
            // Short-profile probe with no recent input → mouse is asleep;
            // reflect immediately so the tray shows Idle without waiting
            // for the decay timer. With recent input we hold the awake
            // signal; this is the fix for the "tray icon flickers on
            // wake and battery never updates" bug.
            if !recentInput { status.awake = false }
            // Only surface no-response errors from user-initiated full
            // profiles — background short probes hitting the noResponse
            // ceiling are normal. Never overwrite a *real* pre-existing
            // error (permission revoke, I/O fault): only clear the field
            // when what's there looks like a stale sleep hint.
            if profile.attempts > RetryProfile.short.attempts && !recentInput {
                status.error = String(describing: e)
            } else if let existing = status.error,
                      existing.contains("asleep") || existing.contains("unreachable") {
                status.error = nil
            }
            // Log even though it's expected during radio nap — silence
            // here was what made "battery reads went dark" invisible
            // in prior debugging rounds.
            Log.info("probe: noResponse (recentInput=\(recentInput) attempts=\(profile.attempts) awake=\(status.awake))")
        case .notPermitted:
            status.error = String(describing: e)
            Log.warn("probe: \(e)")
        default:
            status.error = String(describing: e)
            if !recentInput { status.awake = false }
            Log.warn("probe: \(e)")
        }
    }
}
