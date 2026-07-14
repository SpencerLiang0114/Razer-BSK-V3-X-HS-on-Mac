import SwiftUI

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
                .background(RoundedRectangle(cornerRadius: DS.rLarge).fill(DS.cardFill))
                .overlay(RoundedRectangle(cornerRadius: DS.rLarge).stroke(DS.border, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.03), radius: 0.5, x: 0, y: 0.5)
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

