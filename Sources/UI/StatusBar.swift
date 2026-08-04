import SwiftUI

// Auto-save status toast — surfaces "Saving…" / "Saved" / errors briefly
// and fades out on its own. Rendered as a compact floating pill in the
// top-right of the panel via `.overlay(alignment: .topTrailing)` — the
// previous full-width bottom bar reflowed the ScrollView every time it
// appeared (content got a scrollbar because the footer stole vertical
// space), which was the "古老很不好看" UX the user called out.
//
// State machine lives in MainView; this view is purely presentational.

struct StatusBar: View {
    @Binding var footer: MainView.FooterState

    var body: some View {
        HStack(spacing: 8) {
            switch footer {
            case .idle:
                EmptyView()
            case .working(let m):
                ProgressView().controlSize(.small)
                Text(m)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            case .ok(let m):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
                Text(m)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            case .error(let m):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                Text(m)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Button {
                    footer = .idle
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                // `.help(...)` only surfaces on hover. Without an
                // explicit accessibility label VoiceOver reads the
                // button as "xmark, button" — the label lets it
                // announce "Dismiss error, button" instead.
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(cornerRadius: 12)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}
