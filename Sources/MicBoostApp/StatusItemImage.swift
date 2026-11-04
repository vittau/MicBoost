import AppKit

@MainActor enum StatusItemImage {
    private static let images = Dictionary(
        uniqueKeysWithValues: ["mic.fill", "mic.slash.fill", "mic", "exclamationmark.triangle.fill"].map {
            ($0, make(symbol: $0))
        })

    static func image(symbol: String) -> NSImage? { images[symbol] }

    private static func make(symbol: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
            let warning = symbol == "exclamationmark.triangle.fill"
            let slot = NSRect(x: warning ? 3 : 0, y: 0, width: warning ? 18 : 14, height: 18)
            if let microphone = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let scale = min(slot.width / microphone.size.width, slot.height / microphone.size.height)
                let size = NSSize(width: microphone.size.width * scale, height: microphone.size.height * scale)
                microphone.draw(
                    in: NSRect(
                        x: slot.midX - size.width / 2, y: slot.midY - size.height / 2,
                        width: size.width, height: size.height))
            }
            if !warning {
                NSColor.black.setFill()
                for (index, height) in [4.0, 7.0, 10.0].enumerated() {
                    NSBezierPath(
                        roundedRect: NSRect(x: 16 + Double(index) * 3, y: 5, width: 2, height: height),
                        xRadius: 1, yRadius: 1
                    ).fill()
                }
                if symbol == "mic", let context = NSGraphicsContext.current?.cgContext {
                    let slash = CGMutablePath()
                    slash.move(to: CGPoint(x: 15.3, y: 4.5))
                    slash.addLine(to: CGPoint(x: 23.2, y: 15.1))
                    context.saveGState()
                    context.setLineCap(.round)
                    context.setBlendMode(.clear)
                    context.setLineWidth(3.5)
                    context.addPath(slash)
                    context.strokePath()
                    context.setBlendMode(.normal)
                    context.setStrokeColor(NSColor.black.cgColor)
                    context.setLineWidth(1.3)
                    context.addPath(slash)
                    context.strokePath()
                    context.restoreGState()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
