import AppKit
import Combine
import CoreText
import QuartzCore
import SwiftUI

/// Native surface for high-rate presentation (measurement image, active cells).
///
/// Two costs are avoided. A SwiftUI invalidation always lays out and re-renders
/// the whole window's hosting view, however small the changed leaf; and a
/// CPU bitmap of the whole field (`draw(_:)`) costs a full-size rasterization
/// and upload per frame, which grows with the display (5K iMac). The painter
/// therefore records vector operations; `updateLayer` hands them to a small,
/// reused set of `CAShapeLayer`s that Core Animation renders outside this
/// process. `draw(_:)` replays the same operations for offline snapshots
/// (`cacheDisplay`), so pictures and stage show one drawing.
@MainActor final class LiveLayerView: NSView {
    var paint: ((inout LiveCanvas) -> Void)?
    /// Mirrors `presentationVisible`: a hidden window shows nothing.
    var isPresenting = true {
        didSet { if isPresenting != oldValue { needsDisplay = true } }
    }
    private(set) var drawCount = 0
    private var shapes: [CAShapeLayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    /// Pointer input belongs to the SwiftUI siblings and `ScanFieldPointerEvents`.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func record() -> [LiveCanvas.Operation] {
        guard isPresenting, let paint else { return [] }
        drawCount += 1
        // Dynamic colors (accent, label) resolve like SwiftUI does in this view.
        LiveColorCache.shared.appearance = effectiveAppearance
        var canvas = LiveCanvas(size: bounds.size)
        paint(&canvas)
        return canvas.operations
    }

    override func updateLayer() {
        guard let layer else { return }
        let operations = record()
        let scale = window?.backingScaleFactor ?? layer.contentsScale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        while shapes.count < operations.count {
            let shape = CAShapeLayer()
            shape.anchorPoint = .zero; shape.contentsScale = scale
            layer.addSublayer(shape); shapes.append(shape)
        }
        for (index, shape) in shapes.enumerated() {
            guard index < operations.count else { shape.isHidden = true; shape.path = nil; shape.mask = nil; shape.contents = nil; continue }
            shape.isHidden = false
            shape.frame = operations[index].image?.rect ?? bounds
            if shape.contentsScale != scale { shape.contentsScale = scale }
            operations[index].apply(to: shape, scale: scale, bounds: bounds)
        }
        CATransaction.commit()
    }

    /// Offline snapshots draw through `drawRect`, not the layer tree.
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for operation in record() { operation.replay(in: context) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }
    /// Test observation: number of visible shape layers after the last update.
    var visibleShapeCount: Int { shapes.filter { !$0.isHidden }.count }
}

/// The subset of SwiftUI's `GraphicsContext` the live layers use, recorded as
/// vector operations. Call sites keep `fill(path, with: .color(…))` and
/// `stroke(…)`; text is a plain string with font parameters. Consecutive fills
/// Every call is its own operation in call order, so translucent overlaps compose
/// exactly as in SwiftUI; callers batch deliberately (one path for all raw dots).
@MainActor struct LiveCanvas {
    enum Shading { case color(Color) }
    struct Font: Hashable {
        var size: CGFloat
        var weight: NSFont.Weight
        var monospaced = false
        static func system(size: CGFloat, weight: NSFont.Weight = .regular) -> Font { .init(size: size, weight: weight) }
        static func monospaced(size: CGFloat, weight: NSFont.Weight = .regular) -> Font { .init(size: size, weight: weight, monospaced: true) }
        var nsFont: NSFont {
            monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        }
    }
    struct Stroke: Equatable {
        var width: CGFloat, cap: CGLineCap, join: CGLineJoin, miter: CGFloat, dash: [CGFloat], phase: CGFloat
    }
    /// Text whose glyphs have no outline (color emoji) is drawn as a small bitmap.
    struct Image { let image: CGImage; let rect: CGRect }
    struct Operation {
        let path: CGPath
        let color: CGColor
        /// nil: fill (nonzero rule).
        let stroke: Stroke?
        let clip: CGPath?
        var image: Image? = nil

