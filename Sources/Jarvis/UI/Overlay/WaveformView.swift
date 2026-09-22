import SwiftUI

/// Animated audio waveform representing mic activity or TTS speech.
public struct WaveformView: View {
    public let isActive: Bool
    public let amplitude: CGFloat

    public init(isActive: Bool = true, amplitude: CGFloat = 0.5) {
        self.isActive = isActive
        self.amplitude = amplitude
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let midY = size.height / 2
                let width = size.width
                let barCount = 28
                let spacing: CGFloat = width / CGFloat(barCount)

                for i in 0..<barCount {
                    let progress = CGFloat(i) / CGFloat(barCount)
                    let x = CGFloat(i) * spacing + spacing / 2

                    // Sine wave modulation based on time and index
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let wave = sin(time * 6.0 + Double(progress * 2 * .pi))
                    let scale = isActive ? max(0.15, abs(CGFloat(wave)) * amplitude) : 0.08
                    let barHeight = size.height * scale

                    let rect = CGRect(
                        x: x - 2,
                        y: midY - barHeight / 2,
                        width: 4,
                        height: barHeight
                    )

                    let path = RoundedRectangle(cornerRadius: 2).path(in: rect)

                    // Gradient color across the waveform
                    let color = Color(
                        hue: 0.58 + Double(progress) * 0.15,
                        saturation: 0.85,
                        brightness: isActive ? 0.95 : 0.45
                    )
                    context.fill(path, with: .color(color))
                }
            }
            .frame(height: 36)
        }
    }
}
