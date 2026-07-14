import SwiftUI
import AppKit

// Scroll-wheel LED editor. Sits inside the Sensitivity / Lighting section
// of the main view. Split out of RemapPicker.swift because "lighting" and
// "remap a button" are conceptually different panes that just used to
// share a file for historical reasons.

struct LightingPane: View {
    @Binding var draft: AppSettings

    private var mode: LightingEffect.Mode {
        get { draft.lighting.effect.mode }
    }
    private func setMode(_ m: LightingEffect.Mode) {
        // Preserve any existing color/direction/speed when switching modes so
        // toggling between Static ↔ Breath ↔ Reactive keeps the palette pick.
        let color = currentColor ?? .razerGreen
        let dir: LightingEffect.WaveDir = {
            if case .wave(let d) = draft.lighting.effect { return d }
            return .leftToRight
        }()
        let speed: Int = {
            if case .reactive(_, let s) = draft.lighting.effect { return s }
            return 2
        }()
        switch m {
        case .off:      draft.lighting.effect = .off
        case .static:   draft.lighting.effect = .static(color)
        case .breath:   draft.lighting.effect = .breath(color)
        case .spectrum: draft.lighting.effect = .spectrum
        case .wave:     draft.lighting.effect = .wave(direction: dir)
        case .reactive: draft.lighting.effect = .reactive(color, speed: speed)
        }
    }

    /// Extract the RGB payload if the current effect has one.
    private var currentColor: RGB? {
        switch draft.lighting.effect {
        case .static(let c), .breath(let c): return c
        case .reactive(let c, _):            return c
        default: return nil
        }
    }
    private func setColor(_ c: RGB) {
        switch draft.lighting.effect {
        case .static:            draft.lighting.effect = .static(c)
        case .breath:            draft.lighting.effect = .breath(c)
        case .reactive(_, let s): draft.lighting.effect = .reactive(c, speed: s)
        default: break
        }
    }

    var body: some View {
        Card(title: "Effect") {
            Picker("", selection: Binding(
                get: { mode },
                set: { setMode($0) }
            )) {
                ForEach(LightingEffect.Mode.allCases) { m in
                    Text(LocalizedStringKey(m.label)).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(LocalizedStringKey(subtitle(for: mode)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            // Contextual controls per effect.
            switch draft.lighting.effect {
            case .static, .breath, .reactive:
                Divider().padding(.vertical, 6)
                colorSection
            case .wave(let dir):
                Divider().padding(.vertical, 6)
                directionSection(current: dir)
            case .off, .spectrum:
                EmptyView()
            }

            // Reactive speed lives in its own row so it doesn't crowd colors.
            if case .reactive(_, let speed) = draft.lighting.effect {
                Divider().padding(.vertical, 6)
                reactiveSpeedSection(current: speed)
            }
        }

        Card(title: "Brightness") {
            HStack(spacing: 14) {
                Text("\(draft.lighting.brightness)%")
                    .font(.system(size: 15, weight: .medium))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(draft.lighting.brightness) },
                    set: { draft.lighting.brightness = Int($0.rounded()) }
                ), in: 0...100)
            }
            Text("Applies to the scroll wheel LED (the only light on this mouse).")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
        }
    }

    // MARK: - Sections

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 10) {
                // Custom-color affordance grouped and labeled so it doesn't
                // read as "just another preset that looks different." A thin
                // vertical rule separates it from the preset row.
                VStack(spacing: 4) {
                    ColorPicker("", selection: Binding(
                        get: { Color(nsColor: NSColor(srgbRed: CGFloat(currentColor?.r ?? 68)/255,
                                                      green: CGFloat(currentColor?.g ?? 217)/255,
                                                      blue: CGFloat(currentColor?.b ?? 34)/255,
                                                      alpha: 1)) },
                        set: { c in
                            let ns = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
                            setColor(RGB(
                                r: UInt8(max(0, min(255, Int((ns.redComponent   * 255).rounded())))),
                                g: UInt8(max(0, min(255, Int((ns.greenComponent * 255).rounded())))),
                                b: UInt8(max(0, min(255, Int((ns.blueComponent  * 255).rounded()))))
                            ))
                        }
                    ), supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 40)
                    Text("Custom")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Rectangle()
                    .fill(DS.border)
                    .frame(width: 0.5, height: 26)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 10)
                VStack(spacing: 4) {
                    HStack(spacing: 10) {
                        ForEach(LightingPane.swatches, id: \.self) { s in
                            swatchButton(s)
                        }
                    }
                    Text("Presets")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    private func directionSection(current: LightingEffect.WaveDir) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Direction").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { current },
                set: { draft.lighting.effect = .wave(direction: $0) }
            )) {
                ForEach(LightingEffect.WaveDir.allCases, id: \.self) { d in
                    Text(LocalizedStringKey(d.label)).tag(d)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func reactiveSpeedSection(current: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speed").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { current },
                set: { s in
                    let c = currentColor ?? .razerGreen
                    draft.lighting.effect = .reactive(c, speed: s)
                }
            )) {
                Text("Slow").tag(1)
                Text("Medium").tag(2)
                Text("Fast").tag(3)
                Text("Very fast").tag(4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func swatchButton(_ s: RGB) -> some View {
        Button {
            setColor(s)
        } label: {
            Circle()
                .fill(Color(nsColor: NSColor(srgbRed: CGFloat(s.r)/255,
                                             green:   CGFloat(s.g)/255,
                                             blue:    CGFloat(s.b)/255,
                                             alpha: 1)))
                .frame(width: 22, height: 22)
                .overlay(
                    Circle().stroke(currentColor == s ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5),
                                    lineWidth: currentColor == s ? 2 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .help("Set to #\(String(format: "%02X%02X%02X", s.r, s.g, s.b))")
    }

    private func subtitle(for m: LightingEffect.Mode) -> String {
        switch m {
        case .off:      return "LED off."
        case .static:   return "Solid color."
        case .breath:   return "Fades in and out."
        case .spectrum: return "Cycles the rainbow."
        case .wave:     return "Rainbow scrolls across the wheel."
        case .reactive: return "Flashes on click."
        }
    }

    /// A handful of Synapse-style preset swatches for one-click color pick.
    private static let swatches: [RGB] = [
        .razerGreen,                        // Razer green
        RGB(r: 255, g: 255, b: 255),        // white
        RGB(r: 255, g: 0,   b: 0),          // red
        RGB(r: 255, g: 128, b: 0),          // orange
        RGB(r: 255, g: 255, b: 0),          // yellow
        RGB(r: 0,   g: 128, b: 255),        // sky
        RGB(r: 0,   g: 0,   b: 255),        // blue
        RGB(r: 200, g: 0,   b: 255),        // purple
        RGB(r: 255, g: 0,   b: 128),        // magenta
    ]
}