        func apply(to shape: CAShapeLayer, scale: CGFloat, bounds: CGRect) {
            if let image {
                shape.path = nil; shape.fillColor = nil; shape.strokeColor = nil; shape.mask = nil
                shape.contents = image.image; shape.contentsGravity = .resize
                return
            }
            if shape.contents != nil { shape.contents = nil }
            shape.path = path
            if let stroke {
                shape.fillColor = nil; shape.strokeColor = color
                shape.lineWidth = stroke.width
                shape.lineCap = stroke.cap.shapeLayerCap; shape.lineJoin = stroke.join.shapeLayerJoin
                shape.miterLimit = stroke.miter
                shape.lineDashPattern = stroke.dash.isEmpty ? nil : stroke.dash.map { NSNumber(value: Double($0)) }
                shape.lineDashPhase = stroke.phase
            } else {
                shape.fillColor = color; shape.strokeColor = nil; shape.lineDashPattern = nil
            }
            if let clip {
                let mask = (shape.mask as? CAShapeLayer) ?? CAShapeLayer()
                mask.anchorPoint = .zero; mask.frame = bounds; mask.contentsScale = scale
                mask.path = clip; mask.fillColor = CGColor(gray: 0, alpha: 1)
                shape.mask = mask
            } else if shape.mask != nil {
                shape.mask = nil
            }
        }

        func replay(in context: CGContext) {
            context.saveGState()
            if let image {
                // Flipped view context: draw the upright bitmap into its box.
                context.translateBy(x: image.rect.minX, y: image.rect.maxY); context.scaleBy(x: 1, y: -1)
                context.draw(image.image, in: CGRect(origin: .zero, size: image.rect.size))
                context.restoreGState(); return
            }
            if let clip { context.addPath(clip); context.clip() }
            context.addPath(path)
            if let stroke {
                context.setStrokeColor(color)
                context.setLineWidth(stroke.width); context.setLineCap(stroke.cap)
                context.setLineJoin(stroke.join); context.setMiterLimit(stroke.miter)
                if !stroke.dash.isEmpty { context.setLineDash(phase: stroke.phase, lengths: stroke.dash) }
                context.strokePath()
            } else {
                context.setFillColor(color); context.fillPath()
            }
            context.restoreGState()
        }
    }

    let size: CGSize
    private(set) var operations: [Operation] = []
    private var clip: CGPath?
    init(size: CGSize) { self.size = size }

    mutating func fill(_ path: Path, with shading: Shading) {
        guard !path.isEmpty, case let .color(color) = shading else { return }
        append(path.cgPath, color: LiveColorCache.shared.cgColor(color), stroke: nil)
    }

    mutating func stroke(_ path: Path, with shading: Shading, lineWidth: CGFloat = 1) {
        stroke(path, with: shading, style: StrokeStyle(lineWidth: lineWidth))
    }

    mutating func stroke(_ path: Path, with shading: Shading, style: StrokeStyle) {
        guard !path.isEmpty, case let .color(color) = shading else { return }
        let stroke = Stroke(width: style.lineWidth, cap: style.lineCap, join: style.lineJoin, miter: style.miterLimit,
                            dash: style.dash, phase: style.dashPhase)
        append(path.cgPath, color: LiveColorCache.shared.cgColor(color), stroke: stroke)
    }

    /// Scoped clip; operations inside are masked, the clip ends with the closure.
    mutating func withClip(_ path: Path, _ body: (inout LiveCanvas) -> Void) {
        let outer = clip
        clip = path.cgPath
        body(&self)
        clip = outer
    }

    /// Positions the text's typographic box like `GraphicsContext.draw(_:at:anchor:)`.
    mutating func draw(text: String, font: Font, color: Color, at point: CGPoint, anchor: UnitPoint = .center) {
        guard !text.isEmpty else { return }
        let glyphs = LiveTextCache.shared.glyphs(text, font: font)
        let origin = CGPoint(x: point.x - glyphs.width * anchor.x, y: point.y - glyphs.height * anchor.y)
        if !glyphs.outlined {
            guard let image = LiveTextCache.shared.bitmap(text, font: font, color: color) else { return }
            operations.append(.init(path: CGMutablePath(), color: LiveColorCache.shared.cgColor(color), stroke: nil, clip: clip,
                                    image: .init(image: image, rect: CGRect(x: origin.x, y: origin.y, width: glyphs.width, height: glyphs.height))))
            return
        }
        // Glyph outlines are y-up around the baseline; this view is flipped.
        var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: origin.x, ty: origin.y + glyphs.ascent)
        guard let placed = glyphs.path.copy(using: &transform) else { return }
        append(placed, color: LiveColorCache.shared.cgColor(color), stroke: nil)
    }

    private mutating func append(_ path: CGPath, color: CGColor, stroke: Stroke?) {
        operations.append(.init(path: path, color: color, stroke: stroke, clip: clip))
    }
}

