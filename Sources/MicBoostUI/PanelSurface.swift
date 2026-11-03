import AppKit
import SwiftUI

/// The live AppKit surface owns material rendering; SwiftUI supplies transparent content.
@MainActor public final class PanelSurface: NSView {
    private let host: PanelHostingView
    public var contentSize: NSSize { host.fittingSize }

    public init(model: AppModel) {
        host = PanelHostingView(rootView: PanelView(model: model))
        let bounds = NSRect(origin: .zero, size: host.fittingSize)
        super.init(frame: bounds)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.cornerRadius = 12
        host.layer?.masksToBounds = true

        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = 12
            glass.contentView = host
            surface = glass
        } else {
            let material = NSVisualEffectView(frame: bounds)
            material.material = .menu
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 12
            material.layer?.masksToBounds = true
            material.addSubview(host)
            surface = material
        }
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

@MainActor private final class PanelHostingView: NSHostingView<PanelView> {
    override var isOpaque: Bool { false }
}
