import SwiftUI

// Sensitivity list — one row per DPI stage, styled like a macOS System
// Settings pane. Radio picks the active stage; the slider + numeric
// readout edit DPI. Value is buffered while the slider is being
// scrubbed and only commits on drag-end, so the mouse's real DPI can't
// change mid-scrub (which reads as 突然快突然慢 on the pointer).

struct DPIStagesList: View {
    @Binding var dpi: DPIConfig
    var body: some View {
        VStack(spacing: 0) {
            ForEach(dpi.stages.indices, id: \.self) { idx in
                DPIStageRow(idx: idx, dpi: $dpi)
                if idx < dpi.stages.count - 1 {
                    Divider().opacity(0.4)
                }
            }
        }
    }
}

private struct DPIStageRow: View {
    let idx: Int
    @Binding var dpi: DPIConfig
    @EnvironmentObject var controller: DeviceController
    @State private var xScrub: Int? = nil
    @State private var yScrub: Int? = nil

    private var isActive: Bool { idx + 1 == dpi.activeStage }
    private var canRemove: Bool { dpi.stages.count > 1 }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: activate) {
                HStack(spacing: 8) {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                        .font(.system(size: 15))
                    Text("Stage \(idx + 1)")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                }
            }
            .buttonStyle(.plain)
            .frame(width: 92, alignment: .leading)

            // Bindings route through safeBinding/syncedBinding so a
            // stale idx from a removed row's still-mounted view can't
            // trap on out-of-range subscript. See
            // [[feedback-swiftui-idx-binding-crash]].
            if dpi.xyIndependent {
                VStack(spacing: 6) {
                    DPIAxisEditor(label: "X",
                                  value: safeBinding(\.x),
                                  scrub: $xScrub)
                    DPIAxisEditor(label: "Y",
                                  value: safeBinding(\.y),
                                  scrub: $yScrub)
                }
            } else {
                DPIAxisEditor(label: nil,
                              value: syncedBinding(),
                              scrub: $xScrub)
            }

            Button(action: removeSelf) {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(Color.secondary.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .opacity(canRemove ? 1 : 0.35)
            .help("Remove this stage")
        }
        .padding(.vertical, 6)
    }

    private func activate() {
        dpi.activeStage = idx + 1
        Task { try? await controller.setActiveStage(idx + 1) }
    }
    private func removeSelf() {
        // Defer to the next runloop tick — mutating `dpi.stages` inside
        // the Button's action while SwiftUI is still holding view state
        // for the current row is what triggered the crash. By the time
        // the async block fires SwiftUI has settled and the ForEach can
        // unmount cleanly.
        let target = idx
        DispatchQueue.main.async {
            guard dpi.stages.count > 1,
                  dpi.stages.indices.contains(target) else { return }
            dpi.stages.remove(at: target)
            if dpi.activeStage > dpi.stages.count {
                dpi.activeStage = dpi.stages.count
            }
        }
    }
    /// Bounds-safe sub-binding for one axis (`\.x` or `\.y`).
    private func safeBinding(_ axis: WritableKeyPath<DPIStageValue, Int>) -> Binding<Int> {
        Binding(
            get: { dpi.stages.indices.contains(idx) ? dpi.stages[idx][keyPath: axis] : 0 },
            set: { new in
                guard dpi.stages.indices.contains(idx) else { return }
                dpi.stages[idx][keyPath: axis] = new
            }
        )
    }
    /// Bounds-safe binding that mirrors writes onto both axes (used
    /// when X-Y independent is off).
    private func syncedBinding() -> Binding<Int> {
        Binding(
            get: { dpi.stages.indices.contains(idx) ? dpi.stages[idx].x : 0 },
            set: { new in
                guard dpi.stages.indices.contains(idx) else { return }
                dpi.stages[idx].x = new
                dpi.stages[idx].y = new
            }
        )
    }
}

// Numeric readout + native Slider. `scrub` holds the mid-drag value so
// `value` (which propagates to the HID apply pipeline) only writes on
// drag end.
private struct DPIAxisEditor: View {
    let label: String?
    @Binding var value: Int
    @Binding var scrub: Int?
    private var displayed: Int { scrub ?? value }
    var body: some View {
        HStack(spacing: 10) {
            if let label {
                Text(LocalizedStringKey(label))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            Text(displayed.formatted())
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            // No `step:` on the Slider — that parameter makes SwiftUI
            // draw a tick mark for every step across the range (358 of
            // them at step:50 in [100, 18000]), which renders as a
            // dashed second line under the track. We snap to the
            // nearest 50 inside the setter instead; scrubbing stays
            // continuous, and the track matches System Settings' look.
            Slider(
                value: Binding<Double>(
                    get: { Double(displayed) },
                    set: { new in
                        let snapped = Int((new / 50).rounded()) * 50
                        scrub = min(max(snapped, 100), 18000)
                    }
                ),
                in: 100...18000,
                onEditingChanged: { editing in
                    if !editing, let s = scrub {
                        value = s
                        scrub = nil
                    }
                }
            )
        }
    }
}
