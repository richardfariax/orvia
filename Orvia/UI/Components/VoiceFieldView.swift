import SwiftUI

enum VoiceActiveSpeaker: Equatable {
    case none
    case user
    case assistant
}

/// Campo de voz com as superfícies e cores semânticas do Orvia.
struct VoiceFieldView: View {
    let phaseLabel: String
    let message: String
    let statusLine: String
    let speaker: VoiceActiveSpeaker
    let userLevel: Double
    let assistantLevel: Double
    let speechProgress: Double
    let isSpeakingCaption: Bool
    let isProcessing: Bool
    let accent: Color
    let successTint: Bool?

    private let barCount = 72

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let level = activeLevel
            let speakerColor = color(for: speaker)

            ZStack {
                ambient(level: level, color: speakerColor)

                VStack(spacing: 0) {
                    topBar(phaseLabel: phaseLabel, color: speakerColor)
                        .padding(.top, 36)
                        .padding(.horizontal, 40)

                    Spacer(minLength: 0)

                    voiceHero(t: t, level: level, speakerColor: speakerColor)
                        .padding(.horizontal, 64)

                    Spacer(minLength: 0)

                    messageBlock(speakerColor: speakerColor)
                        .padding(.horizontal, 64)
                        .padding(.bottom, 56)
                }
            }
        }
    }

    // MARK: - Ambient

    private func ambient(level: Double, color: Color) -> some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            // Glow central reativo à voz
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            color.opacity(0.16 + level * 0.32),
                            color.opacity(0.04),
                            .clear
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: 260
                    )
                )
                .frame(width: 520, height: 520)
                .blur(radius: 36)
                .scaleEffect(0.92 + level * 0.12)

        }
        .ignoresSafeArea()
    }

    // MARK: - Top

    private func topBar(phaseLabel: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("ORVIA")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(5)
                .foregroundStyle(.primary)

            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .shadow(color: color.opacity(0.8), radius: 4)
                .opacity(speaker == .none && !isProcessing ? 0.4 : 1)

            Spacer()

            Text(phaseLabel)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(3.5)
                .foregroundStyle(color.opacity(0.95))
        }
    }

    // MARK: - Voice hero (center)

    private func voiceHero(t: TimeInterval, level: Double, speakerColor: Color) -> some View {
        VStack(spacing: 20) {
            HStack(spacing: 20) {
                speakerBadge(title: "VOCÊ", active: speaker == .user, color: userColor)
                if isProcessing {
                    processingArc(t: t, color: speakerColor)
                }
                speakerBadge(title: "ORVIA", active: speaker == .assistant, color: assistantColor)
            }

            ZStack {
                // Linha base
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 1)

                waveform(t: t, level: level, color: speakerColor)
                    .frame(height: 96)

                if isProcessing {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.clear, speakerColor.opacity(0.6), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 100, height: 1.5)
                        .offset(x: CGFloat(sin(t * 2.0)) * 180)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 780)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        }
        .frame(maxWidth: .infinity)
    }

    private func messageBlock(speakerColor: Color) -> some View {
        VStack(spacing: 10) {
            if !statusLine.isEmpty {
                Text(statusLine.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(2.4)
                    .foregroundStyle(speakerColor.opacity(0.8))
            }

            if isSpeakingCaption {
                SpeakingCaptionView(
                    text: message,
                    progress: speechProgress,
                    accent: speakerColor
                )
                .frame(maxWidth: 720)
                .frame(height: 110)
            } else {
                Text(message)
                    .font(.system(size: 20, weight: .medium, design: .default))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .frame(maxWidth: 680)
                    .animation(.easeOut(duration: 0.2), value: message)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func speakerBadge(title: String, active: Bool, color: Color) -> some View {
        HStack(spacing: 7) {
            Capsule()
                .fill(active ? color : Color.secondary.opacity(0.3))
                .frame(width: active ? 16 : 8, height: 2)
                .shadow(color: active ? color.opacity(0.7) : .clear, radius: 4)
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(2.2)
                .foregroundStyle(active ? color : .secondary)
        }
        .animation(.easeOut(duration: 0.18), value: active)
    }

    private func processingArc(t: TimeInterval, color: Color) -> some View {
        Circle()
            .trim(from: 0.08, to: 0.38)
            .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(t * 190))
    }

    private func waveform(t: TimeInterval, level: Double, color: Color) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let spacing: CGFloat = 2
            // Barras bem finas (~1.5pt), densidade alta.
            let barWidth = min(1.6, max(1.2, (width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    color.opacity(0.95),
                                    color.opacity(0.35 + level * 0.45)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: barWidth, height: barHeight(index: index, t: t, level: level))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var activeLevel: Double {
        switch speaker {
        case .user:
            return max(0.05, min(1, userLevel))
        case .assistant:
            return max(0.05, min(1, assistantLevel))
        case .none:
            return isProcessing ? 0.2 : 0.08
        }
    }

    private var userColor: Color {
        Color(red: 0.55, green: 0.78, blue: 1.0)
    }

    private var assistantColor: Color {
        if let successTint {
            return successTint
                ? Color(red: 0.4, green: 0.92, blue: 0.72)
                : Color(red: 1.0, green: 0.55, blue: 0.4)
        }
        return Color(red: 0.35, green: 0.92, blue: 0.95)
    }

    private func color(for speaker: VoiceActiveSpeaker) -> Color {
        switch speaker {
        case .user: return userColor
        case .assistant: return assistantColor
        case .none: return accent
        }
    }

    private func barHeight(index: Int, t: TimeInterval, level: Double) -> CGFloat {
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / center
        // Envelope mais concentrado no centro — visual “de voz” clássico.
        let envelope = max(0.08, pow(1.0 - distance, 1.35))

        let wave: Double
        switch speaker {
        case .user:
            wave = sin(t * 17 + Double(index) * 0.55) * 0.5
                + sin(t * 29 + Double(index) * 1.05) * 0.28
        case .assistant:
            wave = sin(t * 13 + Double(index) * 0.42) * 0.48
                + sin(t * 22 + Double(index) * 0.9) * 0.32
        case .none:
            if isProcessing {
                wave = sin(t * 5.5 + Double(index) * 0.35) * 0.3
            } else {
                wave = sin(t * 2.2 + Double(index) * 0.25) * 0.18
            }
        }

        let shaped = max(0, (0.18 + level * 1.1) * envelope + wave * (0.18 + level * 0.5))
        return CGFloat(4 + shaped * 78)
    }
}

// MARK: - Legenda sincronizada com a fala

/// Mostra o texto acompanhando o progresso do TTS: palavra atual em destaque e scroll automático.
private struct SpeakingCaptionView: View {
    let text: String
    let progress: Double
    let accent: Color

    private var words: [String] {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    private var currentIndex: Int {
        Self.wordIndex(progress: progress, words: words)
    }

    var body: some View {
        let tokens = words
        if tokens.isEmpty {
            EmptyView()
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    FlowWordWrap(words: tokens, currentIndex: currentIndex, accent: accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                }
                .mask(
                    LinearGradient(
                        colors: [.clear, .black, .black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .onChange(of: currentIndex) { _, index in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
                .onAppear {
                    proxy.scrollTo(currentIndex, anchor: .center)
                }
            }
        }
    }

    static func wordIndex(progress: Double, words: [String]) -> Int {
        guard !words.isEmpty else { return 0 }
        let weights = words.map { Double(max(2, $0.count)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        var cursor = max(0, min(1, progress)) * total
        for (index, weight) in weights.enumerated() {
            cursor -= weight
            if cursor <= 0 {
                return index
            }
        }
        return words.count - 1
    }
}

/// Empilha palavras em linhas com wrap manual (macOS-friendly).
private struct FlowWordWrap: View {
    let words: [String]
    let currentIndex: Int
    let accent: Color

    var body: some View {
        // Text + AttributedString com wrap nativo e IDs por palavra via background preference é complexo;
        // usamos LazyVGrid de fluxo simples com alignment leading.
        FlexibleWordCloud(words: words, currentIndex: currentIndex, accent: accent)
    }
}

private struct FlexibleWordCloud: View {
    let words: [String]
    let currentIndex: Int
    let accent: Color

    var body: some View {
        // Layout em linhas via ViewThatFits não serve; usamos wrapping com HStack em GeometryReader.
        WordWrapLayout(spacing: 7, lineSpacing: 10) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(.system(size: index == currentIndex ? 22 : 19, weight: index == currentIndex ? .semibold : .medium, design: .default))
                    .foregroundStyle(color(for: index))
                    .shadow(color: index == currentIndex ? accent.opacity(0.45) : .clear, radius: 8)
                    .id(index)
                    .animation(.easeOut(duration: 0.12), value: currentIndex)
            }
        }
    }

    private func color(for index: Int) -> Color {
        if index == currentIndex {
            return .primary
        }
        if index < currentIndex {
            return Color.secondary.opacity(0.6)
        }
        return .primary
    }
}

/// Layout simples de word-wrap para macOS.
private struct WordWrapLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 680
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
            totalHeight = y + lineHeight
        }
        return CGSize(width: maxWidth, height: max(totalHeight, lineHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
        }
    }
}
