import AppKit

/// Metrics of the status menu. A standard `NSMenuItem` title is inset from the menu's content
/// edges by a state column plus a gap, and a view-based item's view is placed at the edge: a
/// custom row that repeated AppKit's insets would not line up with the native rows. The values
/// are therefore measured from the menu window the first time the panel opens (docs/ui.md
/// "Painel") and reused afterwards; the constants are only the initial layout for that first
/// open, matching the metrics of the macOS version this project is built against.
@MainActor public enum MenuMetrics {
    /// Leading edge of a standard menu item title.
    public private(set) static var titleInset: CGFloat = saved.titleInset
    /// Trailing edge of a standard menu item's key equivalent.
    public private(set) static var trailingInset: CGFloat = saved.trailingInset
    /// Width of a custom row before the menu's own width replaces it.
    public static let contentWidth: CGFloat = 320
    private static var measured = false
    private static let storageKey = "menuRowInsets"

    /// Metrics of the previous launch, so the rows start where the system puts them instead of
    /// moving on the first open of every launch. Only the first launch after installation
    /// measures them while the panel is already visible.
    private static var saved: (titleInset: CGFloat, trailingInset: CGFloat) {
        guard let values = UserDefaults.standard.array(forKey: storageKey) as? [Double],
            values.count == 2, (12...40).contains(values[0]), (2...30).contains(values[1])
        else { return (27, 13) }
        return (CGFloat(values[0]), CGFloat(values[1]))
    }

    /// Reads the insets from the open menu window: the title of a plain item and the key
    /// equivalent column are laid out by AppKit inside the same menu, so they are the menu's
    /// own margins and not a guess of ours.
    static func measure(in menu: NSMenu) {
        guard !measured, let window = menuWindow(of: menu), let content = window.contentView else {
            return
        }
        let rows = tableRows(in: content)
        guard !rows.isEmpty else { return }
        var leading: CGFloat?
        var trailing = CGFloat.greatestFiniteMagnitude
        for (index, item) in menu.items.enumerated() where index < rows.count {
            let fields = textFields(in: rows[index])
            guard !fields.isEmpty else { continue }
            for field in fields {
                let frame = field.convert(field.bounds, to: content)
                guard frame.width > 0, frame.minX > 0 else { continue }
                if item.view == nil, !item.isSectionHeader, item.image == nil {
                    leading = min(leading ?? frame.minX, frame.minX)
                }
                trailing = min(trailing, content.bounds.width - frame.maxX)
            }
        }
        guard let left = leading else { return }
        // A degenerate layout (menu not sized yet) must not change the rows.
        guard (12...40).contains(left), (2...30).contains(trailing) else { return }
        titleInset = left.rounded()
        trailingInset = trailing.rounded()
        UserDefaults.standard.set([Double(titleInset), Double(trailingInset)], forKey: storageKey)
        measured = true
    }

    private static func menuWindow(of menu: NSMenu) -> NSWindow? {
        menu.items.compactMap { $0.view?.window }.first
            ?? NSApp.windows.first { $0.className == "NSPopupMenuWindow" }
    }

    /// The row views of the menu's table, in item order.
    private static func tableRows(in view: NSView) -> [NSView] {
        let rows = view.subviews.filter { $0 is NSTableRowView }
        if !rows.isEmpty {
            return rows.sorted { $0.frame.minY < $1.frame.minY }
        }
        return view.subviews.flatMap { tableRows(in: $0) }
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        let own = (view as? NSTextField).map { [$0] } ?? []
        return own + view.subviews.flatMap { textFields(in: $0) }
    }
}
