import SwiftUI
import AppKit

// MARK: - Presence state

/// ZiA's visible state, derived from the real backend interaction phase.
public enum ZiaPresenceState: String, Sendable, CaseIterable {
    case disabled
    case idle
    case listening
    case understanding
    case thinking
    case working
    case speaking
    case done
    case error
    case stopped

    public var label: String {
        switch self {
        case .disabled: return "Off"
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .understanding: return "Understanding"
        case .thinking: return "Thinking"
        case .working: return "Working"
        case .speaking: return "Speaking"
        case .done: return "Done"
        case .error: return "Error"
        case .stopped: return "Stopped"
        }
    }

    /// Whether the presence should be time-driven at all. Idle is a very slow
    /// breath (12 fps); everything else is capped at 30 fps.
    public var isAnimating: Bool {
        switch self {
        case .listening, .understanding, .thinking, .working, .speaking: return true
        case .disabled, .idle, .done, .error, .stopped: return false
        }
    }

    /// The state's base spectral hue. One source of truth: the presence, the HUD
    /// backdrop and the window atmosphere all read this, so a state can never be
    /// one colour in one place and another somewhere else.
    public var hue: Double {
        switch self {
        case .disabled: return 0.62
        case .idle: return 0.62
        case .listening: return 0.575
        case .understanding: return 0.60
        case .thinking: return 0.655
        case .working: return 0.695
        case .speaking: return 0.715
        case .done: return 0.545
        case .error: return 0.015
        case .stopped: return 0.085
        }
    }

    /// A representative colour for the state, used by status affordances. The
    /// presence itself renders the full spectral treatment from `hue`.
    public var color: Color {
        Color(hue: hue, saturation: 0.62, brightness: 0.86)
    }

    /// A quiet secondary line, only when it adds information the presence
    /// itself cannot show.
    public var hint: String? {
        switch self {
        case .disabled: return "Enable ZiA from the menu bar"
        case .idle: return "Say “ZiA …” or hold ⌥Space"
        case .working: return "Working quietly — you can keep using your Mac"
        case .error: return nil
        case .stopped: return nil
        default: return nil
        }
    }

    static func resolve(phase: InteractionPhase, appEnabled: Bool, stopped: Bool = false) -> ZiaPresenceState {
        if stopped { return .stopped }
        switch phase {
        case .idle: return appEnabled ? .idle : .disabled
        case .listening: return .listening
        case .understanding: return .understanding
        case .thinking: return .thinking
        case .executing: return .working
        case .speaking: return .speaking
        case .success: return .done
        case .error: return .error
        case .stopped: return .stopped
        }
    }
}

// MARK: - Presence physics profile

/// The physical character of the presence in one state. These are *targets*; the
/// renderer damps toward them every frame, so any state change is interpolated
/// rather than cut — and remains interruptible mid-transition.
struct ZiaPresenceProfile: Sendable {
    /// How much internal light/energy the body holds (0…1).
    var energy: Double
    /// Boundary deformation depth (0…1) — the fluid, organic asymmetry.
    var deform: Double
    /// Atmospheric bloom outside the body (0…1).
    var bloom: Double
    /// Internal rotation of the spectral band (turns per second).
    var spin: Double
    /// Organic boundary turbulence (extra high-frequency modes).
    var turbulence: Double
    /// Base hue (0…1, spectral).
    var hue: Double
    /// Saturation of the spectral band.
    var saturation: Double
    /// How much the body draws inward (understanding folds; speaking expands).
    var fold: Double

    /// The profile for a state, with the colour pinned to `ZiaPresenceState.hue`
    /// so light can never disagree with the state's identity.
    static func forState(_ state: ZiaPresenceState, audioEnergy: Double) -> ZiaPresenceProfile {
        var profile = character(forState: state, audioEnergy: audioEnergy)
        profile.hue = state.hue
        return profile
    }

