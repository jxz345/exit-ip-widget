import AppKit
import SwiftUI

/// Mirrors the menu-bar icon in the Dock and ⌘-Tab. `StatusItemController` passes the same
/// `MenuBarCountryLabel` it has just drawn, with the status button's appearance, so the Dock shows
/// exactly what the menu bar shows (flag or chosen text style, stale prefix, stop symbol, change
/// highlight) and changes at the same moment. The label is rendered at high resolution, scaled to
/// fit a transparent square canvas, and drawn only when its visible content changes.
@MainActor
final class DockIconController {
    static let shared = DockIconController()
    static let canvasSide: CGFloat = 512
    /// The label fills this share of the canvas's longer side.
    static let fill: CGFloat = 0.9

    private(set) var lastKey: String?
    private(set) var image: NSImage?

    /// Renders and (unless `apply` is false) sets the application icon when the label's visible
    /// content or appearance changed. Returns whether a new icon was rendered.
    @discardableResult
    func update(label: MenuBarCountryLabel, darkAppearance: Bool, apply: Bool = true) -> Bool {
        let key = label.visualKey + (darkAppearance ? "|dark" : "|light")
        guard key != lastKey else { return false }
        guard let rendered = Self.render(label: label, darkAppearance: darkAppearance) else {
            RuntimeLog.shared.error("dock_icon_render_failed")
            return false
        }
        lastKey = key
        image = rendered
        if apply {
            NSApp.applicationIconImage = rendered
            RuntimeLog.shared.info("dock_icon_updated", fields: ["appearance": darkAppearance ? "dark" : "light"])
        }
        return true
    }

    /// Re-applies the current icon, for example after the activation policy changes.
    func reapply() {
        if let image { NSApp.applicationIconImage = image }
    }

    static func render(label: MenuBarCountryLabel, darkAppearance: Bool) -> NSImage? {
        let content = label
            .fixedSize()
            .environment(\.colorScheme, darkAppearance ? .dark : .light)
        // Measure at 1×, then render again at the scale that fills the canvas, so the emoji and
        // symbols are drawn from large glyphs rather than enlarged pixels.
        let measure = ImageRenderer(content: content)
        guard let natural = measure.cgImage, natural.width > 0, natural.height > 0 else { return nil }
        let scale = (canvasSide * fill) / CGFloat(max(natural.width, natural.height))
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let large = renderer.cgImage else { return nil }

        let side = Int(canvasSide)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let width = CGFloat(large.width), height = CGFloat(large.height)
        let fit = min(canvasSide * fill / width, canvasSide * fill / height, 1)
        let drawn = CGSize(width: width * fit, height: height * fit)
        context.draw(large, in: CGRect(x: (canvasSide - drawn.width) / 2, y: (canvasSide - drawn.height) / 2,
                                       width: drawn.width, height: drawn.height))
        guard let canvas = context.makeImage() else { return nil }
        return NSImage(cgImage: canvas, size: NSSize(width: canvasSide, height: canvasSide))
    }
}
