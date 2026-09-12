import AppKit
import SwiftUI

extension Color {
    /// Mixes toward white by `amount` (0…1). Used for the charging fill's
    /// brighter trailing stop so a theme colour can build a full ramp without
    /// hard-coded hex values.
    func hisLighten(_ amount: Double) -> Color {
        hisMixed(with: .white, ratio: amount)
    }

    /// Mixes toward black by `amount` (0…1) — the darker leading stop of the
    /// charging fill gradient.
    func hisDarken(_ amount: Double) -> Color {
        hisMixed(with: .black, ratio: amount)
    }

    private func hisMixed(with other: Color, ratio: Double) -> Color {
        let base = NSColor(self).usingColorSpace(.sRGB)
        let mix = NSColor(other).usingColorSpace(.sRGB)
        guard let base, let mix else { return self }
        return Color(
            red: Double(base.redComponent) + (Double(mix.redComponent) - Double(base.redComponent)) * ratio,
            green: Double(base.greenComponent) + (Double(mix.greenComponent) - Double(base.greenComponent)) * ratio,
            blue: Double(base.blueComponent) + (Double(mix.blueComponent) - Double(base.blueComponent)) * ratio
        )
    }
}

/// GPU-driven energy particle flow for the charging bar.
///
/// A `CAEmitterLayer` keeps a handful of small light points alive inside the
/// bar's filled section; they drift left → right toward the charge edge while
/// fading, suggesting energy arriving at the battery. Every value lives in
/// ``ChargingParticleHostView/Tuning`` so the flow can be retuned in one place.
///
/// The view itself is the clip: SwiftUI sizes it to the filled portion of the
/// bar (with ``Motion/progress`` driving width changes), and `masksToBounds`
/// confines all particles to those bounds — they can never render into the
/// unfilled remainder of the bar.
///
/// All motion is Core Animation work on the GPU; the CPU only spawns a few
/// particles per second. Setting `isActive` to `false` stops spawning and fades
/// the layer out over ``Motion/standard`` while live particles finish their
/// lifetime, so the flow never vanishes in a single frame.
struct ChargingParticleFlow: NSViewRepresentable {
    /// The bar's current fill colour. Particles are mixed toward white so they
    /// read as pale energy highlights on top of the fill, whatever the theme.
    let tint: Color
    /// Drives spawning. `false` drains the flow gracefully.
    var isActive: Bool

    func makeNSView(context: Context) -> ChargingParticleHostView {
        ChargingParticleHostView()
    }

    func updateNSView(_ nsView: ChargingParticleHostView, context: Context) {
        nsView.update(tint: tint, isActive: isActive)
    }
}

/// Layer-backed host for the charging particle emitter. See ``ChargingParticleFlow``.
@MainActor
final class ChargingParticleHostView: NSView {

    /// Everything visual about the flow, in one place:
    /// ~4 particles alive at once (3.2 spawns/s × 1.25 s mean lifetime),
    /// 50–100 pt/s left → right, 1.6–3.4 pt cores at 0.18–0.66 alpha.
    private enum Tuning {
        static let birthRate: Float = 3.2
        static let lifetime: Float = 1.25
        static let lifetimeRange: Float = 0.45
        static let velocity: CGFloat = 75
        static let velocityRange: CGFloat = 25
        static let alpha: Float = 0.42
        static let alphaRange: Float = 0.24
        /// Linear fade so a particle is (near) transparent when its life ends.
        static let alphaSpeed: Float = -0.34
        static let scale: CGFloat = 0.78
        static let scaleRange: CGFloat = 0.27
        /// A gentle swell over the particle's life softens its appearance.
        static let scaleSpeed: CGFloat = 0.10
        static let emissionRange: CGFloat = 0.05
        /// Spawn-box height: ±0.75 pt of vertical jitter so the flow is not
        /// perfectly mechanical.
        static let spawnHeight: CGFloat = 1.5
        /// How far a tint is mixed toward white (see `tint` on the representable).
        static let tintWhiteness = 0.35
    }

