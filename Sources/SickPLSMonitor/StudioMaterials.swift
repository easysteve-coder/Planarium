import SwiftUI
import CoreGraphics

/// Pilot material roles. Decoration owns no subscriptions and never participates in hit testing.
enum StudioMaterials {
    static let labelSize: CGFloat = 10
    static let maximumBrushOpacity = 0.025
    static let wearOpacity = 0.02
    /// Conservative darkest overlap of brushing and wear, used by the contrast audit.
    static let aluminiumMinimum = Color(red: 0.62 * (1 - maximumBrushOpacity) * (1 - wearOpacity),
        green: 0.605 * (1 - maximumBrushOpacity) * (1 - wearOpacity),
        blue: 0.575 * (1 - maximumBrushOpacity) * (1 - wearOpacity))
    static let inkOnLight = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let secondaryInk = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let aluminiumTop = Color(red: 0.79, green: 0.775, blue: 0.74)
    static let aluminiumBottom = Color(red: 0.62, green: 0.605, blue: 0.575)
    static let displayGlass = Color(red: 0.035, green: 0.035, blue: 0.04)
    static let plasticKey = Color(red: 0.15, green: 0.15, blue: 0.165)
    // Thirty percent MIDI FX pigment over the dark plastic base, with light lettering.
    static let midiBypass = Color(red: 0.165, green: 0.291, blue: 0.3135)
    static let gridWell = Color(red: 0.085, green: 0.085, blue: 0.095)
    enum Metal: Hashable { case darkMetal, lightAluminium }
}

@MainActor enum StudioTextureCache {
    private struct Key: Hashable { let metal: StudioMaterials.Metal; let scale: Double }
    private static var images: [Key: CGImage] = [:]
    private(set) static var generations = 0

    static func image(_ metal: StudioMaterials.Metal, scale: CGFloat) -> CGImage? {
        let scale = scale.isFinite ? max(1, min(4, scale)) : 1
        let key = Key(metal: metal, scale: Double(scale))
        if let image = images[key] { return image }
        let width = Int(128 * scale), height = Int(64 * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var seed: UInt64 = metal == .darkMetal ? 0x51C101 : 0xA10101
        for y in 0..<height {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let light = seed & 1 == 0
            let alpha = Double((seed >> 24) % 100) / 100 * (metal == .darkMetal ? 0.018 : StudioMaterials.maximumBrushOpacity)
            context.setFillColor(CGColor(red: light ? 1 : 0, green: light ? 1 : 0, blue: light ? 1 : 0, alpha: alpha))
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        // Sparse deterministic wear follows the brushing direction, never crossing a display.
        for row in 0..<5 {
            let y = (row * 23 + 11) % height
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: StudioMaterials.wearOpacity))
            context.fill(CGRect(x: (row * 47) % width, y: y, width: width / 3, height: 1))
        }
        guard let image = context.makeImage() else { return nil }
        images[key] = image
        generations += 1
        return image
    }
}

@MainActor struct StudioMetalSurface: View {
    let metal: StudioMaterials.Metal
    @Environment(\.displayScale) private var scale
    var body: some View {
        let aluminium = metal == .lightAluminium
        ZStack {
            LinearGradient(colors: aluminium ? [StudioMaterials.aluminiumTop, StudioMaterials.aluminiumBottom]
                : [Color(red: 0.20, green: 0.20, blue: 0.215), Color(red: 0.12, green: 0.12, blue: 0.13)], startPoint: .top, endPoint: .bottom)
            if let image = StudioTextureCache.image(metal, scale: scale) {
                Image(decorative: image, scale: scale).resizable(resizingMode: .tile)
            }
            VStack(spacing: 0) {
                Color.white.opacity(aluminium ? 0.45 : 0.18).frame(height: 1)
                Spacer(minLength: 0)
                Color.black.opacity(0.35).frame(height: 1)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct StudioGlass: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3).fill(StudioMaterials.displayGlass)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(
                LinearGradient(colors: [.black, .white.opacity(0.24)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct StudioPlastic: View {
    var tint: Color = StudioMaterials.plasticKey
    var pressed = false
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(tint)
            .overlay(RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [.clear, .black.opacity(0.14)], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(
                LinearGradient(colors: pressed ? [.black.opacity(0.75), .white.opacity(0.15)] : [.white.opacity(0.38), .black.opacity(0.65)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct StudioMixerKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var studioMixer: Bool { get { self[StudioMixerKey.self] } set { self[StudioMixerKey.self] = newValue } }
}

struct StudioKeyStyle: ButtonStyle {
    @Environment(\.studioMixer) private var enabled
    let tint: Color
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background {
            if enabled { StudioPlastic(tint: tint, pressed: configuration.isPressed || active) }
            else { RoundedRectangle(cornerRadius: 4).fill(tint) }
        }.offset(y: enabled && configuration.isPressed ? 1 : 0)
    }
}

struct StudioSlotPartStyle: ButtonStyle {
    @Environment(\.studioMixer) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: enabled && configuration.isPressed ? 1 : 0)
            .background { if enabled && configuration.isPressed { StudioPlastic(tint: .black.opacity(0.22), pressed: true) } }
    }
}

struct StudioPanicCap: View {
    static let stopColors = (normal: Color(red: 0.66, green: 0.055, blue: 0.035), pressed: Color(red: 0.84, green: 0.055, blue: 0.035))
    static let panicColors = (normal: Color(red: 0.025, green: 0.34, blue: 0.095), pressed: Color(red: 0.035, green: 0.43, blue: 0.12))
    var pressed: Bool
    var colors = stopColors
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        ZStack(alignment: .topLeading) {
            shape.fill(pressed ? colors.pressed : colors.normal)
            shape.fill(LinearGradient(colors: [.white.opacity(pressed ? 0.06 : 0.14), .clear, .black.opacity(0.24)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.8), .white.opacity(0.12), .black.opacity(0.8)],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: pressed ? 1 : 2)
            Capsule().fill(Color.white.opacity(0.55)).frame(width: 18, height: 2).padding(5)
        }.padding(.top, pressed ? 2 : 0).padding(.bottom, pressed ? 0 : 2)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