    /// The physical character of a state, before colour is applied.
    private static func character(forState state: ZiaPresenceState, audioEnergy: Double) -> ZiaPresenceProfile {
        let e = min(1, max(0, audioEnergy))
        switch state {
        case .disabled:
            return .init(energy: 0.08, deform: 0.012, bloom: 0.12, spin: 0.02, turbulence: 0.0,
                         hue: 0.62, saturation: 0.28, fold: 1.0)
        case .idle:
            // Calm, deep living breath: ethereal presence at rest.
            return .init(energy: 0.22, deform: 0.032, bloom: 0.36, spin: 0.05, turbulence: 0.08,
                         hue: 0.62, saturation: 0.66, fold: 1.0)
        case .listening:
            // Real microphone energy drives fluid ripple deformation, bloom and interior plasma.
            return .init(energy: 0.38 + 0.62 * e, deform: 0.050 + 0.115 * e,
                         bloom: 0.46 + 0.44 * e, spin: 0.26 + 0.26 * e, turbulence: 0.34 + 0.44 * e,
                         hue: 0.575, saturation: 0.78, fold: 1.0 - 0.05 * e)
        case .understanding:
            // Energy concentrates inward as the utterance is understood: intense radiant focus.
            return .init(energy: 0.44, deform: 0.032, bloom: 0.40, spin: 0.42, turbulence: 0.20,
                         hue: 0.605, saturation: 0.72, fold: 1.15)
        case .thinking:
            // Deep computation: orbital reorganization of spectral currents. Intelligence at work.
            return .init(energy: 0.54, deform: 0.046, bloom: 0.48, spin: 0.58, turbulence: 0.30,
                         hue: 0.655, saturation: 0.76, fold: 1.05)
        case .working:
            // Rhythmic, steady, calm breathing pulse.
            return .init(energy: 0.50, deform: 0.050, bloom: 0.48, spin: 0.34, turbulence: 0.36,
                         hue: 0.695, saturation: 0.72, fold: 1.0)
        case .speaking:
            // Expressive vocal radiance: expansive blooming waves of light.
            return .init(energy: 0.70, deform: 0.065, bloom: 0.68, spin: 0.24, turbulence: 0.42,
                         hue: 0.718, saturation: 0.78, fold: 0.94)
        case .done:
            // Settling naturally into quiet stillness.
            return .init(energy: 0.28, deform: 0.028, bloom: 0.38, spin: 0.08, turbulence: 0.12,
                         hue: 0.545, saturation: 0.62, fold: 1.0)
        case .error:
            // Subdued ember warmth: gentle notice rather than aggressive flashing.
            return .init(energy: 0.24, deform: 0.016, bloom: 0.42, spin: 0.02, turbulence: 0.05,
                         hue: 0.015, saturation: 0.75, fold: 1.02)
        case .stopped:
            // Cooled, calm twilight stillness.
            return .init(energy: 0.16, deform: 0.018, bloom: 0.24, spin: 0.0, turbulence: 0.05,
                         hue: 0.085, saturation: 0.48, fold: 1.0)
        }
    }
}

// MARK: - Real audio metering

/// Bounded ring of measured microphone energy.
///
/// Nothing here invents signal: `envelope` is an attack/release smoothed version
/// of real RMS samples, and the buffer contains only measured frames. If capture
/// is unavailable the envеlope decays to zero and the presence stays quiet.
@MainActor
public final class ZiaAudioMeter: ObservableObject {
    public static let shared = ZiaAudioMeter()

    public static let historyCount = 48

    /// Instantaneous, attack/release smoothed energy in 0…1 — this is what the
    /// presence deforms with.
    @Published public private(set) var envelope: Float = 0
    /// Recent measured energies (oldest → newest) for the fluid energy field.
    @Published public private(set) var history: [Float] = Array(repeating: 0, count: historyCount)
    /// True once real input has been observed.
    public private(set) var hasLiveInput = false

    private init() {}

    /// Sample the live capture path on a bounded cadence while a listening
    /// surface is on screen. No timer exists when ZiA is idle or hidden.
    func captureSample() {
        let raw: Float
        if AudioCapture.shared.isCapturing {
            // RMS is small in absolute terms; scale for a stable, readable range.
            raw = min(1, max(0, AudioDiagnostic.shared.latestLevels().rms * 13))
            hasLiveInput = hasLiveInput || raw > 0.001
        } else {
            raw = 0
        }

        // Fast attack, slow release: the presence follows the voice instantly and
        // settles gracefully, which is what makes it feel physical.
        let attack: Float = 0.55
        let release: Float = 0.10
        let coefficient = raw > envelope ? attack : release
        envelope += (raw - envelope) * coefficient
        if envelope < 0.0005 { envelope = 0 }

        history.removeFirst()
        history.append(envelope)
    }