    private let emitter = CAEmitterLayer()
    private let cell = CAEmitterCell()
    private var isConfigured = false
    private var lastTint: Color?
    private var lastIsActive = false

    /// The particle sprite: a hot ~3 pt core melting into a soft ~10 pt halo,
    /// rendered once as a 16 pt bitmap so points read as light, not solid dots.
    private static let particleSprite: CGImage = makeParticleSprite()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func update(tint: Color, isActive: Bool) {
        let tintChanged = tint != lastTint
        let wasActive = lastIsActive
        lastTint = tint
        lastIsActive = isActive
        ensureSetup()
        if tintChanged, isConfigured {
            cell.color = Self.particleColor(for: tint)
        }
        guard isActive != wasActive else { return }
        applyActivity(animated: true)
    }

    private func ensureSetup() {
        guard !isConfigured, let root = layer else { return }
        isConfigured = true

        root.masksToBounds = true

        cell.contents = Self.particleSprite
        cell.color = Self.particleColor(for: lastTint ?? .white)
        cell.birthRate = Tuning.birthRate
        cell.lifetime = Tuning.lifetime
        cell.lifetimeRange = Tuning.lifetimeRange
        cell.velocity = Tuning.velocity
        cell.velocityRange = Tuning.velocityRange
        cell.emissionLongitude = 0
        cell.emissionRange = Tuning.emissionRange
        // On macOS the cell's *base* alpha is the alpha of `color`; the
        // speed/range below fade it out over the particle's lifetime.
        cell.alphaRange = Tuning.alphaRange
        cell.alphaSpeed = Tuning.alphaSpeed
        cell.scale = Tuning.scale
        cell.scaleRange = Tuning.scaleRange
        cell.scaleSpeed = Tuning.scaleSpeed

        emitter.emitterShape = .rectangle
        emitter.emitterMode = .volume
        emitter.emitterCells = [cell]
        root.addSublayer(emitter)

        applyActivity(animated: false)
    }

    private func applyActivity(animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(Motion.standard)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        cell.birthRate = lastIsActive ? Tuning.birthRate : 0
        emitter.opacity = lastIsActive ? 1 : 0
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        ensureSetup()
        guard isConfigured, bounds.height > 0 else { return }
        // No explicit transaction here: whatever animation applies to the
        // view's own frame (SwiftUI's Motion.progress on width changes)
        // carries the emitter geometry along with it, keeping the clip in
        // lockstep with the drawn fill.
        layer?.cornerRadius = bounds.height / 2
        emitter.frame = bounds
        emitter.emitterSize = CGSize(width: bounds.width, height: Tuning.spawnHeight)
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private static func makeParticleSprite() -> CGImage {
        let pixels = 32
        let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let gradient = CGGradient(
            colorsSpace: context.colorSpace,
            colors: [
                white,
                white.copy(alpha: 0.82)!,
                white.copy(alpha: 0.26)!,
                white.copy(alpha: 0.06)!,
                white.copy(alpha: 0)!,
            ] as CFArray,
            locations: [0, 0.10, 0.28, 0.55, 1.0]
        )!
        let center = CGPoint(x: pixels / 2, y: pixels / 2)
        context.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: CGFloat(pixels) / 2,
            options: []
        )
        return context.makeImage()!
    }

    private static func particleColor(for tint: Color) -> CGColor {
        let base = NSColor(tint).usingColorSpace(.sRGB)
        guard let base else { return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: CGFloat(Tuning.alpha)) }
        let w = CGFloat(Tuning.tintWhiteness)
        func mixed(_ from: CGFloat) -> CGFloat { from + (1 - from) * w }
        return CGColor(
            srgbRed: mixed(base.redComponent),
            green: mixed(base.greenComponent),
            blue: mixed(base.blueComponent),
            alpha: CGFloat(Tuning.alpha)
        )
    }
}