private extension CGLineCap {
    var shapeLayerCap: CAShapeLayerLineCap {
        switch self { case .round: return .round; case .square: return .square; default: return .butt }
    }
}
private extension CGLineJoin {
    var shapeLayerJoin: CAShapeLayerLineJoin {
        switch self { case .round: return .round; case .bevel: return .bevel; default: return .miter }
    }
}

/// Colors are resolved once per value and appearance; the live layers use a
/// small fixed palette. System color changes (accent) empty the cache.
@MainActor final class LiveColorCache {
    static let shared = LiveColorCache()
    private struct Key: Hashable { let color: Color; let appearance: NSAppearance.Name? }
    private var colors: [Key: CGColor] = [:]
    var appearance: NSAppearance?
    private var observer: NSObjectProtocol?
    init() {
        observer = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LiveColorCache.shared.colors.removeAll() }
        }
    }
    func cgColor(_ color: Color) -> CGColor {
        let key = Key(color: color, appearance: appearance?.name)
        if let cached = colors[key] { return cached }
        if colors.count > 512 { colors.removeAll(keepingCapacity: true) }
        var value = NSColor(color).cgColor
        let resolve = { value = NSColor(color).usingColorSpace(.sRGB)?.cgColor ?? NSColor(color).cgColor }
        if let appearance { appearance.performAsCurrentDrawingAppearance(resolve) } else { resolve() }
        colors[key] = value
        return value
    }
}

/// Glyph outlines keyed by text and font. FoF measured text layout per frame as
/// the dominant canvas cost; live labels repeat across frames.
@MainActor final class LiveTextCache {
    struct Glyphs { let path: CGPath; let width: CGFloat; let ascent: CGFloat; let height: CGFloat; let outlined: Bool }
    private struct Key: Hashable { let text: String; let font: LiveCanvas.Font }
    static let shared = LiveTextCache()
    private var entries: [Key: Glyphs] = [:]
    func glyphs(_ text: String, font: LiveCanvas.Font) -> Glyphs {
        let key = Key(text: text, font: font)
        if let cached = entries[key] { return cached }
        if entries.count > 1024 { entries.removeAll(keepingCapacity: true) }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font.nsFont]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let path = CGMutablePath()
        var outlined = true
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName as String] else { continue }
            let runFont = value as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for index in 0..<count {
                guard let outline = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else {
                    // Spaces have no outline; color glyphs (emoji) need the bitmap path.
                    var bounds = CGRect.zero
                    CTFontGetBoundingRectsForGlyphs(runFont, .horizontal, [glyphs[index]], &bounds, 1)
                    if !bounds.isEmpty { outlined = false }
                    continue
                }
                path.addPath(outline, transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y))
            }
        }
        let value = Glyphs(path: path, width: width, ascent: ascent, height: ascent + descent, outlined: outlined)
        entries[key] = value
        return value
    }

    private struct BitmapKey: Hashable { let text: String; let font: LiveCanvas.Font; let color: Color }
    private var bitmaps: [BitmapKey: CGImage] = [:]
    /// 2× bitmap of the typeset line, for glyphs without outlines.
    func bitmap(_ text: String, font: LiveCanvas.Font, color: Color) -> CGImage? {
        let key = BitmapKey(text: text, font: font, color: color)
        if let cached = bitmaps[key] { return cached }
        if bitmaps.count > 128 { bitmaps.removeAll(keepingCapacity: true) }
        let metrics = glyphs(text, font: font), scale: CGFloat = 2
        let width = max(1, Int(ceil(metrics.width * scale))), height = max(1, Int(ceil(metrics.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let attributes: [NSAttributedString.Key: Any] = [.font: font.nsFont,
            .foregroundColor: NSColor(cgColor: LiveColorCache.shared.cgColor(color)) ?? NSColor.white]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 0, y: metrics.height - metrics.ascent)
        CTLineDraw(line, context)
        let image = context.makeImage()
        bitmaps[key] = image
        return image
    }
}

/// Presentation objects mark a live layer for display directly; no SwiftUI
/// transaction. Re-subscribes only when a source object is replaced.
@MainActor final class LiveLayerSubscriptions {
    private var sources: [ObjectIdentifier] = []
    private var subscriptions: [AnyCancellable] = []
    func redraw(_ view: LiveLayerView, on publishers: [AnyPublisher<Void, Never>], sources: [AnyObject]) {
        let identities = sources.map(ObjectIdentifier.init)
        guard identities != self.sources else { return }
        self.sources = identities
        subscriptions = publishers.map { publisher in
            publisher.sink { [weak view] _ in MainActor.assumeIsolated { view?.needsDisplay = true } }
        }
    }
    func cancel() { subscriptions.removeAll(); sources.removeAll() }
}