    /// Render-only: install a representative measured buffer so the reference
    /// images can show what live speech looks like without a microphone session.
    /// Never called by the running UI — the app only ever shows real capture.
    func _applyForRendering(history samples: [Float]) {
        let clamped = samples.suffix(Self.historyCount).map { min(1, max(0, $0)) }
        var padded = Array(repeating: Float(0), count: Self.historyCount - clamped.count)
        padded.append(contentsOf: clamped)
        history = padded
        envelope = padded.last ?? 0
        hasLiveInput = padded.contains { $0 > 0 }
    }

    /// Reset when a listening session ends so a stale peak cannot linger.
    func reset() {
        envelope = 0
        history = Array(repeating: 0, count: Self.historyCount)
    }
}

// MARK: - Presence orb

/// ZiA's identity: a bead of intelligent light in glass.
///
/// Built from layered light rather than a circle with a gradient — atmospheric
/// bloom, a deformable glass body, a spectral band travelling inside it, soft
/// internal lobes, a specular pair and a volumetric inner shadow. The boundary
/// is always organically deformed (never a uniform scale pulse), and every value
/// is damped toward its state target so transitions are continuous.
public struct ZiaPresenceOrb: View {
    public let state: ZiaPresenceState
    public var size: CGFloat
    /// Optional external energy drive (0…1). When nil the orb reads real
    /// microphone energy while listening.
    public var amplitude: Double?
    /// When false the presence freezes (hidden HUD) so nothing renders off-screen.
    public var animate: Bool

    @ObservedObject private var meter = ZiaAudioMeter.shared

    public init(
        state: ZiaPresenceState,
        size: CGFloat = 120,
        amplitude: Double? = nil,
        animate: Bool = true
    ) {
        self.state = state
        self.size = size
        self.amplitude = amplitude
        self.animate = animate
    }

    private var audioEnergy: Double {
        if let amplitude { return amplitude }
        guard state == .listening else { return 0 }
        return Double(meter.envelope)
    }

    private var motion: Double {
        let base = state.isAnimating || state == .idle
        return animate && base ? 1 : 0
    }

    public var body: some View {
        Group {
            if animate && (state.isAnimating || state == .idle) && !ZiaMotion.reduceMotion {
                TimelineView(.animation(minimumInterval: interval)) { timeline in
                    canvas(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                // Still frame. Reduce Motion and idle-while-hidden both land here.
                canvas(at: 0)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(Text("ZiA, \(state.label)"))
    }

    /// 30 fps while active, 12 fps for the idle breath — never 120 fps.
    private var interval: Double {
        state.isAnimating ? 1.0 / 30.0 : 1.0 / 12.0
    }

    private func canvas(at time: Double) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
            render(
                context: &context,
                size: canvasSize,
                time: state.isAnimating ? time : time * 0.35,
                audioEnergy: audioEnergy,
                motion: motion
            )
        }
    }

    // MARK: Renderer

    private func render(
        context: inout GraphicsContext,
        size canvasSize: CGSize,
        time: Double,
        audioEnergy: Double,
        motion: Double
    ) {
        var profile = ZiaPresenceProfile.forState(state, audioEnergy: audioEnergy)
        var motion = motion
        // Reduce Motion: keep the state's light and colour, remove movement.
        if ZiaMotion.reduceMotion {
            profile.spin = 0
            profile.turbulence = 0
            profile.deform *= 0.1
            motion = 0
        }

        let detailed = canvasSize.width >= 56
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let half = min(canvasSize.width, canvasSize.height) / 2
        let bodyRadius = half * 0.68

        // 1. Dual-layer atmospheric bloom: living aura radiating into surrounding space
        drawBloom(context: &context, center: center, radius: bodyRadius, profile: profile, time: time)

        // 2. Liquid glass body with multi-frequency harmonic fluid boundary
        let bodyPath = Self.organicPath(
            center: center,
            radius: bodyRadius * profile.fold,
            time: time * motion,
            deform: profile.deform * motion,
            turbulence: profile.turbulence * motion
        )

        // 3. Volumetric interior: luminous nucleus, orbiting plasma vortices, and spectral caustic ribbon
        context.drawLayer { layer in
            layer.clip(to: bodyPath)
            drawInterior(context: &layer, center: center, radius: bodyRadius,
                         profile: profile, time: time * motion, detailed: detailed)
        }

        // 4. Volumetric glass shell: clear refractive core with subtle perimeter absorption
        context.fill(
            bodyPath,
            with: .radialGradient(
                Self.shellGradient(profile: profile),
                center: center,
                startRadius: 0,
                endRadius: bodyRadius * profile.fold
            )
        )

        // 5. Asymmetric Fresnel rim light and edge transmission
        if detailed {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: bodyRadius * 0.05))
                layer.stroke(
                    bodyPath,
                    with: .linearGradient(
                        Self.rimGradient(profile: profile),
                        startPoint: CGPoint(x: center.x - bodyRadius, y: center.y - bodyRadius),
                        endPoint: CGPoint(x: center.x + bodyRadius, y: center.y + bodyRadius)
                    ),
                    lineWidth: bodyRadius * 0.065
                )
            }
        }

