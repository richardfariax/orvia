import SwiftUI

extension View {
    /// Keeps grouped forms visually integrated with the settings detail column.
    /// `Form` owns a scroll background on macOS, which becomes an opaque rectangle
    /// when the form is already hosted by the settings scroll view.
    func orviaSettingsFormStyle() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, -8)
    }

    /// Semantic card surface that follows macOS appearance and accessibility
    /// contrast instead of relying on translucent material over an unknown layer.
    func orviaSettingsSurface(cornerRadius: CGFloat = 12) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                }
        )
    }
}
