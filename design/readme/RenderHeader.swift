// Renders the README header: the app icon and the "MicBoost" wordmark, centered on a
// transparent canvas, in a light and a dark variant. Run through
// scripts/render-readme-header.sh so the paths stay in one place.

import AppKit

struct Variant {
    let name: String
    let textColor: NSColor
}

let canvasWidth = 1480  // 740 pt at 2x
let canvasHeight = 520  // 260 pt at 2x
let iconSide: CGFloat = 360
let gap: CGFloat = 56
let fontSize: CGFloat = 170

let variants = [
    Variant(name: "light", textColor: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)),
    Variant(name: "dark", textColor: NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1)),
]

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: RenderHeader.swift <icon.png> <output-dir>\n".utf8))
    exit(2)
}

let iconURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2])

guard let icon = NSImage(contentsOf: iconURL) else {
    FileHandle.standardError.write(Data("cannot read \(iconURL.path)\n".utf8))
    exit(1)
}

let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)

for variant in variants {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: canvasWidth,
            pixelsHigh: canvasHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        FileHandle.standardError.write(Data("cannot create bitmap\n".utf8))
        exit(1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

    let text = NSAttributedString(
        string: "MicBoost",
        attributes: [
            .font: font,
            .foregroundColor: variant.textColor,
            .kern: -1.5,
        ]
    )
    let textSize = text.size()

    let contentWidth = iconSide + gap + textSize.width
    let originX = (CGFloat(canvasWidth) - contentWidth) / 2

    let iconRect = CGRect(
        x: originX,
        y: (CGFloat(canvasHeight) - iconSide) / 2,
        width: iconSide,
        height: iconSide
    )
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)

    // Center the wordmark on its typographic bounds, not on the line box, so the
    // optical center matches the icon.
    let textRect = CGRect(
        x: originX + iconSide + gap,
        y: (CGFloat(canvasHeight) - textSize.height) / 2,
        width: textSize.width,
        height: textSize.height
    )
    text.draw(in: textRect)

    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("cannot encode PNG\n".utf8))
        exit(1)
    }
    let destination = outputDirectory.appendingPathComponent("header-\(variant.name).png")
    try png.write(to: destination)
    print("wrote \(destination.path) (\(canvasWidth)x\(canvasHeight))")
}