        // 6. Curvature glass caustics & specular highlights
        drawSpecular(context: &context, center: center, radius: bodyRadius, profile: profile)

        // 7. Volumetric depth shadow: subtle mass and 3D anchoring
        if detailed {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: bodyRadius * 0.32))
                let shadow = Path(ellipseIn: CGRect(
                    x: center.x - bodyRadius * 0.68,
                    y: center.y + bodyRadius * 0.34,
                    width: bodyRadius * 1.36,
                    height: bodyRadius * 0.65
                ))
                layer.fill(shadow, with: .color(.black.opacity(0.30)))
            }
        }
    }

    // MARK: Layers

    private func drawBloom(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        profile: ZiaPresenceProfile,
        time: Double
    ) {
        let breathe = 1 + 0.06 * sin(time * 0.95)
        let outer = radius * (2.20 * CGFloat(breathe))
        let inner = radius * (1.45 * CGFloat(breathe))

        // Outer ambient spatial radiance
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.55))
            let rect = CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2)
            layer.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [
                        Self.spectral(profile.hue, saturation: 0.82, brightness: 0.65, alpha: 0.36 * profile.bloom),
                        Self.spectral(profile.hue + 0.06, saturation: 0.88, brightness: 0.55, alpha: 0.18 * profile.bloom),
                        .clear
                    ]),
                    center: center,
                    startRadius: radius * 0.20,
                    endRadius: outer
                )
            )
        }

        // Inner chromatic halo
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.28))
            let rect = CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)
            layer.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [
                        Self.spectral(profile.hue - 0.04, saturation: 0.90, brightness: 0.85, alpha: 0.28 * profile.bloom),
                        Self.spectral(profile.hue + 0.10, saturation: 0.85, brightness: 0.70, alpha: 0.14 * profile.bloom),
                        .clear
                    ]),
                    center: center,
                    startRadius: radius * 0.30,
                    endRadius: inner
                )
            )
        }
    }

    private func drawInterior(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        profile: ZiaPresenceProfile,
        time: Double,
        detailed: Bool
    ) {
        // Deep celestial base: warm-cool translucent luminosity
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [
                    Self.spectral(profile.hue, saturation: profile.saturation * 0.85,
                                  brightness: 0.60, alpha: 0.35 + 0.35 * profile.energy),
                    Self.spectral(profile.hue - 0.05, saturation: profile.saturation,
                                  brightness: 0.40, alpha: 0.20 + 0.22 * profile.energy),
                    Self.spectral(profile.hue + 0.08, saturation: profile.saturation * 0.9,
                                  brightness: 0.22, alpha: 0.15)
                ]),
                center: CGPoint(x: center.x, y: center.y + radius * 0.08),
                startRadius: 0,
                endRadius: radius * 1.05
            )
        )

        guard detailed else { return }

        // Central living plasma nucleus (breathing hotspot)
        let coreBreathe = 1 + 0.08 * sin(time * 1.35)
        let coreRadius = radius * (0.38 + 0.22 * profile.energy) * CGFloat(coreBreathe)
        let coreCenter = CGPoint(x: center.x, y: center.y - radius * 0.06)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.18))
            layer.fill(
                Path(ellipseIn: CGRect(x: coreCenter.x - coreRadius, y: coreCenter.y - coreRadius,
                                       width: coreRadius * 2, height: coreRadius * 2)),
                with: .radialGradient(
                    Gradient(colors: [
                        .white.opacity(0.35 + 0.35 * profile.energy),
                        Self.spectral(profile.hue + 0.04, saturation: 0.80, brightness: 0.98,
                                      alpha: 0.30 + 0.30 * profile.energy),
                        .clear
                    ]),
                    center: coreCenter,
                    startRadius: 0,
                    endRadius: coreRadius
                )
            )
        }

        // Three orbiting fluid plasma vortices (chromatic nebulae)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.20))
            let orbits: [(hueOffset: Double, speed: Double, phaseOffset: Double, distance: CGFloat, radiusScale: CGFloat)] = [
                (-0.06, 0.24, 0.0, 0.32, 0.34),  // Cyan / Azure vortex
                (0.08, 0.38, 2.1, 0.28, 0.30),   // Violet vortex
                (0.18, 0.52, 4.2, 0.35, 0.32)    // Radiant rose / magenta vortex
            ]
            for orbit in orbits {
                let currentPhase = time * (orbit.speed * (0.8 + 0.4 * profile.spin)) + orbit.phaseOffset
                let dist = radius * orbit.distance * (1.0 + 0.10 * CGFloat(profile.turbulence))
                let pt = CGPoint(
                    x: center.x + CGFloat(cos(currentPhase)) * dist,
                    y: center.y + CGFloat(sin(currentPhase * 0.85)) * dist * 0.75
                )
                let lobeR = radius * (orbit.radiusScale + 0.18 * CGFloat(profile.energy))
                let rect = CGRect(x: pt.x - lobeR, y: pt.y - lobeR, width: lobeR * 2, height: lobeR * 2)
                layer.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [
                            Self.spectral(profile.hue + orbit.hueOffset,
                                          saturation: profile.saturation,
                                          brightness: 0.96,
                                          alpha: 0.25 + 0.32 * profile.energy),
                            Self.spectral(profile.hue + orbit.hueOffset + 0.04,
                                          saturation: profile.saturation * 0.85,
                                          brightness: 0.80,
                                          alpha: 0.10 + 0.15 * profile.energy),
                            .clear
                        ]),
                        center: pt, startRadius: 0, endRadius: lobeR
                    )
                )
            }
        }

        // Spectral caustic ribbon: travelling S-curve lens
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.15))
            let angle = time * profile.spin * 2 * .pi
            let band = Self.spectralBand(center: center, radius: radius, angle: angle,
                                         thickness: 0.28 + 0.18 * profile.energy,
                                         curvature: 0.44 + 0.20 * profile.turbulence)
            layer.fill(band, with: .linearGradient(
                Self.spectralGradient(profile: profile, energy: profile.energy),
                startPoint: CGPoint(x: center.x - radius, y: center.y - radius * 0.35),
                endPoint: CGPoint(x: center.x + radius, y: center.y + radius * 0.35)
            ))
        }
    }

    private func drawSpecular(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        profile: ZiaPresenceProfile
    ) {
        // 1. Primary crescent caustic highlight (top-left sphere curvature)
        let crescentCenter = CGPoint(x: center.x - radius * 0.30, y: center.y - radius * 0.36)
        let crescentWidth = radius * 0.58
        let crescentHeight = radius * 0.34

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.08))
            let primaryRect = CGRect(
                x: crescentCenter.x - crescentWidth / 2,
                y: crescentCenter.y - crescentHeight / 2,
                width: crescentWidth,
                height: crescentHeight
            )
            layer.fill(
                Path(ellipseIn: primaryRect),
                with: .linearGradient(
                    Gradient(colors: [
                        .white.opacity(0.68 + 0.22 * profile.energy),
                        .white.opacity(0.20),
                        .clear
                    ]),
                    startPoint: CGPoint(x: primaryRect.minX, y: primaryRect.minY),
                    endPoint: CGPoint(x: primaryRect.maxX, y: primaryRect.maxY)
                )
            )
        }

        // Intense pinpoint apex specular crest
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.03))
            let apex = CGRect(
                x: center.x - radius * 0.35,
                y: center.y - radius * 0.40,
                width: radius * 0.22,
                height: radius * 0.12
            )
            layer.fill(
                Path(ellipseIn: apex),
                with: .color(.white.opacity(0.75 + 0.20 * profile.energy))
            )
        }

        // 2. Secondary environmental rim reflection catch (bottom-right perimeter)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.09))
            let secondaryRect = CGRect(
                x: center.x + radius * 0.16,
                y: center.y + radius * 0.26,
                width: radius * 0.38,
                height: radius * 0.22
            )
            layer.fill(
                Path(ellipseIn: secondaryRect),
                with: .color(Self.spectral(profile.hue + 0.08, saturation: 0.35,
                                           brightness: 1.0, alpha: 0.18 + 0.18 * profile.energy))
            )
        }
    }

    // MARK: Geometry

    /// A closed, organically deformed circle. Radial modes of low frequency give
    /// asymmetry and slow evolution — never a uniform `scaleEffect` pulse.
    private static func organicPath(
        center: CGPoint,
        radius: CGFloat,
        time: Double,
        deform: Double,
        turbulence: Double
    ) -> Path {
        let samples = 72
        let modes: [(order: Double, weight: Double, speed: Double, phase: Double)] = [
            (2, 0.55, 0.21, 0.0),
            (3, 0.32, 0.13, 1.7),
            (5, 0.16, 0.29, 3.4),
            (7, 0.09 * (0.4 + turbulence), 0.37, 5.1),
            (11, 0.05 * turbulence, 0.53, 0.9)
        ]

        var points: [CGPoint] = []
        points.reserveCapacity(samples)
        for index in 0..<samples {
            let theta = Double(index) / Double(samples) * 2 * .pi
            var offset = 0.0
            for mode in modes {
                offset += mode.weight * sin(mode.order * theta + mode.speed * time * 2 * .pi + mode.phase)
            }
            let r = radius * (1 + deform * offset)
            points.append(CGPoint(x: center.x + CGFloat(cos(theta) * r),
                                  y: center.y + CGFloat(sin(theta) * r)))
        }
        return smoothClosedPath(points)
    }

    /// Quadratic smoothing through segment midpoints — a clean curve from samples.
    private static func smoothClosedPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count > 2 else { return path }
        let start = CGPoint(x: (points[0].x + points[points.count - 1].x) / 2,
                            y: (points[0].y + points[points.count - 1].y) / 2)
        path.move(to: start)
        for index in 0..<points.count {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let midpoint = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: midpoint, control: current)
        }
        path.closeSubpath()
        return path
    }

    /// A curved band of light that crosses the body — the reference's travelling
    /// spectral lens. Built from two symmetric curves, so its thickness and
    /// curvature can breathe with energy.
    private static func spectralBand(
        center: CGPoint,
        radius: CGFloat,
        angle: Double,
        thickness: Double,
        curvature: Double
    ) -> Path {
        let samples = 40
        let width = radius * 1.25
        let half = radius * max(0.05, thickness) / 2

        func point(_ u: Double, edge: Double) -> CGPoint {
            let x = (u - 0.5) * 2 * width
            // A shallow S-curve plus a bow gives the band its lens shape.
            let bow = sin(u * .pi) * curvature * radius * 0.55
            let wave = sin(u * .pi * 1.6 + 0.6) * radius * 0.16
            let y = bow + wave + edge * half * (1 + 0.5 * sin(u * .pi))
            let rotated = CGPoint(
                x: x * cos(angle) - y * sin(angle),
                y: x * sin(angle) + y * cos(angle)
            )
            return CGPoint(x: center.x + rotated.x, y: center.y + rotated.y)
        }

        var path = Path()
        path.move(to: point(0, edge: -1))
        for index in 0...samples {
            let u = Double(index) / Double(samples)
            path.addLine(to: point(u, edge: -1))
        }
        for index in stride(from: samples, through: 0, by: -1) {
            let u = Double(index) / Double(samples)
            path.addLine(to: point(u, edge: 1))
        }
        path.closeSubpath()
        return path
    }

    // MARK: Colour

    private static func spectral(
        _ hue: Double,
        saturation: Double,
        brightness: Double,
        alpha: Double
    ) -> Color {
        Color(hue: hue.truncatingRemainder(dividingBy: 1.0) < 0
              ? hue.truncatingRemainder(dividingBy: 1.0) + 1
              : hue.truncatingRemainder(dividingBy: 1.0),
              saturation: min(1, max(0, saturation)),
              brightness: min(1, max(0, brightness)),
              opacity: min(1, max(0, alpha)))
    }

    /// Blue → violet → cyan → magenta → white highlight, blended organically
    /// rather than as a rainbow.
    private static func spectralGradient(profile: ZiaPresenceProfile, energy: Double) -> Gradient {
        let base = profile.hue
        return Gradient(stops: [
            .init(color: spectral(base - 0.10, saturation: profile.saturation, brightness: 0.70,
                                  alpha: 0.30 + 0.30 * energy), location: 0.0),
            .init(color: spectral(base + 0.02, saturation: profile.saturation, brightness: 0.80,
                                  alpha: 0.40 + 0.34 * energy), location: 0.30),
            .init(color: spectral(base + 0.09, saturation: profile.saturation * 0.85, brightness: 0.98,
                                  alpha: 0.45 + 0.40 * energy), location: 0.52),
            .init(color: .white.opacity(0.30 + 0.45 * energy), location: 0.60),
            .init(color: spectral(base + 0.16, saturation: profile.saturation * 0.75, brightness: 0.90,
                                  alpha: 0.28 + 0.32 * energy), location: 0.80),
            .init(color: spectral(base + 0.22, saturation: profile.saturation * 0.60, brightness: 0.60,
                                  alpha: 0.06), location: 1.0)
        ])
    }

    /// Glass shell: dark interior, tinted toward the rim, so light inside reads
    /// through depth.
    private static func shellGradient(profile: ZiaPresenceProfile) -> Gradient {
        Gradient(stops: [
            .init(color: Color.black.opacity(0.10), location: 0.0),
            .init(color: Color.black.opacity(0.22), location: 0.45),
            .init(color: spectral(profile.hue + 0.04, saturation: profile.saturation,
                                  brightness: 0.35, alpha: 0.30), location: 0.82),
            .init(color: spectral(profile.hue + 0.06, saturation: profile.saturation,
                                  brightness: 0.60, alpha: 0.55), location: 1.0)
        ])
    }

    /// Asymmetric rim light: bright upper-left, spectral lower-right.
    private static func rimGradient(profile: ZiaPresenceProfile) -> Gradient {
        Gradient(colors: [
            .white.opacity(0.34 + 0.28 * profile.energy),
            spectral(profile.hue + 0.05, saturation: profile.saturation, brightness: 0.95,
                     alpha: 0.30 + 0.30 * profile.energy),
            .white.opacity(0.10)
        ])
    }
}

