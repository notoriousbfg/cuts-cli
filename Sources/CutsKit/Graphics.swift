import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Everything cuts draws itself rather than asking ffmpeg to: titles, gradients, corner masks,
/// shadows and contact sheets. Each is written as a PNG that ffmpeg then composites.
enum Graphics {
    static func context(_ width: Int, _ height: Int) throws -> CGContext {
        guard let ctx = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ToolError("could not make a \(width)×\(height) drawing surface")
        }
        return ctx
    }

    static func write(_ ctx: CGContext, to url: URL) throws {
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ToolError("could not write \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("could not write \(url.path)") }
    }

    static func cg(_ c: RGBA) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [c.r, c.g, c.b, c.a])!
    }

    static func draw(_ fill: Fill, in ctx: CGContext, width: Int, height: Int) {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        switch fill {
        case .color(let c):
            ctx.setFillColor(cg(c))
            ctx.fill(rect)
        case .gradient(let a, let b, let angle):
            // 0° runs left to right, 90° top to bottom.
            let rad = angle * .pi / 180
            let dx = cos(rad), dy = sin(rad)
            let half = (abs(dx) * Double(width) + abs(dy) * Double(height)) / 2
            let cx = Double(width) / 2, cy = Double(height) / 2
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [cg(a), cg(b)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: cx - dx * half, y: cy + dy * half),
                                   end: CGPoint(x: cx + dx * half, y: cy - dy * half),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    static func fillImage(_ fill: Fill, width: Int, height: Int, to url: URL) throws {
        let ctx = try context(width, height)
        draw(fill, in: ctx, width: width, height: height)
        try write(ctx, to: url)
    }

    /// White rounded rectangle on black: the alpha a clip with rounded corners gets.
    static func mask(width: Int, height: Int, radius: Double, to url: URL) throws {
        let ctx = try context(width, height)
        ctx.setFillColor(cg(.black))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(cg(.white))
        let r = min(radius, Double(min(width, height)) / 2)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
        try write(ctx, to: url)
    }

    /// A canvas-sized transparent image holding only the shadow of a rounded rectangle at `rect` (top-left origin).
    static func shadow(canvasWidth: Int, canvasHeight: Int, rect: CGRect, radius: Double, spec: ShadowSpec, scale: Double, to url: URL) throws {
        let ctx = try context(canvasWidth, canvasHeight)
        let flipped = CGRect(x: rect.minX, y: Double(canvasHeight) - rect.maxY, width: rect.width, height: rect.height).insetBy(dx: 1, dy: 1)
        let r = min(radius, Double(min(flipped.width, flipped.height)) / 2)
        let path = CGPath(roundedRect: flipped, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.setShadow(offset: CGSize(width: spec.x * scale, height: -spec.y * scale), blur: spec.blur * scale, color: cg(spec.color))
        ctx.setFillColor(cg(RGBA(r: spec.color.r, g: spec.color.g, b: spec.color.b, a: 1)))
        ctx.addPath(path)
        ctx.fillPath()
        // Keep only the shadow: the clip itself covers this area, and may be translucent.
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setBlendMode(.clear)
        ctx.addPath(path)
        ctx.fillPath()
        try write(ctx, to: url)
    }

    // MARK: Text

    static let weightValues: [String: CGFloat] = [
        "ultralight": -0.8, "thin": -0.6, "light": -0.4, "regular": 0, "medium": 0.23,
        "semibold": 0.3, "bold": 0.4, "heavy": 0.56, "black": 0.62,
    ]

    static func font(_ style: TextStyle, scale: Double, resolve: (String) -> String, warnings: inout [String]) -> CTFont {
        let size = CGFloat(style.size * scale)
        let weight = weightValues[style.weight] ?? 0
        var font: CTFont?
        if let file = style.fontFile {
            let url = URL(fileURLWithPath: resolve(file))
            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let first = descriptors.first {
                font = CTFontCreateWithFontDescriptor(first, size, nil)
            } else {
                warnings.append("could not load a font from \(url.path); using the system font")
            }
        } else if let name = style.font {
            var traits: [CFString: Any] = [kCTFontWeightTrait: weight]
            if style.italic { traits[kCTFontSymbolicTrait] = CTFontSymbolicTraits.traitItalic.rawValue }
            let wanted = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name, kCTFontTraitsAttribute: traits] as CFDictionary)
            if let match = CTFontDescriptorCreateMatchingFontDescriptor(wanted, Set([kCTFontFamilyNameAttribute as String]) as CFSet) {
                font = CTFontCreateWithFontDescriptor(match, size, nil)
            } else {
                // Not a family: maybe a PostScript name such as "HelveticaNeue-Bold".
                let named = CTFontCreateWithName(name as CFString, size, nil)
                let got = [CTFontCopyPostScriptName(named) as String, CTFontCopyFullName(named) as String]
                if got.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    font = named
                } else {
                    warnings.append("no font named \"\(name)\"; using the system font")
                }
            }
        }
        if font == nil {
            let system = NSFont.systemFont(ofSize: size, weight: NSFont.Weight(weight)) as CTFont
            font = style.italic ? (CTFontCreateCopyWithSymbolicTraits(system, size, nil, .traitItalic, .traitItalic) ?? system) : system
        }
        return font!
    }

    /// Draws a text clip as a canvas-sized image. Returns the text block's rectangle (top-left origin).
    @discardableResult
    static func text(_ spec: TextSpec, clip: Clip, width: Int, height: Int, scale: Double,
                     resolve: (String) -> String, warnings: inout [String], to url: URL) throws -> CGRect {
        let ctx = try context(width, height)
        if let background = spec.background { draw(background, in: ctx, width: width, height: height) }

        let string = NSMutableAttributedString()
        for (i, line) in spec.lines.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = spec.align == "left" ? .left : (spec.align == "right" ? .right : .center)
            paragraph.lineHeightMultiple = line.style.lineHeight
            paragraph.paragraphSpacingBefore = i == 0 ? 0 : line.gap * scale
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font(line.style, scale: scale, resolve: resolve, warnings: &warnings),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): cg(line.style.color),
                .kern: line.style.tracking * scale,
                .paragraphStyle: paragraph,
            ]
            string.append(NSAttributedString(string: line.text + (i < spec.lines.count - 1 ? "\n" : ""), attributes: attributes))
        }

        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let limit = CGSize(width: Double(width) * spec.maxWidth, height: .greatestFiniteMagnitude)
        var size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, limit, nil)
        size = CGSize(width: ceil(size.width) + 2, height: ceil(size.height) + 2)

        let left = (clip.position.x * Double(width) - clip.anchor.x * size.width).rounded()
        let top = (clip.position.y * Double(height) - clip.anchor.y * size.height).rounded()
        let block = CGRect(x: left, y: top, width: size.width, height: size.height)
        let flipped = CGRect(x: left, y: Double(height) - top - size.height, width: size.width, height: size.height)

        if let box = spec.box {
            let pad = box.padding * scale
            let rect = flipped.insetBy(dx: -pad * 1.4, dy: -pad)
            let r = min(box.radius * scale, min(rect.width, rect.height) / 2)
            ctx.setFillColor(cg(box.color))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
        }
        if let shadow = clip.shadow {
            ctx.setShadow(offset: CGSize(width: shadow.x * scale, height: -shadow.y * scale), blur: shadow.blur * scale, color: cg(shadow.color))
        }
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: flipped, transform: nil), nil)
        CTFrameDraw(frame, ctx)
        try write(ctx, to: url)
        return block
    }

    // MARK: Contact sheet

    static func sheet(frames: [URL], labels: [String], columns: Int, title: String?, to url: URL) throws {
        let images: [CGImage] = frames.compactMap { url in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let first = images.first else { throw ToolError("no frames came out for the sheet") }
        let cols = max(1, min(columns, images.count))
        let rows = (images.count + cols - 1) / cols
        let w = first.width, h = first.height
        let gap = 12, label = 30, head = title == nil ? 0 : 34
        let width = cols * w + (cols + 1) * gap
        let height = head + rows * (h + label) + (rows + 1) * gap
        let ctx = try context(width, height)
        ctx.setFillColor(cg(RGBA(r: 0.11, g: 0.11, b: 0.12, a: 1)))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        func drawLabel(_ text: String, x: Int, top: Int, size: CGFloat) {
            let attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold) as CTFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): cg(.white),
            ])
            ctx.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(height - top) - size - 4)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        }
        if let title { drawLabel(title, x: gap, top: gap, size: 17) }
        for (i, image) in images.enumerated() {
            let x = gap + (i % cols) * (w + gap)
            let top = head + gap + (i / cols) * (h + label + gap)
            drawLabel(i < labels.count ? labels[i] : "", x: x, top: top, size: 17)
            ctx.draw(image, in: CGRect(x: x, y: height - top - label - h, width: w, height: h))
        }
        try write(ctx, to: url)
    }
}
