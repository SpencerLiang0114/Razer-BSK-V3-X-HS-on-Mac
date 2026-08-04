import SwiftUI

// ─── Slider commit coordinator ──────────────────────────────────────
//
// Sliders normally fire `onChange(of: draft)` on every scrubbed value,
// which the debounce path then commits ~150 ms after the user pauses —
// but the user reads "pause mid-drag" as "still holding the slider, do
// not save yet." Standard native-macOS behaviour is "commit on mouse
// up," so we track a global counter of active drags. `MainView` gates
// its auto-apply on this: as long as any slider is still in flight,
// disk / HID writes are deferred, and on the drop-to-zero transition
// the final draft snapshot is committed once. Sliders opt in via
// `.onEditingChanged` — see the modifier helper below.

@MainActor
final class SliderCommitCoordinator: ObservableObject {
    static let shared = SliderCommitCoordinator()
    /// Number of sliders whose mouse-down has fired without a matching
    /// mouse-up. Bumped from every Slider `.onEditingChanged` handler.
    @Published var activeDrags: Int = 0

    private init() {}

    /// Standard `onEditingChanged` closure — pass this to every Slider
    /// so the coordinator sees drag start / end without every call
    /// site having to spell out the increment/decrement logic.
    static var editingChanged: (Bool) -> Void {
        { editing in
            if editing {
                Self.shared.activeDrags += 1
            } else {
                Self.shared.activeDrags = max(0, Self.shared.activeDrags - 1)
            }
        }
    }
}

// ─── Card: bordered rounded panel used everywhere in the app ─────────

struct Card<Content: View>: View {
    let title: String?
    let content: () -> Content
    init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.s2 - 2) {
            if let title {
                // LocalizedStringKey lookup on the title string — cards
                // always use natural-language labels ("Hardware", "Battery
                // level" …) so this makes the entire app react to the
                // user's locale without touching each call site.
                Text(LocalizedStringKey(title))
                    .font(.system(size: DS.fBody, weight: .semibold))
                    .foregroundStyle(.secondary).padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: DS.s3 - 2) { content() }
                .padding(DS.s4 + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Cards use `.regularMaterial` — Tahoe promotes it to a
                // subtle Liquid Glass tile automatically, and unlike a
                // second `.glassEffect()` layered inside the window's
                // glass it doesn't render as an opaque milky rectangle
                // (nested glass without a `GlassEffectContainer` can't
                // refract the parent glass and falls back to solid frost).
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: DS.rLarge))
                .overlay(RoundedRectangle(cornerRadius: DS.rLarge)
                    .stroke(DS.border, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.05), radius: 0.5, x: 0, y: 0.5)
        }
    }
}

// ─── InfoRow: key / value pair used in the Device pane ──────────────

struct InfoRow: View {
    let key: String
    let value: String
    let mono: Bool
    init(_ key: String, _ value: String, mono: Bool = false) {
        self.key = key; self.value = value; self.mono = mono
    }
    var body: some View {
        HStack {
            // Key labels ("Product", "Firmware" …) always localize.
            Text(LocalizedStringKey(key))
                .font(.system(size: DS.fBody)).foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            // Values are usually hardware data (hex, versions, serials) —
            // localizing is a no-op for those since Localizable.strings has
            // no entry, and SwiftUI falls back to the literal. For values
            // that ARE natural language ("Bluetooth", "Dongle only"), the
            // lookup succeeds and we get the user's locale.
            Text(LocalizedStringKey(value))
                .font(.system(size: DS.fBody, design: mono ? .monospaced : .default))
            Spacer()
        }
        .padding(.vertical, 3)
        Divider().opacity(0.35)
    }
}

// ─── SelectableCard: the "list-row card" surface used across panes ────
//
// RemapPicker's bigRow / chip / aiRow / shortcutRow and ProfilePane's
// triggerAppRow were all building the same "thin-material fill + optional
// accent wash + optional stroke" shape by hand. Extract as a ViewModifier
// so callers keep their own content + layout and just apply the surface.
// Corner radius / accent-wash opacity / stroke behaviour stay as knobs
// because chip is a smaller pill (6 pt radius, slightly stronger accent),
// shortcutRow always shows a hairline, others don't.

extension View {
    /// Wrap `content` in the shared "selectable list-row card" surface.
    ///
    /// - Parameters:
    ///   - selected: True when the row represents the currently-chosen
    ///     option; drives the accent wash + accent-tinted stroke.
    ///   - cornerRadius: 6 for the small `chip` used in dense grids,
    ///     8 for full-width rows. 8 is the default because most call
    ///     sites use it.
    ///   - accentWashOpacity: How strong the "this is picked" tint reads.
    ///     0.15 is the common value; `chip` uses 0.18 because its
    ///     surrounding surface is denser.
    ///   - stroke: Whether to draw a hairline outline. `.none` leaves
    ///     the card borderless (bigRow / aiRow). `.selectedOnly` draws
    ///     it only when the row is selected (chip). `.always` draws
    ///     it in every state, tinted accent when selected
    ///     (shortcutRow, triggerAppRow).
    func selectableCard(selected: Bool,
                        cornerRadius: CGFloat = 8,
                        accentWashOpacity: Double = 0.15,
                        stroke: SelectableCardStroke = .none) -> some View {
        modifier(SelectableCardStyle(selected: selected,
                                     cornerRadius: cornerRadius,
                                     accentWashOpacity: accentWashOpacity,
                                     stroke: stroke))
    }
}

enum SelectableCardStroke {
    case none
    case selectedOnly
    case always
}

private struct SelectableCardStyle: ViewModifier {
    let selected: Bool
    let cornerRadius: CGFloat
    let accentWashOpacity: Double
    let stroke: SelectableCardStroke

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .background(shape.fill(.thinMaterial))
            .background(shape.fill(selected
                                   ? Color.accentColor.opacity(accentWashOpacity)
                                   : Color.clear))
            .overlay {
                switch stroke {
                case .none:
                    EmptyView()
                case .selectedOnly:
                    shape.stroke(selected
                                 ? DS.accentBorderSubtle
                                 : Color.clear,
                                 lineWidth: 0.5)
                case .always:
                    shape.stroke(selected
                                 ? DS.accentBorderSubtle
                                 : DS.border,
                                 lineWidth: 0.5)
                }
            }
    }
}