// MARK: - Fluid energy field (listening)

/// The listening field: fluid bands of light that swell with real microphone
/// energy. Deliberately not an equalizer — the bands are smoothed envelopes
/// rendered as overlapping waves, with no discrete bars.
public struct ZiaEnergyField: View {
    @ObservedObject private var meter = ZiaAudioMeter.shared
    private let isActive: Bool
    private let tint: Color

    public init(isActive: Bool, tint: Color = ZiaColors.presence) {
        self.isActive = isActive
        self.tint = tint
    }

    public var body: some View {
        Group {
            if isActive {
                if ZiaMotion.reduceMotion {
                    staticField
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        field(at: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            } else {
                empty
            }
        }
        .frame(height: 46)
        .frame(maxWidth: .infinity)
        // Bounded sampling: no timer exists unless this field is on screen.
        .task(id: isActive) {
            meter.reset()
            guard isActive else { return }
            while !Task.isCancelled {
                meter.captureSample()
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
            meter.reset()
        }
        .accessibilityHidden(!isActive)
    }

    private var empty: some View { Color.clear }

    private var staticField: some View {
        Canvas { context, size in
            draw(context: &context, size: size, time: 0, energy: Double(meter.envelope))
        }
    }

    private func field(at time: Double) -> some View {
        Canvas { context, size in
            draw(context: &context, size: size, time: time, energy: Double(meter.envelope))
        }
    }

    /// Three overlapping waves sampled from measured energy: the newest samples
    /// form the centre band, older ones trail off behind it.
    private func draw(context: inout GraphicsContext, size: CGSize, time: Double, energy: Double) {
        let history = meter.history
        let midY = size.height / 2
        let width = size.width

        for band in 0..<3 {
            let trail = Double(band)
            let scale = (1.0 - 0.26 * trail) * (0.35 + 0.75 * energy)
            let alpha = (0.30 - 0.07 * trail) * (0.45 + 0.55 * min(1, energy * 2))
            guard alpha > 0.01 else { continue }

            var path = Path()
            for index in 0..<history.count {
                let x = width * Double(index) / Double(history.count - 1)
                // Read the history from behind (older) to front (newest), with a
                // gentle travelling ripple so silence still looks calm, not dead.
                let sampleIndex = min(history.count - 1, max(0, index + band * 3))
                let value = Double(history[sampleIndex])
                let ripple = 0.06 * sin(Double(index) * 0.34 + time * 1.15 + trail * 1.4)
                let offset = (value * 1.35 + ripple + 0.02) * Double(midY) * 0.88 * scale
                let point = CGPoint(x: x, y: midY - offset)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            for index in stride(from: history.count - 1, through: 0, by: -1) {
                let x = width * Double(index) / Double(history.count - 1)
                let sampleIndex = min(history.count - 1, max(0, index + band * 3))
                let value = Double(history[sampleIndex])
                let ripple = 0.06 * sin(Double(index) * 0.34 + time * 1.15 + trail * 1.4)
                let offset = (value * 1.35 + ripple + 0.02) * Double(midY) * 0.88 * scale
                path.addLine(to: CGPoint(x: x, y: midY + offset * 0.55))
            }
            path.closeSubpath()

            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 6 + CGFloat(trail) * 3))
                layer.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [
                            .clear,
                            tint.opacity(alpha * 0.35),
                            Color(hue: 0.58, saturation: 0.65, brightness: 1.0, opacity: alpha * 0.9),
                            Color(hue: 0.74, saturation: 0.60, brightness: 1.0, opacity: alpha * 0.8),
                            tint.opacity(alpha * 0.25),
                            .clear
                        ]),
                        startPoint: CGPoint(x: 0, y: midY),
                        endPoint: CGPoint(x: width, y: midY)
                    )
                )
            }
        }
    }
}

