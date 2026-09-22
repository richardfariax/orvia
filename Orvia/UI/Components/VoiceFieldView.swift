import SwiftUI

enum VoiceActiveSpeaker: Equatable {
    case none
    case user
    case assistant
}

/// Compact voice surface that stays readable without covering the user's work.
struct VoiceFieldView: View {
    let phaseLabel: String
    let message: String
    let speaker: VoiceActiveSpeaker
    let userLevel: Double
    let speechProgress: Double
    let isProcessing: Bool
    let isShowingAnswer: Bool
    let accent: Color
    let closeLabel: String
    let copyLabel: String
    let didCopy: Bool
    let shortcutHint: String
    let onClose: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 12)

            ScrollView(.vertical, showsIndicators: true) {
                Text(message)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(message)
            }
            .frame(maxHeight: 80, alignment: .top)

            footer
                .padding(.top, 14)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)

            Text("Orvia")
                .font(.system(size: 14, weight: .semibold))

            Spacer(minLength: 8)

            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            Text(phaseLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)

            if isShowingAnswer {
                Button(action: onCopy) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
                .help(copyLabel)
                .accessibilityLabel(copyLabel)
                .buttonStyle(.borderless)
                .padding(.leading, 8)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .help(closeLabel)
            .accessibilityLabel(closeLabel)
            .buttonStyle(.borderless)
            .padding(.leading, 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isProcessing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            } else if speaker == .user {
                levelMeter
                    .accessibilityHidden(true)
            } else if speaker == .assistant {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: isShowingAnswer ? "checkmark.circle" : "waveform")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
            }

            if speaker == .assistant {
                ProgressView(value: speechProgress)
                    .tint(accent)
                    .frame(maxWidth: 110)
                    .accessibilityHidden(true)
            }

            Spacer()

            Text(shortcutHint)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(height: 18)
    }

    private var levelMeter: some View {
        let level = userLevel
        return HStack(alignment: .center, spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .fill(accent.opacity(0.5 + min(0.5, level)))
                    .frame(width: 3, height: barHeight(at: index, level: level))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private func barHeight(at index: Int, level: Double) -> CGFloat {
        let envelope: [Double] = [0.45, 0.7, 0.9, 1, 0.9, 0.7, 0.45]
        return CGFloat(3 + min(1, max(0, level)) * envelope[index] * 15)
    }
}
