import SwiftUI

// Auto-save status pill — surfaces "Saving…" / "Saved" / errors briefly and
// fades out on its own. No Apply / Discard buttons: every change is applied
// live, matching Synapse. Split out of RemapPicker.swift; the footer lives
// under MainView and just uses MainView.FooterState as its input.

struct StatusBar: View {
    @Binding var footer: MainView.FooterState
    var body: some View {
        HStack(spacing: 12) {
            switch footer {
            case .idle: EmptyView()
            case .working(let m):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(m).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .ok(let m):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(m).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .error(let m):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(m).font(.system(size: 12)).foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            // Errors stay until dismissed — user can copy the text (selectable
            // above) and close it whenever they've read it.
            if case .error = footer {
                Button {
                    footer = .idle
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 8)
        .background(alignment: .center) {
            if #available(macOS 26.0, *) {
                // Full-width glass footer on Tahoe.
                Rectangle().fill(.clear).glassEffect(.regular, in: Rectangle())
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.separator), alignment: .top)
    }
}