// MARK: - Floating transcript

/// Live transcript as floating typography: no card, no border, no background.
/// It fades and lifts in, and settles gently when the utterance resolves.
public struct ZiaTranscript: View {
    private let text: String
    private let isActive: Bool
    private let isSettled: Bool
    private let placeholder: String

    public init(text: String, isActive: Bool, isSettled: Bool = false,
                placeholder: String = "Listening…") {
        self.text = text
        self.isActive = isActive
        self.isSettled = isSettled
        self.placeholder = placeholder
    }

    public var body: some View {
        VStack(spacing: 6) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 16, weight: .light, design: .rounded))
                    .foregroundStyle(.white.opacity(0.40))
                    .tracking(0.3)
            } else {
                Text(text)
                    .font(.system(size: 18, weight: .light, design: .default))
                    .foregroundStyle(.white.opacity(isSettled ? 0.65 : 0.96))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .tracking(0.2)
                    .shadow(color: .black.opacity(0.60), radius: 10, y: 2)
                    .animation(ZiaMotion.respectingReduceMotion(.easeOut(duration: 0.22)), value: text)
                    .animation(ZiaMotion.respectingReduceMotion(.easeOut(duration: 0.28)), value: isSettled)
            }
        }
        .frame(maxWidth: 320)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(text.isEmpty ? placeholder : text))
    }
}
